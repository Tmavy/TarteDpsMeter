local MOD_NAME = "TarteMeter v2.6.0"
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
local SOURCE_KEEP_SECONDS = 6.000
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
local OWNER_CACHE_PRUNE_SECONDS = 10.000
local TARGET_MATCH_MAX_DISTANCE = 3000.0
local ATTRIBUTION_DIAGNOSTIC_LIMIT = 16
local SOURCE_DIAGNOSTIC_LIMIT = 16
local OWNER_CHAIN_DIAGNOSTIC_DEPTH = 4
local OWNER_CHAIN_DIAGNOSTIC_NODES = 14
local DANA_GOLEM_CLASS_TOKEN = "DsMon_Chaco_V2_C"
local DANA_GOLEM_OWNER_TOKEN = "DsMCTR_C"
local DANA_GOLEM_DISPLAY = "Chako"
local DANA_GOLEM_TARGET_GRACE_SECONDS = 2.500
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

local source_queue = {}
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
local TIMELINE_FLUSH_MAX_LINES = 24
local script_start_time = os.clock()
local window_launched = false
local last_state_write = -999.0
local last_command_poll = -999.0
local last_owner_cache_prune = -999.0
local owner_resolution_cache = {}
local attribution_diagnostic_count = 0
local source_diagnostic_count = 0
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

local function find_damage_target_xyz(hx, hy, hz)
    local monsters = safe_call(function()
        return FindAllOf("DsMonsterCharacter")
    end, nil)
    if monsters == nil then
        return nil, nil, "monster_snapshot_unavailable"
    end

    local candidates = {}
    for _, monster in ipairs(monsters) do
        if monster ~= nil and not is_chako_actor(monster) then
            local valid = safe_call(function()
                return monster:IsValid()
            end, false)
            if valid then
                local x, y, z = actor_xyz(monster)
                if x ~= nil then
                    candidates[#candidates + 1] = {
                        actor = monster,
                        x = x,
                        y = y,
                        z = z
                    }
                end
            end
        end
    end

    if #candidates == 0 then
        return nil, nil, "monster_snapshot_empty"
    end

    if hx == nil and #candidates == 1 then
        return candidates[1].actor, nil, "single_monster_snapshot"
    end
    if hx == nil then
        return nil, nil, "hit_location_unavailable"
    end

    local nearest = nil
    local nearest_distance2 = nil
    for _, entry in ipairs(candidates) do
        local dx = entry.x - hx
        local dy = entry.y - hy
        local dz = entry.z - hz
        local distance2 = dx * dx + dy * dy + dz * dz
        if nearest_distance2 == nil or distance2 < nearest_distance2 then
            nearest = entry.actor
            nearest_distance2 = distance2
        end
    end

    if nearest == nil then
        return nil, nil, "monster_positions_unavailable"
    end

    local distance = math.sqrt(nearest_distance2)
    if distance > TARGET_MATCH_MAX_DISTANCE then
        return nil, distance, "nearest_target_too_far"
    end

    return nearest, distance, "live_hit_location_nearest"
end

local function find_damage_target(hit_location)
    local hx, hy, hz = vector_xyz(hit_location)
    return find_damage_target_xyz(hx, hy, hz)
end

