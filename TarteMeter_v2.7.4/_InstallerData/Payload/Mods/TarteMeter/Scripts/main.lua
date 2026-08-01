local MOD_NAME = "TarteMeter v2.7.4"
-- UE4SS can discover the same mod through more than one enable mechanism.
-- A process-wide guard prevents duplicate combat hooks in one game process.
if _G ~= nil and _G["__TARTE_METER_RUNTIME_ACTIVE"] ~= nil then
    print(string.format(
        "[DS DPS] DUPLICATE_RUNTIME_BLOCKED existing=%s requested=%s",
        tostring(_G["__TARTE_METER_RUNTIME_ACTIVE"]),
        MOD_NAME
    ))
    return
end
if _G ~= nil then
    _G["__TARTE_METER_RUNTIME_ACTIVE"] = MOD_NAME
end

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

local SAFETY = {
    world_scan_max_event_age_seconds = 1.000,
    monster_snapshot_max_actors = 1024,
    timeline_pending_hard_limit = 4096,
    recent_target_cache_max_entries = 64,
    enemy_transient_hold_seconds = 12.0,
    enemy_candidate_window_seconds = 2.0,
    enemy_candidate_confirm_hits = 4,
    enemy_candidate_key = nil,
    enemy_candidate_name = nil,
    enemy_candidate_hits = 0,
    enemy_candidate_time = -999.0,
    timeline_lines_dropped = 0,
    timeline_pressure_logged = false,
    stale_world_scan_logged = false,
    reset_token = {}
}

-- Idle detection creates rolling checkpoints only; it never clears totals. Manual RESET is the only normal encounter boundary.
local DAMAGE_DEFER_SECONDS = 0.080
local DAMAGE_BATCH_MAX_EVENTS = 384
local DAMAGE_BATCH_CONTINUATION_MS = 3
local DAMAGE_QUEUE_HARD_LIMIT = 16384
local TARGET_MATCH_CELL_SIZE = 20.0
local SOURCE_KEEP_SECONDS = 6.000
local SOURCE_QUEUE_MAX_RECORDS = 512
local SOURCE_PRUNE_SECONDS = 0.500
local SOURCE_AFTER_DAMAGE_SECONDS = 0.120
local SOURCE_MATCH_WINDOW_SECONDS = 1.500
local SOURCE_BURST_REUSE_SECONDS = 0.900
local SOURCE_BURST_MAX_HITS = 16
local CHAKO_SOURCE_MATCH_WINDOW_SECONDS = 3.000
local CHAKO_SOURCE_BURST_REUSE_SECONDS = 2.000
local CHAKO_SOURCE_BURST_MAX_HITS = 64
local STRICT_SOURCE_MATCH_SECONDS = 0.220
local STRICT_CHAKO_MATCH_SECONDS = 0.400
local STRICT_SOURCE_AMBIGUITY_SECONDS = 0.025
local SWAP_RESOLUTION_SECONDS = 2.500
local TARGET_PROBE_SECONDS = 1.250


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
-- Once Chako has been seen, Dana's command skills need target attribution
-- even when no projectile overlap is emitted for the individual damage tick.
-- The lease is refreshed by every confirmed Chako source or committed hit.
local CHAKO_PRESENCE_SECONDS = 45.000
local CHAKO_DANA_TARGET_REFRESH_SECONDS = 0.220
local TARGET_ATTRIBUTION_CACHE_SECONDS = 0.350
local TARGET_ATTRIBUTION_CACHE_CELL_SIZE = 260.0
local TARGET_ATTRIBUTION_CACHE_MAX_DISTANCE = 750.0
local ALLIED_SUMMON_TARGET_TOKENS = {
    "DsMon_Chaco_V2_C",
    "DsMon_Kalien_Large_Fox_C",
    "DsMon_Kalien_SignalA_Fox_C"
}
local MAX_HISTORY_EVENTS = 25000
local VERBOSE_DAMAGE_LOG = false

