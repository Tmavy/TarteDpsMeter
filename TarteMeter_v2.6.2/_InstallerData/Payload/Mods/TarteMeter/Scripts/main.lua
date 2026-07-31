local MOD_NAME = "TarteMeter v2.6.2"
local LOG_FILE = "Mods/TarteMeter/dps_meter.txt"
local STATE_FILE = "Mods/TarteMeter/dps_state.txt"
local STATE_TMP = "Mods/TarteMeter/dps_state.tmp"
local COMMAND_FILE = "Mods/TarteMeter/dps_command.txt"
local WINDOW_SCRIPT = "Mods\\TarteMeter\\OverlayBootstrap.ps1"
local WINDOW_LAUNCHER = "Mods\\TarteMeter\\LaunchOverlay.vbs"
local HISTORY_FILE = "Mods/TarteMeter/battle_history.jsonl"
local TIMELINE_FILE = "Mods/TarteMeter/current_timeline.csv"
local EXPORT_CSV_FILE = "Mods/TarteMeter/latest_battle.csv"
local EXPORT_JSON_FILE = "Mods/TarteMeter/latest_battle.json"

-- Automatic combat-end archiving is enabled; manual RESET remains available.
local DAMAGE_DEFER_SECONDS = 0.080
local DAMAGE_BATCH_MAX_EVENTS = 512
local DAMAGE_BATCH_CONTINUATION_MS = 4
local DAMAGE_QUEUE_HARD_LIMIT = 16384
local TARGET_MATCH_CELL_SIZE = 20.0
local SOURCE_KEEP_SECONDS = 6.000
local SOURCE_QUEUE_MAX_RECORDS = 512
local SOURCE_PRUNE_SECONDS = 0.500
local SOURCE_AFTER_DAMAGE_SECONDS = 0.120
local SOURCE_MATCH_WINDOW_SECONDS = 1.500
local SOURCE_BURST_REUSE_SECONDS = 0.900
local SOURCE_BURST_MAX_HITS = 16

-- Tarte's deployed orbs can produce delayed or spaced damage callbacks.
-- Use a wider continuation window only for a source already verified as Tarte.
local TARTE_SOURCE_MATCH_WINDOW_SECONDS = 1.500
local TARTE_SOURCE_BURST_REUSE_SECONDS = 1.250
local TARTE_SOURCE_BURST_MAX_HITS = 24

-- Performance controls.
local ACTIVE_POLL_SECONDS = 0.250
local STATE_WRITE_SECONDS = 0.750
local COMMAND_POLL_SECONDS = 0.500
local OWNER_CACHE_SECONDS = 2.000
local OWNER_NEGATIVE_CACHE_SECONDS = 0.250
local OWNER_CACHE_PRUNE_SECONDS = 1.000
local OWNER_RESOLUTION_MAX_NODES = 18
local TARGET_MATCH_MAX_DISTANCE = 3000.0
local ATTRIBUTION_DIAGNOSTIC_LIMIT = 4
local SOURCE_DIAGNOSTIC_LIMIT = 16
local OWNER_CHAIN_DIAGNOSTIC_DEPTH = 4
local OWNER_CHAIN_DIAGNOSTIC_NODES = 14
local DANA_GOLEM_CLASS_TOKEN = "DsMon_Chaco_V2_C"
local DANA_GOLEM_OWNER_TOKEN = "DsMCTR_C"
local DANA_GOLEM_DISPLAY = "Chako"
local DANA_GOLEM_SOURCE_TOKEN = "Chaco"
local DANA_GOLEM_TARGET_GRACE_SECONDS = 2.500
local ALLIED_SUMMON_TARGET_TOKENS = {
    "DsMon_Chaco_V2_C",
    "DsMon_Kalien_Large_Fox_C",
    "DsMon_Kalien_SignalA_Fox_C"
}
local MAX_HISTORY_EVENTS = 25000
local VERBOSE_DAMAGE_LOG = false

-- A fight is considered finished after this much time without outgoing damage.
-- Long fights are archived automatically; shorter fights are archived when RESET is used.
local COMBAT_END_IDLE_SECONDS = 10.000
local AUTO_SAVE_MIN_DURATION_SECONDS = 0.000

-- Heuristic for lingering attacks when the game exposes no SourceActor event.
-- After a swap, low/periodic damage can remain assigned to the previous hero
-- for this short window. Direct attacks by the new hero end the carryover.
local SWAP_CARRY_SECONDS = 0.000
local CARRY_SMALL_DAMAGE_MAX = 3000.0
local NEW_ACTIVE_DIRECT_DAMAGE_MIN = 5000.0

local active_pc = -1
local active_name = "Unknown"
local active_internal = nil
local current_enemy_name = "Unknown"
local current_enemy_time = -999.0
local ENEMY_NAME_KEEP_SECONDS = 3.0
local last_enemy_object_key = nil

local source_records = {}
local source_record_count = 0
local source_record_sequence = 0
local pending_damage_events = {}
local damage_batch_scheduled = false
local damage_batch_token = 0
local damage_queue_overflow_logged = false
local combat_generation = 0

local totals = {}
local hits = {}
local crits = {}
local highest_hits = {}
local combat_events = {}
local combat_events_truncated = false
local character_order = {}
local character_seen = {}

local roster_internal = {}
local roster_display = {}

local session_started = false
local session_finished = false
local session_start_time = 0.0
local session_end_time = 0.0
local last_outgoing_damage_time = -999.0
local session_auto_saved = false
local event_no = 0
local timeline_pending_lines = {}
local timeline_last_flush = 0.0
local TIMELINE_FLUSH_SECONDS = 1.000
local TIMELINE_FLUSH_MAX_LINES = 512
local script_start_time = os.clock()
local window_launched = false
local last_state_write = -999.0
local last_command_poll = -999.0
local last_owner_cache_prune = -999.0
local last_source_prune = -999.0
local owner_resolution_cache = {}
local attribution_diagnostic_count = 0
local source_diagnostic_count = 0
local allied_target_diagnostic_count = 0
local hook_callback_error_count = 0
local special_summon_logged = {}
local special_target_owner_cache = {}
local state_dirty = true
local previous_active_name = nil
local swap_time = -999.0
local carryover_enabled = false
local transition_active = false
local transition_until = -999.0
local missing_controller_since = nil
local MAP_RELOAD_GRACE_SECONDS = 3.0
local CONTROLLER_MISSING_CONFIRM_SECONDS = 0.75

-- Internal UE class tokens -> player-facing names.
local DISPLAY_ALIASES = {
    Castela = "Castella",
    Aileen = "Eileen",
    Theresia = "Theresa",
    Onette = "Ornette",
    Cassius = "Kalsion"
}

local function now()
    return os.clock() - script_start_time
end

local function safe_call(fn, fallback)
    local ok, value = pcall(fn)
    if ok and value ~= nil then return value end
    return fallback
end

local VERBOSE_LOGGING = false
local QUIET_LOG_TYPES = {
    DAMAGE = true,
    DAMAGE_PENDING = true,
    SOURCE_ACCEPTED = true,
    SOURCE_REJECTED = true,
    DPS_SUMMARY = true,
    DPS_CHARACTER = true,
    DIAG_PROJECTILE_BLOCK = true,
    DIAG_BATTLE_LOG = true,
    DIAG_BUFF_DAMAGE_DIRECT_ATTACKER = true,
    DIAG_HIT_DIRECTION = true,
    DIAG_CHARACTER_DAMAGED = true
}

local function append_line(kind, details)
    if not VERBOSE_LOGGING and QUIET_LOG_TYPES[kind] then
        return
    end

    if not VERBOSE_DAMAGE_LOG and (kind == "DAMAGE_PENDING" or kind == "DAMAGE") then
        return
    end

    event_no = event_no + 1
    local line = string.format(
        "%.3f | %06d | %-24s | %s\n",
        now(), event_no, kind, details or ""
    )

    pcall(function()
        local f = io.open(LOG_FILE, "a")
        if f then
            f:write(line)
            f:flush()
            f:close()
        end
    end)

    print("[DS DPS] " .. line:gsub("\n", ""))
end

local function reset_log_file()
    local f = io.open(LOG_FILE, "w")
    if f then
        f:write(MOD_NAME .. "\n")
        f:write("time | event# | type | details\n")
        f:close()
    end
end

local function fname_to_string(fname)
    if fname == nil then return nil end
    local converted = safe_call(function() return fname:ToString() end, nil)
    if converted ~= nil then return tostring(converted) end
    return tostring(fname)