local function enter_map_transition(reason)
    local t = now()
    if not transition_active then
        transition_active = true
        transition_until = t + MAP_RELOAD_GRACE_SECONDS
        source_queue = {}
        owner_resolution_cache = {}
        attribution_diagnostic_count = 0
        source_diagnostic_count = 0
        special_summon_logged = {}
        special_target_owner_cache = {}
        last_owner_cache_prune = -999.0
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

    local t = now()
    local root_key = object_key(root)
    local cached = owner_resolution_cache[root_key]
    if cached ~= nil and (t - cached.time) <= OWNER_CACHE_SECONDS then
        return cached.owner, cached.method
    end

    local queue = {{ obj = root, path = "root", depth = 0 }}
    local visited = {}
    local head = 1

    while head <= #queue do
        local node = queue[head]
        head = head + 1

        local key = object_key(node.obj)
        if not visited[key] then
            visited[key] = true

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

            local display, internal, class_name = resolve_character_object(node.obj)
            if display ~= nil then
                local method = string.format(
                    "%s class=%s internal=%s",
                    node.path, class_name or "nil", internal or "nil"
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
                        table.insert(queue, {
                            obj = child,
                            path = node.path .. "." .. property_name,
                            depth = node.depth + 1
                        })
                    end
                end
            end
        end
    end

    return nil, "no DsPC owner in chain"
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

local function prune_sources(t)
    local kept = {}
    for _, item in ipairs(source_queue) do
        -- Keep an actively matching deployable alive from its most recent damage,
        -- not only from the original overlap callback.
        local anchor_time = item.last_match_time or item.time
        if (t - anchor_time) <= SOURCE_KEEP_SECONDS then
            table.insert(kept, item)
        end
    end
    source_queue = kept
end

local function consume_best_source(damage_time)

    local best_item = nil
    local best_distance = nil
    local best_delta = nil

    for _, item in ipairs(source_queue) do
        if item.character_name ~= nil and item.character_name ~= "Unknown" then
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

            local valid_initial =
                (first_delta >= 0 and first_delta <= initial_window)
                or
                (first_delta < 0 and (-first_delta) <= SOURCE_AFTER_DAMAGE_SECONDS)

            local valid_burst =
                item.last_match_time ~= nil
                and delta >= 0
                and delta <= burst_window
                and (item.match_count or 0) < burst_max_hits

            if valid_initial or valid_burst then
                local distance = math.abs(delta)
                if best_distance == nil or distance < best_distance then
                    best_item = item
                    best_distance = distance
                    best_delta = first_delta
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
    for _, event in ipairs(combat_events) do
        if not first_event then table.insert(parts, ",") end
        first_event = false
        table.insert(parts, string.format(
            '{"time":%.3f,"character":"%s","damage":%.1f,"critical":%s}',
            event.time or 0.0,
            json_escape(event.character or "Unknown"),
            event.damage or 0.0,
            event.critical and "true" or "false"
        ))
    end

    table.insert(parts, "]}")
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
    flush_timeline_events(false)
end

local function clear_values()
    combat_generation = combat_generation + 1
    source_queue = {}
    combat_events = {}
    combat_events_truncated = false
    timeline_pending_lines = {}
    timeline_last_flush = now()
    attribution_diagnostic_count = 0
    source_diagnostic_count = 0

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

local function finalize_damage_event(event, allow_unreal_access)
    if event.generation ~= combat_generation then
        return
    end

    local source, delta = consume_best_source(event.time)
    local target_owner = event.target_owner
    local target_method = event.target_method
    local target = nil
    local target_key = event.target_key
    local target_match_method = event.target_match_method

    if allow_unreal_access then
        target, event.target_distance, target_match_method =
            find_damage_target_xyz(
                event.hit_x,
                event.hit_y,
                event.hit_z
            )
        target_key = object_key(target)

        local fresh_owner, fresh_method =
            resolve_target_last_attacker(
                target,
                "game_thread_deferred"
            )
        if fresh_owner ~= nil and fresh_owner ~= "Unknown" then
            target_owner = fresh_owner
            target_method = fresh_method
        end
    end

    local owner
    local method

    if target_owner ~= nil and target_owner ~= "Unknown" then
        owner = target_owner
        method = target_method or "target_last_attacker"
    elseif source ~= nil then
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

        if attribution_diagnostic_count < ATTRIBUTION_DIAGNOSTIC_LIMIT then
            attribution_diagnostic_count = attribution_diagnostic_count + 1
            local diagnostic_attacker = nil
            if allow_unreal_access and target ~= nil then
                diagnostic_attacker = get_property(target, "LastAttacker")
            end
            append_line("ATTRIBUTION_ACTIVE_FALLBACK", string.format(
                "damage=%.1f critical=%s target=%s target_match=%s captured_active=%d:%s last_attacker=%s chain=%s",
                event.damage,
                tostring(event.critical),
                target_key or "nil",
                tostring(target_match_method or "unknown"),
                event.active_index,
                event.active_name,
                describe_object(diagnostic_attacker),
                describe_owner_chain(diagnostic_attacker)
            ))
        end
    end

    commit_damage_event(event, owner, method)
end

local function schedule_damage_event(event)
    local delay_ms = math.floor(DAMAGE_DEFER_SECONDS * 1000.0)

    if ExecuteWithDelay ~= nil and ExecuteInGameThread ~= nil then
        local scheduled_ok, scheduled_error = pcall(function()
            ExecuteWithDelay(delay_ms, function()
                local queued_ok, queued_error = pcall(function()
                    ExecuteInGameThread(function()
                        local ok, err = pcall(function()
                            finalize_damage_event(
                                event,
                                event.needs_target_recheck == true
                            )
                        end)
                        if not ok and hook_callback_error_count < 12 then
                            hook_callback_error_count =
                                hook_callback_error_count + 1
                            append_line("GAME_THREAD_DAMAGE_ERROR", tostring(err))
                        end
                    end)
                end)

                if not queued_ok and hook_callback_error_count < 12 then
                    hook_callback_error_count = hook_callback_error_count + 1
                    append_line(
                        "GAME_THREAD_QUEUE_ERROR",
                        tostring(queued_error)
                    )
                    finalize_damage_event(event, false)
                end
            end)
        end)

        if scheduled_ok then
            return
        end

        if hook_callback_error_count < 12 then
            hook_callback_error_count = hook_callback_error_count + 1
            append_line("DAMAGE_DELAY_ERROR", tostring(scheduled_error))
        end
    end

    -- Compatibility fallback: use only the owner snapshot already captured in
    -- the UFunction callback. No Unreal object is touched off the game thread.
    finalize_damage_event(event, false)
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
    function(Context, ...)
        if transition_active then return end

        local source = get_property(Context, "SourceActor")
        if source == nil then
            source = Context
        end

        local class_name = object_class_name(source)
        local obj_name = object_name(source)

        local owner, owner_method = resolve_owner_chain(source)

        if owner == nil then
            local token_owner, token_internal = infer_from_roster_tokens(class_name)
            if token_owner ~= nil then
                owner = token_owner
                owner_method = "roster-token:" .. tostring(token_internal)
            end
        end

        -- Only player roster members are accepted. Bosses/enemies never enter queue.
        -- The resolved owner is preserved even after character switching, so
        -- delayed mines, traps, projectiles, and lingering fields stay assigned
        -- to the character that originally created them.
        if owner == nil or owner == "Unknown" then
            if source_diagnostic_count < SOURCE_DIAGNOSTIC_LIMIT then
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
        prune_sources(t)

        local source_key = object_key(source)
        local refreshed = false

        -- The same mine/trap may fire overlap callbacks more than once.
        -- Refresh its existing ownership record instead of creating ambiguous
        -- one-shot entries.
        for _, item in ipairs(source_queue) do
            if item.source_key == source_key then
                item.time = t
                item.character_name = owner
                item.owner_method = owner_method
                item.class_name = class_name
                item.object_name = obj_name
                item.last_match_time = nil
                item.match_count = 0
                refreshed = true
                break
            end
        end

        if not refreshed then
            table.insert(source_queue, {
                time = t,
                source_key = source_key,
                class_name = class_name,
                object_name = obj_name,
                character_name = owner,
                owner_method = owner_method,
                last_match_time = nil,
                match_count = 0
            })
        end

        append_line("SOURCE_ACCEPTED", string.format(
            "owner=%s via=%s class=%s obj=%s queue=%d active=%d:%s",
            owner,
            owner_method or "unknown",
            class_name or "nil",
            obj_name or "nil",
            #source_queue,
            active_pc,
            active_name
        ))
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
        local target, target_distance, target_match_method =
            find_damage_target(hit_location)
        local target_owner, target_method =
            resolve_target_last_attacker(target, "callback")

        if target == nil
            and attribution_diagnostic_count < ATTRIBUTION_DIAGNOSTIC_LIMIT
        then
            attribution_diagnostic_count = attribution_diagnostic_count + 1
            append_line("ATTRIBUTION_TARGET_MISS", string.format(
                "damage=%.1f reason=%s distance=%s active=%d:%s",
                damage,
                tostring(target_match_method or "unknown"),
                target_distance ~= nil and string.format("%.1f", target_distance) or "nil",
                active_pc,
                active_name
            ))
        end

        local t = now()
        ensure_session(t)

        local hit_x, hit_y, hit_z = vector_xyz(hit_location)
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
            target_key = object_key(target),
            target_distance = target_distance,
            target_match_method = target_match_method,
            target_owner = target_owner,
            target_method = target_method,
            needs_target_recheck = (
                target_owner == nil or target_owner == "Unknown"
            )
        }

        append_line("DAMAGE_PENDING", string.format(
            "damage=%.1f critical=%s active=%d:%s target=%s distance=%s target_owner=%s",
            damage,
            tostring(critical),
            active_pc,
            active_name,
            object_name(target) or "nil",
            target_distance ~= nil and string.format("%.1f", target_distance) or "nil",
            target_owner or "nil"
        ))

        -- All values captured by the delayed closure are plain Lua values.
        target = nil
        hit_location = nil
        schedule_damage_event(event)
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
            prune_sources(tick_time)
            finish_session_if_idle(tick_time)
            process_window_command()
            write_state(false)
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
    "hook_context_pawn=true no_persistent_uobject_cache=true game_thread_deferred_resolution=true target_last_attacker=true separate_chako_row=true owner_chain_diagnostics=true live_target_snapshot=true owner_cache_pruning=true state_write=%.1fs combat_end_idle=%.1fs auto_save_min=%.1fs source_keep=%.1fs deferred=%.0fms",
    STATE_WRITE_SECONDS,
    COMBAT_END_IDLE_SECONDS,
    AUTO_SAVE_MIN_DURATION_SECONDS,
    SOURCE_KEEP_SECONDS,
    DAMAGE_DEFER_SECONDS * 1000.0
))

launch_window()