-- After this idle time, write a rolling latest checkpoint only.
-- Damage, timeline, and encounter identity continue when combat resumes.
local COMBAT_END_IDLE_SECONDS = 10.000
local AUTO_SAVE_MIN_DURATION_SECONDS = 0.000

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
local latest_source_time = -999.0
local latest_chako_source_time = -999.0
local last_target_probe_time = -999.0
local owner_resolution_cache = {}
local attribution_diagnostic_count = 0
local source_diagnostic_count = 0
local allied_target_diagnostic_count = 0
local hook_callback_error_count = 0
local special_summon_logged = {}
local special_target_owner_cache = {}
local state_dirty = true
local swap_time = -999.0
local last_chako_presence_time = -999.0
-- Plain Lua values only. No UObject is retained between game-thread batches.
local recent_target_attribution = {}
local chako_source_link_log_count = 0

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

    pcall(function()
        local version_file = io.open("Mods/TarteMeter/runtime_version.txt", "w")
        if version_file then
            version_file:write(MOD_NAME .. "\n")
            version_file:close()
        end
    end)
end

local function fname_to_string(fname)
    if fname == nil then return nil end
    local converted = safe_call(function() return fname:ToString() end, nil)
    if converted ~= nil then return tostring(converted) end
    return tostring(fname)
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
                local allied = is_allied_summon_actor(monster)
                if allied and is_chako_actor(monster) then
                    -- Seeing the live summon in a target scan is enough to arm
                    -- Dana's command-skill attribution before Chako's first
                    -- auto-attack has produced a confirmed damage owner.
                    last_chako_presence_time = math.max(
                        last_chako_presence_time,
                        now()
                    )
                end

                -- Allied summons such as Chako are valid damage sources, but
                -- they must never participate in hit-location target matching.
                -- Including them allowed the nearest-target resolver to select
                -- Chako itself and discard Chako's outgoing hit as friendly.
                if x ~= nil and not allied then
                    snapshot[#snapshot + 1] = {
                        actor = monster,
                        key = object_key(monster),
                        x = x,
                        y = y,
                        z = z
                    }
                    if #snapshot >= SAFETY.monster_snapshot_max_actors then
                        break
                    end
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

local function note_chako_presence(t)
    local seen_time = tonumber(t) or now()
    if seen_time > last_chako_presence_time then
        last_chako_presence_time = seen_time
    end
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

    note_chako_presence(now())

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

local function resolve_enemy_display_name(monster)
    if monster == nil then return "Unknown" end

    -- Avoid speculative property probing on enemy objects. Class/object names
    -- are stable enough for display and require fewer native UObject reads.
    local readable_class = clean_enemy_name(object_class_name(monster))
    if readable_class ~= nil then return readable_class end

    local readable_object = clean_enemy_name(object_name(monster))
    if readable_object ~= nil then return readable_object end

    return "Unknown"
end