end

local function value_to_string(value)
    if value == nil then return nil end

    local converted = safe_call(function()
        return value:ToString()
    end, nil)

    if converted ~= nil then
        local text = tostring(converted)
        if text ~= "" and text ~= "None" then return text end
    end

    local text = tostring(value)
    if text == "" or text == "nil" or text == "None" then return nil end
    return text
end

local function clean_enemy_name(text)
    if text == nil then return nil end
    text = tostring(text)
    text = text:gsub("^Default__", "")
    text = text:gsub("_C_%d+$", "")
    text = text:gsub("_C$", "")
    text = text:gsub("_%d+$", "")
    text = text:gsub("^BP_", "")
    text = text:gsub("^DsMonsterCharacter_", "")
    text = text:gsub("_", " ")
    text = text:gsub("%s+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" or text == "Unknown" then return nil end
    return text
end

local function object_class_name(obj)
    if obj == nil then return nil end
    return safe_call(function()
        if not obj:IsValid() then return nil end
        local cls = obj:GetClass()
        if cls == nil then return nil end
        return fname_to_string(cls:GetFName())
    end, nil)
end

local function object_name(obj)
    if obj == nil then return nil end
    return safe_call(function()
        if not obj:IsValid() then return nil end
        return fname_to_string(obj:GetFName())
    end, nil)
end

local function object_key(obj)
    if obj == nil then return "nil" end
    return tostring(object_class_name(obj) or "unknown-class")
        .. "|" ..
        tostring(object_name(obj) or "unknown-object")
end

local function normalize_display(internal)
    if internal == nil or internal == "" then return "Unknown" end
    return DISPLAY_ALIASES[internal] or internal
end

local function extract_pc_internal(class_name)
    if class_name == nil then return nil end
    return class_name:match("^DsPC_([^_]+)")
end

local function register_character(name)
    if name == nil or name == "" then name = "Unknown" end

    if totals[name] == nil then
        totals[name] = 0.0
        hits[name] = 0
        crits[name] = 0
        highest_hits[name] = 0.0
    end

    if not character_seen[name] then
        character_seen[name] = true
        table.insert(character_order, name)
    end

    return name
end

register_character("Unknown")

local function register_roster_internal(internal)
    if internal == nil or internal == "" then return nil end
    local display = normalize_display(internal)
    roster_internal[internal] = true
    roster_display[internal] = display
    register_character(display)
    return display
end

local function unwrap_remote_value(value)
    if value == nil then return nil end
    local unwrapped = safe_call(function() return value:get() end, nil)
    if unwrapped ~= nil then return unwrapped end
    return value
end

local function vector_xyz(value)
    value = unwrap_remote_value(value)
    if value == nil then return nil, nil, nil end

    local function component(name)
        local raw = safe_call(function() return value[name] end, nil)
        raw = unwrap_remote_value(raw)
        return tonumber(raw)
    end

    local x = component("X")
    local y = component("Y")
    local z = component("Z")
    if x == nil or y == nil or z == nil then
        return nil, nil, nil
    end
    return x, y, z
end

local function actor_xyz(actor)
    if actor == nil then return nil, nil, nil end

    local location = safe_call(function()
        if not actor:IsValid() then return nil end
        return actor:K2_GetActorLocation()
    end, nil)

    return vector_xyz(location)
end

local function is_chako_actor(actor)
    if actor == nil then return false end
    local class_name = object_class_name(actor)
    local obj_name = object_name(actor)
    return (
        class_name ~= nil
        and class_name:find(DANA_GOLEM_CLASS_TOKEN, 1, true) ~= nil
    ) or (
        obj_name ~= nil
        and obj_name:find(DANA_GOLEM_CLASS_TOKEN, 1, true) ~= nil
    )
end

local function is_allied_summon_actor(actor)
    if actor == nil then return false end

    local class_name = object_class_name(actor) or ""
    local obj_name = object_name(actor) or ""

    for _, token in ipairs(ALLIED_SUMMON_TARGET_TOKENS) do
        if class_name:find(token, 1, true) ~= nil
            or obj_name:find(token, 1, true) ~= nil
        then
            return true
        end
    end

    return false
end

local function build_monster_snapshot()
    local monsters = safe_call(function()
        return FindAllOf("DsMonsterCharacter")
    end, nil)

    if monsters == nil then
        return nil, "monster_snapshot_unavailable"
    end

    local snapshot = {}
    for _, monster in ipairs(monsters) do
        if monster ~= nil then
            local valid = safe_call(function()
                return monster:IsValid()
            end, false)

            if valid then
                local x, y, z = actor_xyz(monster)
                if x ~= nil then
                    snapshot[#snapshot + 1] = {
                        actor = monster,
                        key = object_key(monster),
                        allied = is_allied_summon_actor(monster),
                        x = x,
                        y = y,
                        z = z
                    }
                end
            end
        end
    end

    if #snapshot == 0 then
        return snapshot, "monster_snapshot_empty"
    end

    return snapshot, "monster_snapshot_ready"
end

local function hit_bucket_key(hx, hy, hz)
    if hx == nil or hy == nil or hz == nil then
        return "nil"
    end

    local cell = TARGET_MATCH_CELL_SIZE
    return string.format(
        "%d:%d:%d",
        math.floor((hx / cell) + 0.5),
        math.floor((hy / cell) + 0.5),
        math.floor((hz / cell) + 0.5)
    )
end

local function find_target_in_snapshot(
    snapshot,
    hx,
    hy,
    hz,
    match_cache
)
    if snapshot == nil or #snapshot == 0 then
        return nil, nil, "monster_snapshot_empty"
    end

    local bucket = hit_bucket_key(hx, hy, hz)
    local cached = match_cache[bucket]

    if cached ~= nil then
        if cached.index == 0 then
            return nil, cached.distance, cached.method
        end

        return snapshot[cached.index], cached.distance, cached.method
    end

    if hx == nil then
        if #snapshot == 1 then
            match_cache[bucket] = {
                index = 1,
                distance = nil,
                method = "single_monster_snapshot"
            }
            return snapshot[1], nil, "single_monster_snapshot"
        end

        match_cache[bucket] = {
            index = 0,
            distance = nil,
            method = "hit_location_unavailable"
        }
        return nil, nil, "hit_location_unavailable"
    end

    local nearest_index = nil
    local nearest_distance2 = nil

    for index, entry in ipairs(snapshot) do
        local dx = entry.x - hx
        local dy = entry.y - hy
        local dz = entry.z - hz
        local distance2 = dx * dx + dy * dy + dz * dz

        if nearest_distance2 == nil or distance2 < nearest_distance2 then
            nearest_index = index
            nearest_distance2 = distance2
        end
    end

    if nearest_index == nil then
        match_cache[bucket] = {
            index = 0,
            distance = nil,
            method = "monster_positions_unavailable"
        }
        return nil, nil, "monster_positions_unavailable"
    end

    local distance = math.sqrt(nearest_distance2)
    if distance > TARGET_MATCH_MAX_DISTANCE then
        match_cache[bucket] = {
            index = 0,
            distance = distance,
            method = "nearest_target_too_far"
        }
        return nil, distance, "nearest_target_too_far"
    end

    match_cache[bucket] = {
        index = nearest_index,
        distance = distance,
        method = "batch_hit_location_nearest"
    }
    return snapshot[nearest_index], distance, "batch_hit_location_nearest"
end

local function clear_pending_damage_events()
    pending_damage_events = {}
    damage_batch_token = damage_batch_token + 1
    damage_batch_scheduled = false
    damage_queue_overflow_logged = false
end

local function enter_map_transition(reason)
    local t = now()
    if not transition_active then
        transition_active = true
        transition_until = t + MAP_RELOAD_GRACE_SECONDS
        source_records = {}
        source_record_count = 0
        source_record_sequence = 0
        clear_pending_damage_events()
        owner_resolution_cache = {}
        attribution_diagnostic_count = 0
        source_diagnostic_count = 0
        allied_target_diagnostic_count = 0
        special_summon_logged = {}
        special_target_owner_cache = {}
        last_owner_cache_prune = -999.0
        last_source_prune = -999.0
        carryover_enabled = false
        previous_active_name = nil
        active_pc = -1
        active_name = "Unknown"
        active_internal = nil
        current_enemy_name = "Unknown"
        current_enemy_time = -999.0
        last_enemy_object_key = nil
        state_dirty = true
        append_line("MAP_TRANSITION", reason or "controller unavailable")
    else
        transition_until = math.max(transition_until, t + 0.5)
    end
end

local function resolve_character_object(obj)
    if obj == nil then return nil, nil, nil end

    local class_name = object_class_name(obj)
    local internal = extract_pc_internal(class_name)
    if internal ~= nil then
        local display = register_roster_internal(internal)
        return display, internal, class_name
    end

    return nil, nil, class_name
end

local OWNER_PROPERTIES = {
    "Owner",
    "Instigator",
    "SourceActor",
    "Caster",
    "Creator",
    "Character",
    "Pawn",
    "AcknowledgedPawn"
}

local function get_property(obj, property_name)
    return safe_call(function()
        if not obj or not obj:IsValid() then return nil end
        return obj[property_name]
    end, nil)
end

local function resolve_special_summon_owner(obj, path)
    if obj == nil then return nil, nil end

    local class_name = object_class_name(obj)
    local obj_name = object_name(obj)

    local exact_golem = (
        class_name ~= nil
        and class_name:find(DANA_GOLEM_CLASS_TOKEN, 1, true) ~= nil
    ) or (
        obj_name ~= nil
        and obj_name:find(DANA_GOLEM_CLASS_TOKEN, 1, true) ~= nil
    )

    if not exact_golem then
        return nil, nil
    end

    local controller = get_property(obj, "Owner")
    local controller_class = object_class_name(controller)
    local controller_name = object_name(controller)

    local key = object_key(obj)
    if not special_summon_logged[key] then
        special_summon_logged[key] = true
        append_line("CHAKO_IDENTIFIED", string.format(
            "row=%s summon=%s controller=%s path=%s active=%d:%s",
            DANA_GOLEM_DISPLAY,
            key,
            object_key(controller),
            tostring(path or "unknown"),
            active_pc,
            active_name
        ))
    end

    return DANA_GOLEM_DISPLAY, string.format(
        "%s exact_summon=%s controller=%s",
        tostring(path or "root"),
        class_name or obj_name or DANA_GOLEM_CLASS_TOKEN,
        controller_class or controller_name or DANA_GOLEM_OWNER_TOKEN
    )
end

local ENEMY_NAME_PROPERTIES = {
    "DisplayName",
    "CharacterName",
    "MonsterName",
    "UnitName",
    "Name",
    "NickName",
    "ActorName"
}

local function resolve_enemy_display_name(monster)
    if monster == nil then return "Unknown" end

    for _, property_name in ipairs(ENEMY_NAME_PROPERTIES) do
        local raw = get_property(monster, property_name)
        local readable = clean_enemy_name(value_to_string(raw))
        if readable ~= nil then return readable end
    end

    local readable_object = clean_enemy_name(object_name(monster))
    if readable_object ~= nil then return readable_object end

    local readable_class = clean_enemy_name(object_class_name(monster))
    if readable_class ~= nil then return readable_class end

    return "Unknown"
end

local function set_current_enemy(monster)
    if monster == nil then return end

    local key = object_key(monster)
    if key == last_enemy_object_key and current_enemy_name ~= "Unknown" then
        current_enemy_time = now()
        return
    end

    local name = resolve_enemy_display_name(monster)
    if name ~= nil and name ~= "Unknown" then
        last_enemy_object_key = key
        current_enemy_name = name
        current_enemy_time = now()
        state_dirty = true
    end
end

local function resolve_owner_chain(root)
    if root == nil then return nil, "root=nil" end

    local direct_special, direct_method =
        resolve_special_summon_owner(root, "root")
    if direct_special ~= nil then
        return direct_special, direct_method
    end

    local t = now()
    local root_key = object_key(root)
    local cached = owner_resolution_cache[root_key]

    if cached ~= nil then
        local ttl = cached.owner == false
            and OWNER_NEGATIVE_CACHE_SECONDS
            or OWNER_CACHE_SECONDS

        if (t - (cached.time or -999.0)) <= ttl then
            if cached.owner == false then
                return nil, cached.method or "cached unresolved owner"
            end
            return cached.owner, cached.method
        end
    end

    local queue = {{ obj = root, path = "root", depth = 0 }}
    local visited = {}
    local head = 1
    local processed = 0

    while head <= #queue and processed < OWNER_RESOLUTION_MAX_NODES do
        local node = queue[head]
        head = head + 1

        local key = object_key(node.obj)
        if not visited[key] then
            visited[key] = true
            processed = processed + 1

            local special_owner, special_method =
                resolve_special_summon_owner(node.obj, node.path)
            if special_owner ~= nil then
                owner_resolution_cache[root_key] = {
                    owner = special_owner,
                    method = special_method,
                    time = t
                }
                return special_owner, special_method
            end

            local display, internal, class_name =
                resolve_character_object(node.obj)
            if display ~= nil then
                local method = string.format(
                    "%s class=%s internal=%s",
                    node.path,
                    class_name or "nil",
                    internal or "nil"
                )
                owner_resolution_cache[root_key] = {
                    owner = display,
                    method = method,
                    time = t
                }
                return display, method
            end

            if node.depth < 3 then
                for _, property_name in ipairs(OWNER_PROPERTIES) do
                    local child = get_property(node.obj, property_name)
                    if child ~= nil then
                        queue[#queue + 1] = {
                            obj = child,
                            path = node.path .. "." .. property_name,
                            depth = node.depth + 1
                        }
                    end
                end
            end
        end
    end

    local method = processed >= OWNER_RESOLUTION_MAX_NODES
        and "owner chain node limit reached"
        or "no DsPC owner in chain"

    owner_resolution_cache[root_key] = {
        owner = false,
        method = method,
        time = t
    }
    return nil, method
end

local function describe_object(obj)
    if obj == nil then return "nil" end
    return string.format(
        "%s/%s",
        object_class_name(obj) or "unknown-class",
        object_name(obj) or "unknown-object"
    )
end

local function describe_owner_chain(root)
    if root == nil then return "root=nil" end

    local queue = {{ obj = root, path = "root", depth = 0 }}
    local visited = {}
    local output = {}
    local head = 1

    while head <= #queue and #output < OWNER_CHAIN_DIAGNOSTIC_NODES do
        local node = queue[head]
        head = head + 1

        local key = object_key(node.obj)
        if not visited[key] then
            visited[key] = true
            output[#output + 1] = string.format(
                "%s=%s",
                node.path,
                describe_object(node.obj)
            )

            if node.depth < OWNER_CHAIN_DIAGNOSTIC_DEPTH then
                for _, property_name in ipairs(OWNER_PROPERTIES) do
                    local child = get_property(node.obj, property_name)
                    if child ~= nil then
                        queue[#queue + 1] = {
                            obj = child,
                            path = node.path .. "." .. property_name,
                            depth = node.depth + 1
                        }
                    end
                end
            end
        end
    end

    return table.concat(output, " > ")
end

local function resolve_target_last_attacker(target, phase)
    if target == nil then
        return nil, "target=nil"
    end

    local valid = safe_call(function() return target:IsValid() end, false)
    if not valid then
        return nil, "target=invalid"
    end

    local t = now()
    local target_key = object_key(target)
    local attacker = get_property(target, "LastAttacker")

    if attacker == nil then
        local cached = special_target_owner_cache[target_key]
        if cached ~= nil
            and (t - (cached.time or -999.0))
                <= DANA_GOLEM_TARGET_GRACE_SECONDS
        then
            set_current_enemy(target)
            return cached.owner, string.format(
                "target_last_attacker phase=%s target=%s via=recent_exact_golem age=%.0fms",
                tostring(phase or "unknown"),
                object_name(target) or "unknown",
                (t - cached.time) * 1000.0
            )
        end

        special_target_owner_cache[target_key] = nil
        return nil, "target_last_attacker=nil"
    end

    -- Direct check is intentionally before the generic owner-chain cache.
    -- The exact attacker class was captured in the controlled diagnostic.
    local special_owner, special_method =
        resolve_special_summon_owner(
            attacker,
            "target.LastAttacker"
        )

    if special_owner ~= nil then
        special_target_owner_cache[target_key] = {
            owner = special_owner,
            time = t
        }
        set_current_enemy(target)
        return special_owner, string.format(
            "target_last_attacker phase=%s target=%s via=%s",
            tostring(phase or "unknown"),
            object_name(target) or "unknown",
            special_method or "exact_dana_golem"
        )
    end

    -- A concrete non-golem attacker replaces any transient target cache.
    special_target_owner_cache[target_key] = nil

    local owner, owner_method = resolve_owner_chain(attacker)
    if owner == nil or owner == "Unknown" then
        return nil, "target_last_attacker_unresolved"
    end

    set_current_enemy(target)
    return owner, string.format(
        "target_last_attacker phase=%s target=%s via=%s",
        tostring(phase or "unknown"),
        object_name(target) or "unknown",
        owner_method or "unknown"
    )
end

local function prune_owner_resolution_cache(force)
    local t = now()
    if not force
        and (t - last_owner_cache_prune) < OWNER_CACHE_PRUNE_SECONDS
    then
        return
    end
    last_owner_cache_prune = t

    for key, entry in pairs(owner_resolution_cache) do
        if entry == nil or (t - (entry.time or -999.0)) > OWNER_CACHE_SECONDS then
            owner_resolution_cache[key] = nil
        end
    end

    for key, entry in pairs(special_target_owner_cache) do
        if entry == nil
            or (t - (entry.time or -999.0))
                > DANA_GOLEM_TARGET_GRACE_SECONDS
        then
            special_target_owner_cache[key] = nil
        end
    end
end

local function infer_from_roster_tokens(class_name)
    if class_name == nil then return nil, nil end

    local lower_class = class_name:lower()
    local best_internal = nil
    local best_length = 0

    for internal, _ in pairs(roster_internal) do
        local token = internal:lower()
        if #token > best_length and lower_class:find(token, 1, true) then
            best_internal = internal
            best_length = #token
        end
    end

    if best_internal ~= nil then
        return roster_display[best_internal], best_internal
    end

    return nil, nil
end

local function update_active_character_from_controller(pc)
    if pc == nil then return end

    local idx = tonumber(safe_call(function()
        return pc.CurrentPCIndex
    end, -1)) or -1

    local candidate = get_property(pc, "Character")
    if candidate == nil then candidate = get_property(pc, "Pawn") end
    if candidate == nil then
        candidate = get_property(pc, "AcknowledgedPawn")
    end

    local display, internal, class_name = resolve_character_object(candidate)
    if display == nil then
        display = active_name or "Unknown"
    end

    local changed = idx ~= active_pc or display ~= active_name
    if changed then
        local old_idx = active_pc
        local old_name = active_name

        previous_active_name = old_name
        swap_time = now()
        carryover_enabled = false

        active_pc = idx
        active_name = display
        active_internal = internal
        state_dirty = true

        append_line("ACTIVE_CHARACTER", string.format(
            "from=%d:%s to=%d:%s internal=%s pawn_class=%s carryover=false",
            old_idx,
            old_name or "nil",
            active_pc,
            active_name,
            active_internal or "nil",
            class_name or "nil"
        ))
    end
end

local function update_active_character()
    -- Compatibility no-op. UObject polling was removed from LoopAsync.
end

local function prune_sources(t, force)
    if not force
        and (t - last_source_prune) < SOURCE_PRUNE_SECONDS
    then
        return
    end
    last_source_prune = t

    for key, item in pairs(source_records) do
        local anchor_time = item.last_match_time or item.time
        if (t - anchor_time) > SOURCE_KEEP_SECONDS then
            source_records[key] = nil
            source_record_count = math.max(
                0,
                source_record_count - 1
            )
        end
    end
end

local function remove_oldest_source_record()
    local oldest_key = nil
    local oldest_time = math.huge

    for key, item in pairs(source_records) do
        local anchor_time = item.last_match_time or item.time or -999.0
        if anchor_time < oldest_time then
            oldest_time = anchor_time
            oldest_key = key
        end
    end

    if oldest_key ~= nil then
        source_records[oldest_key] = nil
        source_record_count = math.max(
            0,
            source_record_count - 1
        )
    end
end

local function remember_source(
    source_key,
    target_key,
    class_name,
    obj_name,
    owner,
    owner_method,
    t
)
    local record_key = source_key
    if target_key ~= nil and target_key ~= "nil" then
        record_key = source_key .. "->" .. target_key
    end

    local item = source_records[record_key]

    source_record_sequence = source_record_sequence + 1

    if item ~= nil then
        item.time = t
        item.sequence = source_record_sequence
        item.target_key = target_key
        item.character_name = owner
        item.owner_method = owner_method
        item.class_name = class_name
        item.object_name = obj_name
        item.last_match_time = nil
        item.match_count = 0
        return item, false
    end

    item = {
        time = t,
        sequence = source_record_sequence,
        record_key = record_key,
        source_key = source_key,
        target_key = target_key,
        class_name = class_name,
        object_name = obj_name,
        character_name = owner,
        owner_method = owner_method,
        last_match_time = nil,
        match_count = 0
    }

    source_records[record_key] = item
    source_record_count = source_record_count + 1

    if source_record_count > SOURCE_QUEUE_MAX_RECORDS then
        prune_sources(t, true)
        while source_record_count > SOURCE_QUEUE_MAX_RECORDS do
            remove_oldest_source_record()
        end
    end

    return item, true
end

local function consume_best_source(
    damage_time,
    target_key,
    preferred_character,
    require_exact_target
)
    local best_item = nil
    local best_distance = nil
    local best_delta = nil
    local best_sequence = -1

    for _, item in pairs(source_records) do
        local character_matches = (
            preferred_character == nil
            or item.character_name == preferred_character
        )

        local target_matches = true
        if require_exact_target then
            target_matches = (
                target_key ~= nil
                and target_key ~= "nil"
                and item.target_key == target_key
            )
        elseif item.target_key ~= nil
            and target_key ~= nil
            and target_key ~= "nil"
            and item.target_key ~= target_key
        then
            target_matches = false
        end

        if character_matches
            and target_matches
            and item.character_name ~= nil
            and item.character_name ~= "Unknown"
        then
            local anchor_time = item.last_match_time or item.time
            local delta = damage_time - anchor_time
            local first_delta = damage_time - item.time

            local is_tarte = item.character_name == "Tarte"
            local initial_window = is_tarte
                and TARTE_SOURCE_MATCH_WINDOW_SECONDS
                or SOURCE_MATCH_WINDOW_SECONDS
            local burst_window = is_tarte
                and TARTE_SOURCE_BURST_REUSE_SECONDS
                or SOURCE_BURST_REUSE_SECONDS
            local burst_max_hits = is_tarte
                and TARTE_SOURCE_BURST_MAX_HITS
                or SOURCE_BURST_MAX_HITS

            local valid_initial = (
                first_delta >= 0
                and first_delta <= initial_window
            ) or (
                first_delta < 0
                and (-first_delta) <= SOURCE_AFTER_DAMAGE_SECONDS
            )

            local valid_burst = (
                item.last_match_time ~= nil
                and delta >= 0
                and delta <= burst_window
                and (item.match_count or 0) < burst_max_hits
            )

            if valid_initial or valid_burst then
                local distance = math.abs(delta)
                local sequence = item.sequence or 0
                if best_distance == nil
                    or distance < best_distance
                    or (
                        distance == best_distance
                        and sequence > best_sequence
                    )
                then
                    best_item = item
                    best_distance = distance
                    best_delta = first_delta
                    best_sequence = sequence
                end
            end
        end
    end

    if best_item ~= nil then
        best_item.last_match_time = damage_time
        best_item.match_count = (best_item.match_count or 0) + 1
        return best_item, best_delta
    end

    return nil, nil
end

local function elapsed_at(t)
    if not session_started and not session_finished then return 0.0 end
    local effective_time = session_finished and session_end_time or t
    local value = effective_time - session_start_time
    if value < 0 then return 0.0 end
    return value
end

local function total_damage()
    local total = 0.0
    for _, name in ipairs(character_order) do
        total = total + (totals[name] or 0.0)
    end
    return total
end

local function write_text_atomic(path, temp_path, text)
    local ok = pcall(function()
        local f = assert(io.open(temp_path, "w"))
        assert(f:write(text))
        assert(f:close())
        os.remove(path)
        assert(os.rename(temp_path, path))
    end)

    if not ok then
        pcall(function() os.remove(temp_path) end)
    end
    return ok
end

local function append_text(path, text)
    return pcall(function()
        local f = assert(io.open(path, "a"))
        assert(f:write(text))
        assert(f:close())
    end)
end

local flush_timeline_events

local function write_state(force)
    local t = now()
    if not force then
        if not state_dirty then return end
        if (t - last_state_write) < STATE_WRITE_SECONDS then return end
    end
    last_state_write = t

    local elapsed = elapsed_at(t)
    local total = total_damage()
    local overall_dps = elapsed > 0 and total / elapsed or 0.0
    local status = session_started and "COMBAT"
        or (session_finished and "ENDED" or "READY")

    local lines = {
        "version=4\n",
        "status=" .. status .. "\n",
        "active=" .. (active_name or "Unknown") .. "\n"
    }

    local enemy_for_state = current_enemy_name or "Unknown"
    if (t - current_enemy_time) > ENEMY_NAME_KEEP_SECONDS then
        enemy_for_state = "Unknown"
    end

    lines[#lines + 1] = "enemy=" .. enemy_for_state .. "\n"
    lines[#lines + 1] = string.format("elapsed=%.3f\n", elapsed)
    lines[#lines + 1] = string.format("total=%.1f\n", total)
    lines[#lines + 1] = string.format("overall_dps=%.1f\n", overall_dps)

    for _, name in ipairs(character_order) do
        local damage = totals[name] or 0.0
        local dps = elapsed > 0 and damage / elapsed or 0.0
        local share = total > 0 and damage / total * 100.0 or 0.0
        lines[#lines + 1] = string.format(
            "character=%s|%.1f|%.1f|%.2f|%d|%d|%.1f|%.1f\n",
            name, damage, dps, share, hits[name] or 0, crits[name] or 0,
            highest_hits[name] or 0.0,
            (hits[name] or 0) > 0 and damage / (hits[name] or 1) or 0.0
        )
    end

    if not write_text_atomic(STATE_FILE, STATE_TMP, table.concat(lines)) then
        -- Keep the last valid UI snapshot and retry on the next throttled pass.
        state_dirty = true
        return
    end

    state_dirty = false
    flush_timeline_events(force == true)
end

local function json_escape(value)
    local s = tostring(value or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
    return s
end

local function csv_escape(value)
    local s = tostring(value or "")
    if s:find('[,"\r\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
    return s
end

local function battle_json(reason, t)
    local elapsed = elapsed_at(t)
    local total = total_damage()
    local parts = {
        "{",
        '"timestamp":"' .. json_escape(os.date("!%Y-%m-%dT%H:%M:%SZ")) .. '",',
        '"reason":"' .. json_escape(reason or "manual") .. '",',
        '"target":"' .. json_escape(current_enemy_name or "Unknown") .. '",',
        string.format('"duration":%.3f,', elapsed),
        string.format('"total_damage":%.1f,', total),
        string.format('"dps":%.1f,', elapsed > 0 and total / elapsed or 0.0),
        '"events_truncated":' .. (combat_events_truncated and "true" or "false") .. ',',
        '"characters":['
    }
    local first = true
    for _, name in ipairs(character_order) do
        local damage = totals[name] or 0.0
        if damage > 0 then
            if not first then table.insert(parts, ",") end
            first = false
            local hc, cc = hits[name] or 0, crits[name] or 0
            table.insert(parts, string.format(
                '{"name":"%s","damage":%.1f,"dps":%.1f,"share":%.2f,"hits":%d,"crits":%d,"crit_rate":%.2f,"highest_hit":%.1f,"average_hit":%.1f}',
                json_escape(name), damage, elapsed > 0 and damage / elapsed or 0.0,
                total > 0 and damage / total * 100.0 or 0.0, hc, cc,
                hc > 0 and cc / hc * 100.0 or 0.0, highest_hits[name] or 0.0,
                hc > 0 and damage / hc or 0.0
            ))
        end
    end
    table.insert(parts, '],"events":[')

    local first_event = true
    local event_chunk = {}
    local event_chunk_size = 256

    for _, event in ipairs(combat_events) do
        event_chunk[#event_chunk + 1] = string.format(
            '%s{"time":%.3f,"character":"%s","damage":%.1f,"critical":%s}',
            first_event and "" or ",",
            event.time or 0.0,
            json_escape(event.character or "Unknown"),
            event.damage or 0.0,
            event.critical and "true" or "false"
        )
        first_event = false

        if #event_chunk >= event_chunk_size then
            parts[#parts + 1] = table.concat(event_chunk)
            event_chunk = {}
        end
    end

    if #event_chunk > 0 then
        parts[#parts + 1] = table.concat(event_chunk)
    end

    parts[#parts + 1] = "]}"
    return table.concat(parts)
end

local function export_battle(reason)
    if (not session_started and not session_finished) or total_damage() <= 0 then
        return false
    end

    local t = now()
    local json = battle_json(reason, t)
    local latest_json_saved = write_text_atomic(
        EXPORT_JSON_FILE,
        EXPORT_JSON_FILE .. ".tmp",
        json .. "\n"
    )
    local history_saved = append_text(HISTORY_FILE, json .. "\n")

    local elapsed = elapsed_at(t)
    local total = total_damage()
    local csv_lines = {
        "Character,Damage,DPS,SharePercent,Hits,Crits,CritRatePercent,HighestHit,AverageHit\n"
    }

    for _, name in ipairs(character_order) do
        local damage = totals[name] or 0.0
        if damage > 0 then
            local hc, cc = hits[name] or 0, crits[name] or 0
            csv_lines[#csv_lines + 1] = string.format(
                "%s,%.1f,%.1f,%.2f,%d,%d,%.2f,%.1f,%.1f\n",
                csv_escape(name),
                damage,
                elapsed > 0 and damage / elapsed or 0.0,
                total > 0 and damage / total * 100.0 or 0.0,
                hc,
                cc,
                hc > 0 and cc / hc * 100.0 or 0.0,
                highest_hits[name] or 0.0,
                hc > 0 and damage / hc or 0.0
            )
        end
    end

    local latest_csv_saved = write_text_atomic(
        EXPORT_CSV_FILE,
        EXPORT_CSV_FILE .. ".tmp",
        table.concat(csv_lines)
    )

    append_line(
        history_saved and "BATTLE_EXPORTED" or "BATTLE_EXPORT_FAILED",
        "reason=" .. tostring(reason)
            .. " history_saved=" .. tostring(history_saved)
            .. " latest_json=" .. tostring(latest_json_saved)
            .. " latest_csv=" .. tostring(latest_csv_saved)
    )
    return history_saved
end

flush_timeline_events = function(force)
    if #timeline_pending_lines == 0 then return end

    local t = now()
    if not force
        and #timeline_pending_lines < TIMELINE_FLUSH_MAX_LINES
        and (t - timeline_last_flush) < TIMELINE_FLUSH_SECONDS then
        return
    end

    if not append_text(TIMELINE_FILE, table.concat(timeline_pending_lines)) then
        return
    end

    timeline_pending_lines = {}
    timeline_last_flush = t
end

local function append_timeline_event(t, owner, damage, critical)
    local relative_time = elapsed_at(t)

    if #combat_events < MAX_HISTORY_EVENTS then
        table.insert(combat_events, {
            time = relative_time,
            character = owner,
            damage = damage,
            critical = critical == true,
        })
    else
        combat_events_truncated = true
    end

    timeline_pending_lines[#timeline_pending_lines + 1] = string.format(
        "%.3f,%s,%.1f,%s\n",
        relative_time,
        csv_escape(owner),
        damage,
        critical and "1" or "0"
    )
end

local function clear_values()
    combat_generation = combat_generation + 1
    source_records = {}
    source_record_count = 0
    source_record_sequence = 0
    clear_pending_damage_events()
    combat_events = {}
    combat_events_truncated = false
    timeline_pending_lines = {}
    timeline_last_flush = now()
    attribution_diagnostic_count = 0
    source_diagnostic_count = 0
    allied_target_diagnostic_count = 0
    owner_resolution_cache = {}
    special_summon_logged = {}
    special_target_owner_cache = {}
    last_source_prune = -999.0

    for _, name in ipairs(character_order) do
        totals[name] = 0.0
        hits[name] = 0
        crits[name] = 0
        highest_hits[name] = 0.0
    end

    session_started = false
    session_finished = false
    session_start_time = 0.0
    session_end_time = 0.0
    last_outgoing_damage_time = -999.0
    session_auto_saved = false
    current_enemy_name = "Unknown"
    current_enemy_time = -999.0
    last_enemy_object_key = nil
    state_dirty = true
end

local function reset_meter(reason)
    local reset_reason = tostring(reason or "manual")
    local has_damage = total_damage() > 0
    local archived = not has_damage

    if has_damage and session_auto_saved then
        -- The encounter is already present in battle_history.jsonl. Do not add
        -- a duplicate row when the user clears the meter afterward.
        archived = true
        append_line("RESET_ARCHIVE_ALREADY_SAVED", reset_reason)
    elseif has_damage then
        archived = export_battle("reset:" .. reset_reason)
    end

    -- Never destroy an unsaved encounter. A locked history file can be retried
    -- by pressing RESET again after the lock is released.
    if has_damage and not archived then
        append_line("RESET_ABORTED_SAVE_FAILED", reset_reason)
        state_dirty = true
        write_state(true)
        return false
    end

    clear_values()
    write_text_atomic(
        TIMELINE_FILE,
        TIMELINE_FILE .. ".tmp",
        "Time,Character,Damage,Critical\n"
    )
    append_line(
        "METER_RESET",
        reset_reason .. " archived=" .. tostring(archived)
    )
    write_state(true)
    return true
end

local write_snapshot

local function archive_finished_session(reason)
    if total_damage() <= 0 then
        session_auto_saved = true
        return true
    end

    if session_auto_saved then
        return true
    end

    local saved = write_snapshot(reason) == true
    if saved then
        session_auto_saved = true
    end
    return saved
end

local function ensure_session(t)
    if session_finished then
        local previous_damage = total_damage()

        -- Never clear an automatically ended raid phase until it has been
        -- appended to battle_history.jsonl.
        local archived = archive_finished_session(
            "auto before new encounter"
        )

        if previous_damage > 0 and not archived then
            -- Preserve all totals if the history file is temporarily locked.
            -- The new damage extends the current encounter and the save is
            -- retried at the next idle boundary or manual RESET.
            session_started = true
            session_finished = false
            session_end_time = 0.0
            append_line(
                "AUTO_RESET_ABORTED_SAVE_FAILED",
                "continuing previous encounter without clearing totals"
            )
            state_dirty = true
            return
        end

        clear_values()
        write_text_atomic(
            TIMELINE_FILE,
            TIMELINE_FILE .. ".tmp",
            "Time,Character,Damage,Critical\n"
        )
        append_line(
            "AUTO_RESET_AFTER_SAVE",
            "previous_damage=" .. tostring(previous_damage)
        )
    end

    if not session_started then
        session_started = true
        session_finished = false
        session_auto_saved = false
        session_start_time = t
        session_end_time = 0.0
        append_line("SESSION_START", "first outgoing damage")
        state_dirty = true
    end
end

local function finish_session_if_idle(t)
    if not session_started then return end
    if (t - last_outgoing_damage_time) < COMBAT_END_IDLE_SECONDS then return end

    session_end_time = last_outgoing_damage_time
    if session_end_time < session_start_time then
        session_end_time = t
    end

    local duration = session_end_time - session_start_time

    -- Mark the encounter ended before exporting so elapsed_at() excludes the
    -- idle-detection delay.
    session_started = false
    session_finished = true
    state_dirty = true

    session_auto_saved = archive_finished_session(
        "auto combat end"
    )

    append_line(
        session_auto_saved
            and "SESSION_AUTO_SAVED"
            or "SESSION_AUTO_SAVE_FAILED",
        string.format(
            "duration=%.3fs idle=%.3fs minimum=%.3fs",
            duration,
            t - last_outgoing_damage_time,
            AUTO_SAVE_MIN_DURATION_SECONDS
        )
    )

    write_state(true)
end

-- Snapshot records the current cumulative encounter without resetting totals.
write_snapshot = function(reason)
    local t = now()
    local elapsed = elapsed_at(t)
    local total = total_damage()
    local total_dps = elapsed > 0 and total / elapsed or 0.0

    append_line("DPS_SUMMARY", string.format(
        "reason=%s elapsed=%.3fs total=%.1f total_dps=%.1f",
        reason or "manual", elapsed, total, total_dps
    ))

    for _, name in ipairs(character_order) do
        local damage = totals[name] or 0.0
        if damage > 0 then
            local dps = elapsed > 0 and damage / elapsed or 0.0
            local share = total > 0 and damage / total * 100.0 or 0.0
            local hit_count = hits[name] or 0
            local crit_count = crits[name] or 0
            local crit_rate = hit_count > 0 and crit_count / hit_count * 100.0 or 0.0

            append_line("DPS_CHARACTER", string.format(
                "name=%s damage=%.1f dps=%.1f share=%.2f%% hits=%d crits=%d crit_rate=%.2f%%",
                name, damage, dps, share, hit_count, crit_count, crit_rate
            ))
        end
    end

    return export_battle(
        "snapshot:" .. tostring(reason or "manual")
    )
end

local function read_param(param, default)
    local direct = safe_call(function() return param:get() end, nil)
    if direct ~= nil then return direct end
    if param ~= nil then return param end
    return default
end

local function commit_damage_event(event, owner, method)
    if event.generation ~= combat_generation then
        append_line("DAMAGE_DROPPED_AFTER_RESET", string.format(
            "damage=%.1f event_generation=%d current_generation=%d",
            event.damage,
            event.generation or -1,
            combat_generation
        ))
        return
    end

    owner = register_character(owner)
    totals[owner] = totals[owner] + event.damage
    hits[owner] = hits[owner] + 1
    highest_hits[owner] = math.max(
        highest_hits[owner] or 0.0,
        event.damage
    )
    if event.critical then
        crits[owner] = crits[owner] + 1
    end

    append_timeline_event(
        event.time,
        owner,
        event.damage,
        event.critical
    )
    last_outgoing_damage_time = event.time
    state_dirty = true

    if VERBOSE_DAMAGE_LOG then
        append_line("DAMAGE", string.format(
            "owner=%s damage=%.1f critical=%s method=%s captured_active=%d:%s current_active=%d:%s owner_total=%.1f",
            owner,
            event.damage,
            tostring(event.critical),
            method or "unknown",
            event.active_index,
            event.active_name,
            active_pc,
            active_name,
            totals[owner]
        ))
    end
end

local function finalize_damage_event(
    event,
    target_owner,
    target_method,
    target_key,
    target_match_method,
    target_distance,
    diagnostic_attacker,
    diagnostic_chain
)
    if event.generation ~= combat_generation then
        return
    end

    local owner = nil
    local method = nil

    -- Chako overlap callbacks provide an exact source + target pair. This must
    -- be checked before the batch-time LastAttacker because another character
    -- can overwrite LastAttacker after the player swaps but before the shared
    -- batch is resolved.
    local chako_source, chako_delta = consume_best_source(
        event.time,
        target_key,
        DANA_GOLEM_DISPLAY,
        true
    )

    if chako_source ~= nil then
        owner = DANA_GOLEM_DISPLAY
        method = string.format(
            "exact_chako_source_target delta=%.1fms via=%s class=%s obj=%s",
            chako_delta * 1000.0,
            chako_source.owner_method or "unknown",
            chako_source.class_name or "nil",
            chako_source.object_name or "nil"
        )
    elseif target_owner ~= nil and target_owner ~= "Unknown" then
        owner = target_owner
        method = target_method or "target_last_attacker"
    else
        local source, delta = consume_best_source(
            event.time,
            target_key,
            nil,
            false
        )

        if source ~= nil then
            owner = source.character_name
            method = string.format(
                "explicit_source_fallback delta=%.1fms via=%s class=%s obj=%s",
                delta * 1000.0,
                source.owner_method or "unknown",
                source.class_name or "nil",
                source.object_name or "nil"
            )
        else
            owner = event.active_name
            method = "captured_active_pawn_fallback"

            if attribution_diagnostic_count
                < ATTRIBUTION_DIAGNOSTIC_LIMIT
            then
                attribution_diagnostic_count =
                    attribution_diagnostic_count + 1

                append_line(
                    "ATTRIBUTION_ACTIVE_FALLBACK",
                    string.format(
                        "damage=%.1f critical=%s target=%s target_match=%s distance=%s captured_active=%d:%s last_attacker=%s chain=%s",
                        event.damage,
                        tostring(event.critical),
                        target_key or "nil",
                        tostring(target_match_method or "unknown"),
                        target_distance ~= nil
                            and string.format("%.1f", target_distance)
                            or "nil",
                        event.active_index,
                        event.active_name,
                        diagnostic_attacker or "not captured",
                        diagnostic_chain or "not captured"
                    )
                )
            end
        end
    end

    commit_damage_event(event, owner, method)
end

local function take_damage_batch()
    local queued = pending_damage_events
    pending_damage_events = {}

    if #queued <= DAMAGE_BATCH_MAX_EVENTS then
        return queued
    end

    local batch = {}
    local remaining = {}

    for index, event in ipairs(queued) do
        if index <= DAMAGE_BATCH_MAX_EVENTS then
            batch[#batch + 1] = event
        else
            remaining[#remaining + 1] = event
        end
    end

    -- There should be no concurrent game-thread damage callback while this
    -- function runs, but prepend the older remainder if another callback was
    -- queued by the runtime.
    if #pending_damage_events > 0 then
        for _, event in ipairs(pending_damage_events) do
            remaining[#remaining + 1] = event
        end
    end
    pending_damage_events = remaining

    return batch
end

local schedule_damage_batch

local function process_damage_batch_without_unreal(token)
    if token ~= damage_batch_token then
        return
    end

    damage_batch_scheduled = false
    local batch = take_damage_batch()

    for _, event in ipairs(batch) do
        finalize_damage_event(
            event,
            nil,
            nil,
            event.target_key,
            "unreal_batch_unavailable",
            nil,
            "not captured",
            "not captured"
        )
    end

    if #pending_damage_events > 0 then
        schedule_damage_batch(DAMAGE_BATCH_CONTINUATION_MS)
    end
end

local function process_damage_batch_game_thread(token)
    if token ~= damage_batch_token then
        return
    end

    damage_batch_scheduled = false
    local batch = take_damage_batch()
    if #batch == 0 then
        return
    end

    prune_sources(now(), false)

    -- One transient UObject snapshot is shared by the entire burst. The
    -- snapshot and every actor reference remain local to this game-thread
    -- callback and are released before it returns.
    local snapshot = nil
    local snapshot_reason = "monster_snapshot_failed"
    local snapshot_ok, snapshot_value, reason_value = pcall(
        build_monster_snapshot
    )

    if snapshot_ok then
        snapshot = snapshot_value
        snapshot_reason = reason_value or "monster_snapshot_ready"
    else
        snapshot_reason = tostring(snapshot_value)
        if hook_callback_error_count < 12 then
            hook_callback_error_count =
                hook_callback_error_count + 1
            append_line(
                "MONSTER_SNAPSHOT_ERROR",
                snapshot_reason
            )
        end
    end

    local match_cache = {}
    local resolution_cache = {}

    for _, event in ipairs(batch) do
        local target_owner = nil
        local target_method = nil
        local target_key = event.target_key
        local target_distance = nil
        local target_match_method = snapshot_reason
        local diagnostic_attacker = "not captured"
        local diagnostic_chain = "not captured"
        local ignore_allied_target = false

        local resolution_ok, resolution_error = pcall(function()
            local target_entry
            target_entry, target_distance, target_match_method =
                find_target_in_snapshot(
                    snapshot,
                    event.hit_x,
                    event.hit_y,
                    event.hit_z,
                    match_cache
                )

            if target_entry == nil then
                target_match_method =
                    target_match_method
                    or snapshot_reason
                    or "target_unavailable"
                return
            end

            target_key = target_entry.key

            if target_entry.allied then
                ignore_allied_target = true
                if allied_target_diagnostic_count < 4 then
                    allied_target_diagnostic_count =
                        allied_target_diagnostic_count + 1
                    append_line(
                        "DAMAGE_IGNORED_ALLIED_TARGET",
                        string.format(
                            "damage=%.1f target=%s active=%d:%s",
                            event.damage,
                            target_key or "nil",
                            event.active_index,
                            event.active_name
                        )
                    )
                end
                return
            end

            local resolution = resolution_cache[target_key]
            if resolution == nil then
                local owner, method = resolve_target_last_attacker(
                    target_entry.actor,
                    "game_thread_batch"
                )

                resolution = {
                    owner = owner,
                    method = method,
                    diagnostic_attacker = "not captured",
                    diagnostic_chain = "not captured"
                }

                if owner == nil
                    and attribution_diagnostic_count
                        < ATTRIBUTION_DIAGNOSTIC_LIMIT
                then
                    local attacker = get_property(
                        target_entry.actor,
                        "LastAttacker"
                    )
                    resolution.diagnostic_attacker =
                        describe_object(attacker)
                    resolution.diagnostic_chain =
                        describe_owner_chain(attacker)
                end

                resolution_cache[target_key] = resolution
            end

            target_owner = resolution.owner
            target_method = resolution.method
            diagnostic_attacker =
                resolution.diagnostic_attacker
            diagnostic_chain =
                resolution.diagnostic_chain
        end)

        if not resolution_ok then
            if hook_callback_error_count < 12 then
                hook_callback_error_count =
                    hook_callback_error_count + 1
                append_line(
                    "DAMAGE_RESOLUTION_ERROR",
                    tostring(resolution_error)
                )
            end
        end

        if not ignore_allied_target then
            local commit_ok, commit_error = pcall(function()
                finalize_damage_event(
                    event,
                    target_owner,
                    target_method,
                    target_key,
                    target_match_method,
                    target_distance,
                    diagnostic_attacker,
                    diagnostic_chain
                )
            end)

            if not commit_ok and hook_callback_error_count < 12 then
                hook_callback_error_count =
                    hook_callback_error_count + 1
                append_line(
                    "DAMAGE_COMMIT_ERROR",
                    tostring(commit_error)
                )
            end
        end
    end

    -- Explicitly discard every transient UObject container before scheduling
    -- another batch.
    snapshot = nil
    match_cache = nil
    resolution_cache = nil
    batch = nil

    if #pending_damage_events > 0 then
        schedule_damage_batch(DAMAGE_BATCH_CONTINUATION_MS)
    end
end

schedule_damage_batch = function(delay_override_ms)
    if damage_batch_scheduled or #pending_damage_events == 0 then
        return
    end

    damage_batch_scheduled = true
    local token = damage_batch_token
    local delay_ms = delay_override_ms
        or math.floor(DAMAGE_DEFER_SECONDS * 1000.0)

    if ExecuteWithDelay ~= nil and ExecuteInGameThread ~= nil then
        local scheduled_ok, scheduled_error = pcall(function()
            ExecuteWithDelay(delay_ms, function()
                if token ~= damage_batch_token then
                    return
                end

                local queued_ok, queued_error = pcall(function()
                    ExecuteInGameThread(function()
                        local ok, err = pcall(function()
                            process_damage_batch_game_thread(token)
                        end)

                        if not ok
                            and hook_callback_error_count < 12
                        then
                            hook_callback_error_count =
                                hook_callback_error_count + 1
                            append_line(
                                "GAME_THREAD_BATCH_ERROR",
                                tostring(err)
                            )
                            process_damage_batch_without_unreal(token)
                        end
                    end)
                end)

                if not queued_ok then
                    if hook_callback_error_count < 12 then
                        hook_callback_error_count =
                            hook_callback_error_count + 1
                        append_line(
                            "GAME_THREAD_QUEUE_ERROR",
                            tostring(queued_error)
                        )
                    end
                    process_damage_batch_without_unreal(token)
                end
            end)
        end)

        if scheduled_ok then
            return
        end

        if hook_callback_error_count < 12 then
            hook_callback_error_count =
                hook_callback_error_count + 1
            append_line(
                "DAMAGE_BATCH_DELAY_ERROR",
                tostring(scheduled_error)
            )
        end
    end

    process_damage_batch_without_unreal(token)
end

local function enqueue_damage_event(event)
    if #pending_damage_events >= DAMAGE_QUEUE_HARD_LIMIT then
        if not damage_queue_overflow_logged then
            damage_queue_overflow_logged = true
            append_line(
                "DAMAGE_QUEUE_PRESSURE",
                string.format(
                    "limit=%d; preserving damage with captured attribution",
                    DAMAGE_QUEUE_HARD_LIMIT
                )
            )
        end

        finalize_damage_event(
            event,
            nil,
            nil,
            event.target_key,
            "queue_pressure_fallback",
            nil,
            "not captured",
            "not captured"
        )
        return
    end

    pending_damage_events[#pending_damage_events + 1] = event
    schedule_damage_batch(nil)
end

local function process_window_command()
    local t = now()
    if (t - last_command_poll) < COMMAND_POLL_SECONDS then return end
    last_command_poll = t

    local f = io.open(COMMAND_FILE, "r")
    if not f then return end
    local command = f:read("*l")
    f:close()
    os.remove(COMMAND_FILE)

    if command == "RESET" then
        reset_meter("window button")
    end
end

local function launch_window()
    -- Proven detached launch path from the last confirmed working builds.
    -- START returns immediately, so WPF ShowDialog never blocks UE4SS.
    local primary_command =
        'cmd.exe /d /s /c start "" /b "%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "'
        .. WINDOW_SCRIPT .. '"'

    local primary_ok, primary_result = pcall(function()
        return os.execute(primary_command)
    end)

    local launched = primary_ok and (
        primary_result == true or primary_result == 0
    )
    local method = "cmd-start-powershell"

    if not launched then
        method = "wscript-fallback"
        local fallback_command =
            'wscript.exe //B //Nologo "' .. WINDOW_LAUNCHER .. '"'
        local fallback_ok, fallback_result = pcall(function()
            return os.execute(fallback_command)
        end)
        launched = fallback_ok and (
            fallback_result == true or fallback_result == 0
        )
        primary_ok = fallback_ok
        primary_result = fallback_result
    end

    window_launched = launched
    append_line(
        "WINDOW_LAUNCH",
        "method=" .. method ..
        " launched=" .. tostring(launched) ..
        " ok=" .. tostring(primary_ok) ..
        " result=" .. tostring(primary_result)
    )
end

local function install_hook(path, callback)
    append_line("HOOK_ATTEMPT", path)

    local wrapped_callback = function(...)
        local ok_callback, callback_error = pcall(callback, ...)
        if not ok_callback and hook_callback_error_count < 12 then
            hook_callback_error_count = hook_callback_error_count + 1
            append_line("HOOK_CALLBACK_ERROR", string.format(
                "path=%s error=%s",
                path,
                tostring(callback_error)
            ))
        end
    end

    local ok, result = pcall(function()
        return RegisterHook(path, wrapped_callback)
    end)

    if ok then
        append_line("HOOK_OK", path .. " result=" .. tostring(result))
    else
        append_line("HOOK_FAIL", path .. " error=" .. tostring(result))
    end
end

reset_log_file()
append_line("INIT", "script entered")
register_character("Chako")
write_state(true)

install_hook(
    "/Script/DS.DsAnimationProjectile:OnAttackBeginOverlap",
    function(
        Context,
        OverlappedComp,
        OtherActor,
        OtherComp,
        OtherBodyIndex,
        bFromSweep,
        SweepResult
    )
        if transition_active then return end

        local source = get_property(Context, "SourceActor")
        if source == nil then
            source = Context
        end

        local class_name = object_class_name(source)
        local obj_name = object_name(source)

        local owner, owner_method =
            resolve_special_summon_owner(source, "source")

        if owner == nil then
            local source_token_text = string.format(
                "%s|%s",
                class_name or "",
                obj_name or ""
            )
            if source_token_text:find(
                DANA_GOLEM_SOURCE_TOKEN,
                1,
                true
            ) ~= nil then
                owner = DANA_GOLEM_DISPLAY
                owner_method = "exact_chako_source_token"
            end
        end

        if owner == nil then
            local token_owner, token_internal =
                infer_from_roster_tokens(class_name)
            if token_owner ~= nil then
                owner = token_owner
                owner_method =
                    "roster-token:" .. tostring(token_internal)
            end
        end

        if owner == nil then
            owner, owner_method = resolve_owner_chain(source)
        end

        -- Only player roster members are accepted. Bosses and enemies never
        -- enter the source queue. Every retained record contains only plain Lua
        -- strings and numbers.
        if owner == nil or owner == "Unknown" then
            if VERBOSE_LOGGING
                and source_diagnostic_count < SOURCE_DIAGNOSTIC_LIMIT
            then
                source_diagnostic_count = source_diagnostic_count + 1
                append_line("SOURCE_REJECTED", string.format(
                    "context=%s source=%s reason=%s active=%d:%s chain=%s",
                    describe_object(Context),
                    describe_object(source),
                    owner_method or "not linked to DsPC roster",
                    active_pc,
                    active_name,
                    describe_owner_chain(source)
                ))
            end
            return
        end

        local t = now()
        prune_sources(t, false)

        local other_actor = read_param(OtherActor, nil)
        local target_key = nil
        if other_actor ~= nil
            and not is_allied_summon_actor(other_actor)
        then
            target_key = object_key(other_actor)
        end

        local source_key = object_key(source)
        local _, inserted = remember_source(
            source_key,
            target_key,
            class_name,
            obj_name,
            owner,
            owner_method,
            t
        )

        -- Do not retain any UObject from the overlap callback.
        other_actor = nil

        if VERBOSE_LOGGING then
            append_line("SOURCE_ACCEPTED", string.format(
                "owner=%s via=%s class=%s obj=%s queue=%d inserted=%s active=%d:%s",
                owner,
                owner_method or "unknown",
                class_name or "nil",
                obj_name or "nil",
                source_record_count,
                tostring(inserted),
                active_pc,
                active_name
            ))
        end
    end
)




install_hook(
    "/Script/DS.DsPlayerController:ClientShowDamageText",
    function(Context, Damage, HitLocation, IsPlayer, bCritical)
        if transition_active then return end

        local damage = tonumber(read_param(Damage, 0)) or 0
        local is_player = read_param(IsPlayer, false) == true
        local critical = read_param(bCritical, false) == true

        if is_player then return end
        if damage <= 0 then return end

        -- Capture a swap immediately on the damage callback instead of waiting
        -- for the 250 ms background poll.
        local controller = read_param(Context, Context)
        update_active_character_from_controller(controller)

        local hit_location = read_param(HitLocation, nil)
        local hit_x, hit_y, hit_z = vector_xyz(hit_location)
        local t = now()

        ensure_session(t)

        local event = {
            generation = combat_generation,
            time = t,
            damage = damage,
            critical = critical,
            active_index = active_pc,
            active_name = active_name,
            hit_x = hit_x,
            hit_y = hit_y,
            hit_z = hit_z,
            target_key = "unresolved"
        }

        if VERBOSE_DAMAGE_LOG then
            append_line("DAMAGE_PENDING", string.format(
                "damage=%.1f critical=%s active=%d:%s queue=%d",
                damage,
                tostring(critical),
                active_pc,
                active_name,
                #pending_damage_events + 1
            ))
        end

        -- The queue stores plain Lua values only. One delayed game-thread job
        -- resolves an entire burst instead of scheduling one world scan per hit.
        hit_location = nil
        enqueue_damage_event(event)
    end
)


-- Production build: diagnostic hooks removed to reduce overhead.

-- Reset, show/hide, and click-through hotkeys are registered by the persistent
-- WPF overlay. This allows key bindings to change immediately without adding
-- duplicate UE4SS key callbacks or touching combat attribution.

if LoopAsync then
    LoopAsync(math.floor(ACTIVE_POLL_SECONDS * 1000), function()
        local ok, err = pcall(function()
            local tick_time = now()
            prune_owner_resolution_cache(false)
            prune_sources(tick_time, false)
            finish_session_if_idle(tick_time)
            process_window_command()
            write_state(false)
            flush_timeline_events(false)
        end)

        if not ok and hook_callback_error_count < 12 then
            hook_callback_error_count = hook_callback_error_count + 1
            append_line("BACKGROUND_LOOP_ERROR", tostring(err))
        end
        return false
    end)
else
    append_line("WARN", "LoopAsync unavailable")
end

append_line("INIT_DONE", string.format(
    "hook_context_pawn=true no_persistent_uobject_cache=true coalesced_damage_batches=true one_world_scan_per_batch=true target_last_attacker=true separate_chako_row=true exact_chako_source_target=true bounded_owner_chain=true source_index=true deferred_timeline_io=true owner_cache_pruning=true state_write=%.1fs combat_end_idle=%.1fs auto_save_min=%.1fs source_keep=%.1fs deferred=%.0fms batch_max=%d",
    STATE_WRITE_SECONDS,
    COMBAT_END_IDLE_SECONDS,
    AUTO_SAVE_MIN_DURATION_SECONDS,
    SOURCE_KEEP_SECONDS,
    DAMAGE_DEFER_SECONDS * 1000.0,
    DAMAGE_BATCH_MAX_EVENTS
))

launch_window()