local function set_current_enemy(monster)
    if monster == nil then return end

    local key = object_key(monster)
    local name = resolve_enemy_display_name(monster)
    if name == nil or name == "Unknown" then return end

    local t = now()

    -- Actor IDs can change during boss phases or spawned hazards. Enemy
    -- identity is display metadata only and can never reset an encounter.
    if current_enemy_name == "Unknown" then
        last_enemy_object_key = key
        current_enemy_name = name
        current_enemy_time = t
        SAFETY.enemy_candidate_key = nil
        SAFETY.enemy_candidate_name = nil
        SAFETY.enemy_candidate_hits = 0
        state_dirty = true
        return
    end

    if name == current_enemy_name then
        if key ~= last_enemy_object_key then
            append_line(
                "ENEMY_ACTOR_ID_CHANGED",
                string.format(
                    "name=%s old=%s new=%s encounter_continues=true",
                    current_enemy_name,
                    tostring(last_enemy_object_key),
                    tostring(key)
                )
            )
        end
        last_enemy_object_key = key
        current_enemy_time = t
        SAFETY.enemy_candidate_key = nil
        SAFETY.enemy_candidate_name = nil
        SAFETY.enemy_candidate_hits = 0
        return
    end

    -- A fire tornado, add, or temporary phase actor must not replace the boss
    -- label after one hit. Confirm a different target repeatedly, or accept it
    -- only after the previous target has been absent for a meaningful period.
    if key == SAFETY.enemy_candidate_key
        and name == SAFETY.enemy_candidate_name
        and (t - SAFETY.enemy_candidate_time) <= SAFETY.enemy_candidate_window_seconds
    then
        SAFETY.enemy_candidate_hits = SAFETY.enemy_candidate_hits + 1
    else
        SAFETY.enemy_candidate_key = key
        SAFETY.enemy_candidate_name = name
        SAFETY.enemy_candidate_hits = 1
    end
    SAFETY.enemy_candidate_time = t

    local previous_is_recent =
        (t - current_enemy_time) <= SAFETY.enemy_transient_hold_seconds
    if previous_is_recent
        and SAFETY.enemy_candidate_hits < SAFETY.enemy_candidate_confirm_hits
    then
        return
    end

    append_line(
        "ENEMY_DISPLAY_CHANGED",
        string.format(
            "from=%s to=%s old_id=%s new_id=%s confirmed_hits=%d encounter_continues=true",
            current_enemy_name,
            name,
            tostring(last_enemy_object_key),
            tostring(key),
            SAFETY.enemy_candidate_hits
        )
    )
    last_enemy_object_key = key
    current_enemy_name = name
    current_enemy_time = t
    SAFETY.enemy_candidate_key = nil
    SAFETY.enemy_candidate_name = nil
    SAFETY.enemy_candidate_hits = 0
    state_dirty = true
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

    for key, entry in pairs(recent_target_attribution) do
        if entry == nil
            or (t - (entry.time or -999.0))
                > TARGET_ATTRIBUTION_CACHE_SECONDS
        then
            recent_target_attribution[key] = nil
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

        swap_time = now()

        active_pc = idx
        active_name = display
        active_internal = internal
        state_dirty = true

        append_line("ACTIVE_CHARACTER", string.format(
            "from=%d:%s to=%d:%s internal=%s pawn_class=%s",
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
    latest_source_time = math.max(latest_source_time, t)
    if owner == DANA_GOLEM_DISPLAY then
        latest_chako_source_time = math.max(latest_chako_source_time, t)
        note_chako_presence(t)
    end

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

local function is_resolved_target_key(key)
    return key ~= nil
        and key ~= ""
        and key ~= "nil"
        and key ~= "unresolved"
end

local function target_attribution_bucket_key(hx, hy, hz)
    if hx == nil or hy == nil or hz == nil then
        return nil
    end

    local cell = TARGET_ATTRIBUTION_CACHE_CELL_SIZE
    return string.format(
        "%d:%d:%d",
        math.floor((hx / cell) + 0.5),
        math.floor((hy / cell) + 0.5),
        math.floor((hz / cell) + 0.5)
    )
end

local function get_recent_target_attribution(event)
    if event == nil then return nil end

    local bucket = target_attribution_bucket_key(
        event.hit_x,
        event.hit_y,
        event.hit_z
    )
    if bucket == nil then return nil end

    local item = recent_target_attribution[bucket]
    if item ~= nil then
        local age = event.time - (item.time or -999.0)
        if age >= -SOURCE_AFTER_DAMAGE_SECONDS
            and age <= TARGET_ATTRIBUTION_CACHE_SECONDS
        then
            return item
        end
        recent_target_attribution[bucket] = nil
    end

    -- Large bosses can report adjacent hit locations for the same multi-hit
    -- skill. Reuse only a fresh, spatially close plain-value entry.
    local best_item = nil
    local best_distance_sq = nil
    local max_distance_sq =
        TARGET_ATTRIBUTION_CACHE_MAX_DISTANCE
        * TARGET_ATTRIBUTION_CACHE_MAX_DISTANCE

    for key, candidate in pairs(recent_target_attribution) do
        local age = event.time - (candidate.time or -999.0)
        if age < -SOURCE_AFTER_DAMAGE_SECONDS
            or age > TARGET_ATTRIBUTION_CACHE_SECONDS
        then
            recent_target_attribution[key] = nil
        elseif candidate.hit_x ~= nil
            and candidate.hit_y ~= nil
            and candidate.hit_z ~= nil
        then
            local dx = event.hit_x - candidate.hit_x
            local dy = event.hit_y - candidate.hit_y
            local dz = event.hit_z - candidate.hit_z
            local distance_sq = dx * dx + dy * dy + dz * dz
            if distance_sq <= max_distance_sq
                and (
                    best_distance_sq == nil
                    or distance_sq < best_distance_sq
                )
            then
                best_item = candidate
                best_distance_sq = distance_sq
            end
        end
    end

    return best_item
end

local function remember_target_attribution(
    event,
    target_key,
    owner,
    method,
    distance
)
    if event == nil
        or owner == nil
        or owner == "Unknown"
        or not is_resolved_target_key(target_key)
    then
        return
    end

    local bucket = target_attribution_bucket_key(
        event.hit_x,
        event.hit_y,
        event.hit_z
    )
    if bucket == nil then return end

    if recent_target_attribution[bucket] == nil then
        local cache_count = 0
        local oldest_key = nil
        local oldest_time = math.huge
        for key, item in pairs(recent_target_attribution) do
            cache_count = cache_count + 1
            local item_time = item.time or -999.0
            if item_time < oldest_time then
                oldest_time = item_time
                oldest_key = key
            end
        end
        if cache_count >= SAFETY.recent_target_cache_max_entries
            and oldest_key ~= nil
        then
            recent_target_attribution[oldest_key] = nil
        end
    end

    recent_target_attribution[bucket] = {
        time = event.time,
        target_key = target_key,
        owner = owner,
        method = method,
        distance = distance,
        hit_x = event.hit_x,
        hit_y = event.hit_y,
        hit_z = event.hit_z
    }
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
                is_resolved_target_key(target_key)
                and item.target_key == target_key
            )
        elseif is_resolved_target_key(item.target_key)
            and is_resolved_target_key(target_key)
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
            local is_chako = item.character_name == DANA_GOLEM_DISPLAY
            local initial_window = SOURCE_MATCH_WINDOW_SECONDS
            local burst_window = SOURCE_BURST_REUSE_SECONDS
            local burst_max_hits = SOURCE_BURST_MAX_HITS

            if is_tarte then
                initial_window = TARTE_SOURCE_MATCH_WINDOW_SECONDS
                burst_window = TARTE_SOURCE_BURST_REUSE_SECONDS
                burst_max_hits = TARTE_SOURCE_BURST_MAX_HITS
            elseif is_chako then
                initial_window = CHAKO_SOURCE_MATCH_WINDOW_SECONDS
                burst_window = CHAKO_SOURCE_BURST_REUSE_SECONDS
                burst_max_hits = CHAKO_SOURCE_BURST_MAX_HITS
            end

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

-- Strict temporal fallback used only when the target cannot be recovered.
-- It rejects ambiguous records from different owners instead of guessing.
local function consume_strict_unresolved_source(
    damage_time,
    preferred_character
)
    local best_item = nil
    local best_distance = nil
    local best_delta = nil
    local ambiguous = false

    for _, item in pairs(source_records) do
        if item.character_name ~= nil
            and item.character_name ~= "Unknown"
            and (
                preferred_character == nil
                or item.character_name == preferred_character
            )
        then
            local window = item.character_name == DANA_GOLEM_DISPLAY
                and STRICT_CHAKO_MATCH_SECONDS
                or STRICT_SOURCE_MATCH_SECONDS
            local first_delta = damage_time - (item.time or -999.0)
            local last_delta = item.last_match_time ~= nil
                and (damage_time - item.last_match_time)
                or nil

            local valid_initial = (
                first_delta >= 0
                and first_delta <= window
            ) or (
                first_delta < 0
                and (-first_delta) <= SOURCE_AFTER_DAMAGE_SECONDS
            )
            local valid_burst = (
                last_delta ~= nil
                and last_delta >= 0
                and last_delta <= window
            )

            if valid_initial or valid_burst then
                local distance = math.abs(
                    valid_burst and last_delta or first_delta
                )

                if best_distance == nil
                    or distance < best_distance
                then
                    best_item = item
                    best_distance = distance
                    best_delta = first_delta
                    ambiguous = false
                elseif best_item ~= nil
                    and item.character_name ~= best_item.character_name
                    and math.abs(distance - best_distance)
                        <= STRICT_SOURCE_AMBIGUITY_SECONDS
                then
                    ambiguous = true
                end
            end
        end
    end

    if best_item == nil or ambiguous then
        return nil, nil
    end

    best_item.last_match_time = damage_time
    best_item.match_count = (best_item.match_count or 0) + 1
    return best_item, best_delta
end

local function batch_requires_snapshot(batch)
    for _, event in ipairs(batch) do
        if event.active_name == nil
            or event.active_name == "Unknown"
        then
            return true
        end

        local source_delta = event.time - latest_source_time
        if source_delta >= -SOURCE_AFTER_DAMAGE_SECONDS
            and source_delta <= SOURCE_MATCH_WINDOW_SECONDS
        then
            return true
        end

        local chako_delta = event.time - latest_chako_source_time
        if chako_delta >= -SOURCE_AFTER_DAMAGE_SECONDS
            and chako_delta <= CHAKO_SOURCE_MATCH_WINDOW_SECONDS
        then
            return true
        end

        -- Dana can command Chako to perform attacks whose individual ticks do
        -- not emit OnAttackBeginOverlap. While a confirmed Chako summon is
        -- present, periodically resolve the enemy's LastAttacker instead of
        -- assigning those ticks to Dana through the fast active-pawn path.
        if event.active_name == "Dana"
            and (event.time - last_chako_presence_time)
                <= CHAKO_PRESENCE_SECONDS
        then
            local cached = get_recent_target_attribution(event)
            if cached == nil
                or (event.time - (cached.time or -999.0))
                    >= CHAKO_DANA_TARGET_REFRESH_SECONDS
            then
                return true
            end
        end

        if (event.time - swap_time) <= SWAP_RESOLUTION_SECONDS then
            return true
        end

        if (event.time - last_target_probe_time) >= TARGET_PROBE_SECONDS then
            return true
        end
    end

    return false
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

local function export_battle(reason, append_history)
    if (not session_started and not session_finished) or total_damage() <= 0 then
        return false
    end

    append_history = append_history ~= false

    local t = now()
    local json = battle_json(reason, t)
    local latest_json_saved = write_text_atomic(
        EXPORT_JSON_FILE,
        EXPORT_JSON_FILE .. ".tmp",
        json .. "\n"
    )
    local history_saved = true
    if append_history then
        history_saved = append_text(HISTORY_FILE, json .. "\n")
    end

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

    local export_ok = latest_json_saved and latest_csv_saved
    if append_history then
        export_ok = export_ok and history_saved
    end

    local event_name
    if append_history then
        event_name = export_ok and "BATTLE_EXPORTED" or "BATTLE_EXPORT_FAILED"
    else
        event_name = export_ok and "BATTLE_CHECKPOINTED" or "BATTLE_CHECKPOINT_FAILED"
    end

    append_line(
        event_name,
        "reason=" .. tostring(reason)
            .. " append_history=" .. tostring(append_history)
            .. " history_saved=" .. tostring(history_saved)
            .. " latest_json=" .. tostring(latest_json_saved)
            .. " latest_csv=" .. tostring(latest_csv_saved)
    )
    return export_ok
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

    if #timeline_pending_lines < SAFETY.timeline_pending_hard_limit then
        timeline_pending_lines[#timeline_pending_lines + 1] = string.format(
            "%.3f,%s,%.1f,%s\n",
            relative_time,
            csv_escape(owner),
            damage,
            critical and "1" or "0"
        )
    else
        SAFETY.timeline_lines_dropped = SAFETY.timeline_lines_dropped + 1
        if not SAFETY.timeline_pressure_logged then
            SAFETY.timeline_pressure_logged = true
            append_line(
                "TIMELINE_QUEUE_PRESSURE",
                string.format(
                    "limit=%d; damage totals continue; timeline rows may be omitted until disk writes recover",
                    SAFETY.timeline_pending_hard_limit
                )
            )
        end
    end
end

local function clear_values(token)
    if token ~= SAFETY.reset_token then
        append_line(
            "RESET_GUARD_BLOCKED",
            "unauthorized clear_values call; encounter preserved"
        )
        return false
    end

    combat_generation = combat_generation + 1
    source_records = {}
    source_record_count = 0
    source_record_sequence = 0
    clear_pending_damage_events()
    combat_events = {}
    combat_events_truncated = false
    timeline_pending_lines = {}
    timeline_last_flush = now()
    SAFETY.timeline_lines_dropped = 0
    SAFETY.timeline_pressure_logged = false
    attribution_diagnostic_count = 0
    source_diagnostic_count = 0
    allied_target_diagnostic_count = 0
    owner_resolution_cache = {}
    special_summon_logged = {}
    special_target_owner_cache = {}
    recent_target_attribution = {}
    chako_source_link_log_count = 0
    SAFETY.stale_world_scan_logged = false
    last_source_prune = -999.0
    latest_source_time = -999.0
    latest_chako_source_time = -999.0
    last_target_probe_time = -999.0

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
    current_enemy_name = "Unknown"
    current_enemy_time = -999.0
    last_enemy_object_key = nil
    SAFETY.enemy_candidate_key = nil
    SAFETY.enemy_candidate_name = nil
    SAFETY.enemy_candidate_hits = 0
    SAFETY.enemy_candidate_time = -999.0
    state_dirty = true
    return true
end

local function reset_meter(reason)
    local reset_reason = tostring(reason or "manual")
    local has_damage = total_damage() > 0
    local archived = not has_damage

    if has_damage then
        archived = export_battle("reset:" .. reset_reason, true)
    end

    -- Never destroy an unsaved encounter. A locked history file can be retried
    -- by pressing RESET again after the lock is released.
    if has_damage and not archived then
        append_line("RESET_ABORTED_SAVE_FAILED", reset_reason)
        state_dirty = true
        write_state(true)
        return false
    end

    if not clear_values(SAFETY.reset_token) then
        return false
    end
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

local function ensure_session(t)
    if session_finished then
        -- Idle detection is only a checkpoint boundary. It must never erase
        -- accumulated damage. Summon animations, boss invulnerability phases,
        -- movement, menus, and character swaps can all exceed ten seconds.
        session_started = true
        session_finished = false
        session_end_time = 0.0
        append_line(
            "SESSION_RESUMED",
            "continuing cumulative encounter damage="
                .. tostring(total_damage())
        )
        state_dirty = true
        return
    end

    if not session_started then
        session_started = true
        session_finished = false
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

    -- Save only the rolling latest JSON/CSV checkpoint here. Do not append a
    -- history row and do not clear totals when damage resumes. The complete
    -- encounter is appended to history exactly once on manual RESET.
    local checkpoint_saved = write_snapshot(
        "auto idle checkpoint",
        false
    )

    append_line(
        checkpoint_saved
            and "SESSION_IDLE_CHECKPOINT_SAVED"
            or "SESSION_IDLE_CHECKPOINT_FAILED",
        string.format(
            "duration=%.3fs idle=%.3fs minimum=%.3fs cumulative_damage=%.1f",
            duration,
            t - last_outgoing_damage_time,
            AUTO_SAVE_MIN_DURATION_SECONDS,
            total_damage()
        )
    )

    write_state(true)
end

-- Snapshot records the current cumulative encounter without resetting totals.
write_snapshot = function(reason, append_history)
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
        "snapshot:" .. tostring(reason or "manual"),
        append_history
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

    -- Start or resume an encounter only after the event has a committed
    -- owner. Target-probe and friendly-summon artifacts must not create empty
    -- sessions or trigger immediate auto-save/reset cycles.
    ensure_session(event.time)

    owner = register_character(owner)
    if owner == DANA_GOLEM_DISPLAY then
        note_chako_presence(event.time)
    end
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
    local target_resolved = is_resolved_target_key(target_key)

    -- A verified source + target pair is stronger than a batch-time
    -- LastAttacker value for every character, not only Chako. This prevents a
    -- newer attacker from stealing delayed projectile or skill damage.
    if target_resolved then
        local exact_source, exact_delta = consume_best_source(
            event.time,
            target_key,
            nil,
            true
        )

        if exact_source ~= nil then
            owner = exact_source.character_name
            method = string.format(
                "exact_source_target delta=%.1fms via=%s class=%s obj=%s",
                exact_delta * 1000.0,
                exact_source.owner_method or "unknown",
                exact_source.class_name or "nil",
                exact_source.object_name or "nil"
            )
        end
    end

    -- If target recovery failed or LastAttacker was overwritten immediately
    -- after a swap, accept only an unambiguous, very recent Chako source.
    if owner == nil then
        local allow_chako_override = (
            target_owner == nil
            or target_owner == "Unknown"
            or (
                event.active_name ~= "Dana"
                and target_owner == event.active_name
                and (event.time - swap_time)
                    <= SWAP_RESOLUTION_SECONDS
            )
        )

        if allow_chako_override then
            local chako_source, chako_delta =
                consume_strict_unresolved_source(
                    event.time,
                    DANA_GOLEM_DISPLAY
                )

            if chako_source ~= nil then
                owner = DANA_GOLEM_DISPLAY
                method = string.format(
                    "strict_chako_source delta=%.1fms via=%s class=%s obj=%s",
                    chako_delta * 1000.0,
                    chako_source.owner_method or "unknown",
                    chako_source.class_name or "nil",
                    chako_source.object_name or "nil"
                )
            end
        end
    end

    if owner == nil
        and target_owner ~= nil
        and target_owner ~= "Unknown"
    then
        owner = target_owner
        method = target_method or "target_last_attacker"
    end

    -- Without a target, use only a narrow and ambiguity-checked temporal
    -- source match. This catches SourceActor callbacks that arrive around the
    -- damage text without turning an old projectile into a global owner.
    if owner == nil and not target_resolved then
        local strict_source, strict_delta =
            consume_strict_unresolved_source(event.time, nil)

        if strict_source ~= nil then
            owner = strict_source.character_name
            method = string.format(
                "strict_unresolved_source delta=%.1fms via=%s class=%s obj=%s",
                strict_delta * 1000.0,
                strict_source.owner_method or "unknown",
                strict_source.class_name or "nil",
                strict_source.object_name or "nil"
            )
        end
    end

    if owner == nil and target_resolved then
        local source, delta = consume_best_source(
            event.time,
            target_key,
            nil,
            false
        )

        if source ~= nil then
            owner = source.character_name
            method = string.format(
                "compatible_source_fallback delta=%.1fms via=%s class=%s obj=%s",
                delta * 1000.0,
                source.owner_method or "unknown",
                source.class_name or "nil",
                source.object_name or "nil"
            )
        end
    end

    if owner == nil then
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

    -- Most direct hits need no world scan: the active pawn captured in the
    -- damage callback is already the correct owner. A transient monster
    -- snapshot is created only for swap-sensitive, source-sensitive, unknown,
    -- or periodic target-name probe batches.
    local snapshot = nil
    local snapshot_reason = "fast_path_no_world_scan"
    local needs_snapshot = batch_requires_snapshot(batch)
    local newest_event_time = batch[#batch].time or now()
    local batch_age = now() - newest_event_time

    -- If the game thread was blocked by loading or teardown, do not call
    -- FindAllOf on a stale batch. Plain-value source/active fallbacks are safer
    -- than touching a world that may already be transitioning.
    if needs_snapshot and batch_age > SAFETY.world_scan_max_event_age_seconds then
        needs_snapshot = false
        snapshot_reason = "stale_batch_no_world_scan"
        if not SAFETY.stale_world_scan_logged then
            SAFETY.stale_world_scan_logged = true
            append_line(
                "STALE_WORLD_SCAN_SKIPPED",
                string.format(
                    "batch_age=%.0fms threshold=%.0fms",
                    batch_age * 1000.0,
                    SAFETY.world_scan_max_event_age_seconds * 1000.0
                )
            )
        end
    end

    if needs_snapshot then
        last_target_probe_time = batch[#batch].time or now()

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
    end

    local match_cache = {}

    for _, event in ipairs(batch) do
        local target_owner = nil
        local target_method = nil
        local target_key = event.target_key
        local target_distance = nil
        local target_match_method = snapshot_reason
        local diagnostic_attacker = "not captured"
        local diagnostic_chain = "not captured"

        local resolution_ok, resolution_error = pcall(function()
            if snapshot == nil then
                if event.active_name == "Dana"
                    and (event.time - last_chako_presence_time)
                        <= CHAKO_PRESENCE_SECONDS
                then
                    local cached = get_recent_target_attribution(event)
                    if cached ~= nil then
                        target_owner = cached.owner
                        target_method = string.format(
                            "cached_target_attribution age=%.0fms via=%s",
                            (event.time - cached.time) * 1000.0,
                            cached.method or "unknown"
                        )
                        target_key = cached.target_key
                        target_distance = cached.distance
                        target_match_method =
                            "cached_hit_target_no_world_scan"
                    end
                end
                return
            end

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

            -- Read LastAttacker for each unresolved event instead of reusing
            -- one target result for an entire burst. Exact source attribution
            -- still runs first in finalize_damage_event().
            target_owner, target_method =
                resolve_target_last_attacker(
                    target_entry.actor,
                    "game_thread_event"
                )

            if target_owner ~= nil
                and target_owner ~= "Unknown"
            then
                remember_target_attribution(
                    event,
                    target_key,
                    target_owner,
                    target_method,
                    target_distance
                )
            end

            if target_owner == nil
                and attribution_diagnostic_count
                    < ATTRIBUTION_DIAGNOSTIC_LIMIT
            then
                local attacker = get_property(
                    target_entry.actor,
                    "LastAttacker"
                )
                diagnostic_attacker = describe_object(attacker)
                diagnostic_chain = describe_owner_chain(attacker)
            end
        end)

        if not resolution_ok
            and hook_callback_error_count < 12
        then
            hook_callback_error_count =
                hook_callback_error_count + 1
            append_line(
                "DAMAGE_RESOLUTION_ERROR",
                tostring(resolution_error)
            )
        end

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

        if not commit_ok
            and hook_callback_error_count < 12
        then
            hook_callback_error_count =
                hook_callback_error_count + 1
            append_line(
                "DAMAGE_COMMIT_ERROR",
                tostring(commit_error)
            )
        end
    end

    -- No UObject escapes this game-thread callback.
    snapshot = nil
    match_cache = nil
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
        local context_obj = read_param(Context, Context)
        local source_actor = get_property(context_obj, "SourceActor")
        if source_actor == nil then
            source_actor = context_obj
        end

        local context_class = object_class_name(context_obj)
        local context_name = object_name(context_obj)
        local source_class = object_class_name(source_actor)
        local source_name = object_name(source_actor)

        -- Some Dana command skills are represented by a Chako-owned animation
        -- context while SourceActor still points at Dana. Resolve the concrete
        -- overlap context first, then the source actor.
        local owner, owner_method =
            resolve_special_summon_owner(context_obj, "context")

        if owner == nil and source_actor ~= context_obj then
            owner, owner_method =
                resolve_special_summon_owner(source_actor, "source")
        end

        if owner == nil then
            local source_token_text = string.format(
                "%s|%s|%s|%s",
                context_class or "",
                context_name or "",
                source_class or "",
                source_name or ""
            )
            if source_token_text:find(
                DANA_GOLEM_SOURCE_TOKEN,
                1,
                true
            ) ~= nil then
                owner = DANA_GOLEM_DISPLAY
                owner_method = "exact_chako_context_or_source_token"
                note_chako_presence(now())
            end
        end

        if owner == nil then
            local token_owner, token_internal =
                infer_from_roster_tokens(context_class)
            if token_owner == nil then
                token_owner, token_internal =
                    infer_from_roster_tokens(source_class)
            end
            if token_owner ~= nil then
                owner = token_owner
                owner_method =
                    "roster-token:" .. tostring(token_internal)
            end
        end

        if owner == nil then
            owner, owner_method = resolve_owner_chain(context_obj)
        end
        if owner == nil and source_actor ~= context_obj then
            owner, owner_method = resolve_owner_chain(source_actor)
        end

        local class_name = context_class or source_class
        local obj_name = context_name or source_name

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
                    describe_object(context_obj),
                    describe_object(source_actor),
                    owner_method or "not linked to DsPC roster",
                    active_pc,
                    active_name,
                    describe_owner_chain(context_obj)
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

        -- Use the animation/projectile context as the record identity. This
        -- prevents all of Dana's command projectiles from collapsing into the
        -- same SourceActor key.
        local source_key = object_key(context_obj)
        local _, inserted = remember_source(
            source_key,
            target_key,
            class_name,
            obj_name,
            owner,
            owner_method,
            t
        )

        if owner == DANA_GOLEM_DISPLAY
            and chako_source_link_log_count < 8
        then
            chako_source_link_log_count =
                chako_source_link_log_count + 1
            append_line("CHAKO_SOURCE_LINK", string.format(
                "context=%s source=%s target=%s via=%s",
                describe_object(context_obj),
                describe_object(source_actor),
                target_key or "unresolved",
                owner_method or "unknown"
            ))
        end

        -- Seed a plain-string target lease directly from the exact overlap.
        -- This lets a later nil/overwritten LastAttacker still resolve Chako
        -- after Dana is swapped out, without retaining OtherActor.
        if owner == DANA_GOLEM_DISPLAY
            and is_resolved_target_key(target_key)
        then
            special_target_owner_cache[target_key] = {
                owner = DANA_GOLEM_DISPLAY,
                time = t
            }
        end

        -- Do not retain any UObject from the overlap callback.
        other_actor = nil
        source_actor = nil
        context_obj = nil

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
            target_key = nil
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
    "runtime_singleton_guard=true reset_guard=true stale_world_scan_guard=true hook_context_pawn=true no_persistent_uobject_cache=true coalesced_damage_batches=true one_world_scan_per_batch=true throttled_chako_skill_target_probe=true context_first_source_attribution=true enemy_only_target_snapshot=true target_last_attacker=true separate_chako_row=true exact_chako_source_target=true bounded_owner_chain=true source_index=true deferred_timeline_io=true owner_cache_pruning=true state_write=%.1fs idle_checkpoint=%.1fs auto_save_min=%.1fs source_keep=%.1fs deferred=%.0fms batch_max=%d",
    STATE_WRITE_SECONDS,
    COMBAT_END_IDLE_SECONDS,
    AUTO_SAVE_MIN_DURATION_SECONDS,
    SOURCE_KEEP_SECONDS,
    DAMAGE_DEFER_SECONDS * 1000.0,
    DAMAGE_BATCH_MAX_EVENTS
))

launch_window()
