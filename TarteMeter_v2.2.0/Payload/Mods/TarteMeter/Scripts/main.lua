local MOD_NAME = "TarteMeter v2.2.0"
local LOG_FILE = "Mods/TarteMeter/dps_meter.txt"
local STATE_FILE = "Mods/TarteMeter/dps_state.txt"
local STATE_TMP = "Mods/TarteMeter/dps_state.tmp"
local COMMAND_FILE = "Mods/TarteMeter/dps_command.txt"
local WINDOW_SCRIPT = "Mods\\TarteMeter\\DPSWindow.ps1"
local HISTORY_FILE = "Mods/TarteMeter/battle_history.jsonl"
local TIMELINE_FILE = "Mods/TarteMeter/current_timeline.csv"
local EXPORT_CSV_FILE = "Mods/TarteMeter/latest_battle.csv"
local EXPORT_JSON_FILE = "Mods/TarteMeter/latest_battle.json"

-- No automatic combat reset.
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
local ROSTER_REFRESH_SECONDS = 60.000
local CONTROLLER_SEARCH_RETRY_SECONDS = 0.500
local COMMAND_POLL_SECONDS = 0.500
local OWNER_CACHE_SECONDS = 2.000
local OWNER_CACHE_PRUNE_SECONDS = 10.000
local MAX_HISTORY_EVENTS = 25000
local VERBOSE_DAMAGE_LOG = false

-- A fight is considered finished after this much time without outgoing damage.
-- Long fights are archived automatically; shorter fights are archived when RESET is used.
local COMBAT_END_IDLE_SECONDS = 10.000
local AUTO_SAVE_MIN_DURATION_SECONDS = 60.000

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
local pending_damage = {}

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
local last_roster_refresh = -999.0
local last_state_write = -999.0
local last_controller_search = -999.0
local last_command_poll = -999.0
local last_owner_cache_prune = -999.0
local cached_controller = nil
local monster_cache = {}
local owner_resolution_cache = {}
local last_attacker_scan_no = 0
local aggregate_cache_owner = nil
local aggregate_cache_method = nil
local aggregate_cache_time = -1000.0
local AGGREGATE_SCAN_INTERVAL_SECONDS = 0.12
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
    AGGREGATE_ATTACKER_SCAN = true,
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

local function refresh_roster(force)
    local t = now()
    if not force and (t - last_roster_refresh) < ROSTER_REFRESH_SECONDS then
        return
    end
    last_roster_refresh = t

    local objects = safe_call(function() return FindAllOf("DsPlayerCharacter") end, nil)
    if not objects then return end

    for _, obj in ipairs(objects) do
        local class_name = object_class_name(obj)
        local internal = extract_pc_internal(class_name)
        if internal ~= nil then
            register_roster_internal(internal)
        end
    end
end

local function find_controller()
    -- Reuse the controller while its UObject remains valid. The old build ran
    -- FindAllOf four times per second, which was one of the largest avoidable
    -- game-thread costs. A stale wrapper is discarded immediately on travel.
    if cached_controller ~= nil then
        local valid = safe_call(function()
            return cached_controller:IsValid()
        end, false)
        if valid then return cached_controller end
        cached_controller = nil
    end

    local t = now()
    if (t - last_controller_search) < CONTROLLER_SEARCH_RETRY_SECONDS then
        return nil
    end
    last_controller_search = t

    local pcs = safe_call(function()
        return FindAllOf("DsPlayerController")
    end, nil)
    if not pcs or #pcs == 0 then return nil end

    for _, pc in ipairs(pcs) do
        if pc and safe_call(function() return pc:IsValid() end, false) then
            cached_controller = pc
            return pc
        end
    end
    return nil
end

local function refresh_monster_cache()
    local monsters = safe_call(function()
        return FindAllOf("DsMonsterCharacter")
    end, nil)
    if monsters == nil then return false end

    local refreshed = {}
    for _, monster in ipairs(monsters) do
        if monster ~= nil and safe_call(function()
            return monster:IsValid()
        end, false) then
            refreshed[#refreshed + 1] = monster
        end
    end
    monster_cache = refreshed
    return #monster_cache > 0
end

local function get_valid_monster_cache()
    local valid = {}
    for _, monster in ipairs(monster_cache) do
        if monster ~= nil and safe_call(function()
            return monster:IsValid()
        end, false) then
            valid[#valid + 1] = monster
        end
    end
    monster_cache = valid

    -- FindAllOf is intentionally on-demand only: once after map readiness and
    -- again only when every cached monster has become invalid. This removes the
    -- recurring full-world scan that could produce combat-time hitches.
    if #monster_cache == 0 then
        refresh_monster_cache()
    end
    return monster_cache
end

local function enter_map_transition(reason)
    local t = now()
    if not transition_active then
        transition_active = true
        transition_until = t + MAP_RELOAD_GRACE_SECONDS
        source_queue = {}
        pending_damage = {}
        cached_controller = nil
        monster_cache = {}
        owner_resolution_cache = {}
        aggregate_cache_owner = nil
        aggregate_cache_method = nil
        aggregate_cache_time = -1000.0
        last_owner_cache_prune = -999.0
        last_controller_search = -999.0
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

local function update_active_character()
    local t = now()
    local pc = find_controller()

    if pc == nil then
        if missing_controller_since == nil then
            missing_controller_since = t
        elseif (t - missing_controller_since) >= CONTROLLER_MISSING_CONFIRM_SECONDS then
            enter_map_transition("controller missing")
        end
        return
    end

    missing_controller_since = nil
    if transition_active then
        if t < transition_until then return end
        transition_active = false
        last_roster_refresh = -999.0
        refresh_roster(true)
        refresh_monster_cache()
        append_line("MAP_READY", "controller reacquired after grace period")
    end

    refresh_roster(false)

    -- CurrentPCIndex is retained only for display/log compatibility. Ownership is
    -- resolved from the actual Pawn class, not from a static index table.
    local idx = tonumber(safe_call(function() return pc.CurrentPCIndex end, -1)) or -1

    local candidate = get_property(pc, "Character")
    if candidate == nil then candidate = get_property(pc, "Pawn") end
    if candidate == nil then candidate = get_property(pc, "AcknowledgedPawn") end

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
        carryover_enabled = old_name ~= nil and old_name ~= "Unknown"

        active_pc = idx
        active_name = display
        active_internal = internal
        aggregate_cache_owner = nil
        aggregate_cache_method = nil
        aggregate_cache_time = -1000.0
        state_dirty = true

        append_line("ACTIVE_CHARACTER", string.format(
            "from=%d:%s to=%d:%s internal=%s pawn_class=%s carryover=%s",
            old_idx, old_name or "nil",
            active_pc, active_name,
            active_internal or "nil",
            class_name or "nil",
            tostring(carryover_enabled)
        ))
    end
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
    source_queue = {}
    pending_damage = {}
    combat_events = {}
    combat_events_truncated = false
    timeline_pending_lines = {}
    timeline_last_flush = now()

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

local function ensure_session(t)
    if session_finished then
        -- A new outgoing hit starts a fresh encounter. A short previous fight is
        -- intentionally not auto-saved; use RESET before the next fight to archive it.
        clear_values()
        write_text_atomic(
            TIMELINE_FILE,
            TIMELINE_FILE .. ".tmp",
            "Time,Character,Damage,Critical\n"
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

local write_snapshot

local function finish_session_if_idle(t)
    if not session_started then return end
    if #pending_damage > 0 then return end
    if (t - last_outgoing_damage_time) < COMBAT_END_IDLE_SECONDS then return end

    session_end_time = last_outgoing_damage_time
    if session_end_time < session_start_time then
        session_end_time = t
    end

    local duration = session_end_time - session_start_time

    -- Mark the encounter ended before exporting so elapsed_at() uses the last
    -- damage timestamp instead of including the idle detection delay.
    session_started = false
    session_finished = true
    state_dirty = true

    if duration >= AUTO_SAVE_MIN_DURATION_SECONDS then
        session_auto_saved = write_snapshot("auto combat end") == true
        append_line(
            session_auto_saved and "SESSION_AUTO_SAVED" or "SESSION_AUTO_SAVE_FAILED",
            string.format(
                "duration=%.3fs idle=%.3fs",
                duration,
                t - last_outgoing_damage_time
            )
        )
    else
        append_line("SESSION_ENDED_MANUAL_SAVE_REQUIRED", string.format(
            "duration=%.3fs minimum=%.3fs",
            duration,
            AUTO_SAVE_MIN_DURATION_SECONDS
        ))
    end

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

local function process_pending_damage()
    local t = now()
    local keep = {}

    for _, event in ipairs(pending_damage) do
        if (t - event.time) < DAMAGE_DEFER_SECONDS then
            table.insert(keep, event)
        else
            local source, delta = consume_best_source(event.time)
            local owner
            local method

            -- Prefer the damage aggregate's concrete LastAttacker result.
            -- A queued overlap/source record is temporal evidence and may be stale,
            -- so it is used only when the aggregate exposes no valid owner.
            if event.aggregate_owner ~= nil
                and event.aggregate_owner ~= "Unknown"
            then
                owner = event.aggregate_owner
                method = event.aggregate_method or "aggregate_last_attacker"
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

                local since_swap = event.time - swap_time
                if carryover_enabled
                    and previous_active_name ~= nil
                    and previous_active_name ~= "Unknown"
                    and since_swap >= 0
                    and since_swap <= SWAP_CARRY_SECONDS
                then
                    if event.damage <= CARRY_SMALL_DAMAGE_MAX then
                        owner = previous_active_name
                        method = string.format(
                            "swap_carryover age=%.0fms",
                            since_swap * 1000.0
                        )
                    elseif event.damage >= NEW_ACTIVE_DIRECT_DAMAGE_MIN then
                        carryover_enabled = false
                        method = "new_active_direct_hit"
                    end
                end
            end

            owner = register_character(owner)
            totals[owner] = totals[owner] + event.damage
            hits[owner] = hits[owner] + 1
            highest_hits[owner] = math.max(highest_hits[owner] or 0.0, event.damage)
            if event.critical then crits[owner] = crits[owner] + 1 end
            append_timeline_event(event.time, owner, event.damage, event.critical)
            last_outgoing_damage_time = event.time
            state_dirty = true

            append_line("DAMAGE", string.format(
                "owner=%s damage=%.1f critical=%s method=%s captured_active=%d:%s current_active=%d:%s owner_total=%.1f",
                owner,
                event.damage,
                tostring(event.critical),
                method,
                event.active_index,
                event.active_name,
                active_pc,
                active_name,
                totals[owner]
            ))
        end
    end

    pending_damage = keep
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
    -- Launch detached. Calling powershell.exe directly through os.execute waits
    -- for the WPF ShowDialog process and blocks the UE game thread.
    local command =
        'cmd.exe /d /c start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "'
        .. WINDOW_SCRIPT .. '"'

    local ok, result = pcall(function() return os.execute(command) end)
    window_launched = ok
    append_line("WINDOW_LAUNCH", "detached=true ok=" .. tostring(ok) .. " result=" .. tostring(result))
end

local function install_hook(path, callback)
    append_line("HOOK_ATTEMPT", path)
    local ok, result = pcall(function() return RegisterHook(path, callback) end)
    if ok then
        append_line("HOOK_OK", path .. " result=" .. tostring(result))
    else
        append_line("HOOK_FAIL", path .. " error=" .. tostring(result))
    end
end

reset_log_file()
append_line("INIT", "script entered")
refresh_roster(true)
update_active_character()
if not transition_active then refresh_monster_cache() end
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
            append_line("SOURCE_REJECTED", string.format(
                "class=%s obj=%s reason=%s active=%d:%s",
                class_name or "nil",
                obj_name or "nil",
                owner_method or "not linked to DsPC roster",
                active_pc,
                active_name
            ))
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


-- v4.0 aggregate attribution.
-- We do not identify which monster received a particular number. The meter only
-- needs the aggregate outgoing damage and the character who dealt it.
local function resolve_aggregate_last_attacker(damage, critical)
    local scan_time = now()
    if (scan_time - aggregate_cache_time) < AGGREGATE_SCAN_INTERVAL_SECONDS then
        return aggregate_cache_owner, aggregate_cache_method
    end

    aggregate_cache_time = scan_time
    last_attacker_scan_no = last_attacker_scan_no + 1

    local monsters = get_valid_monster_cache()

    if monsters == nil or #monsters == 0 then
        aggregate_cache_owner = nil
        aggregate_cache_method = "last_attacker_monsters_empty"
        return nil, aggregate_cache_method
    end

    local unique = {}
    local unique_count = 0
    local inspected = 0
    local candidate_count = 0

    for _, monster in ipairs(monsters) do
        if monster ~= nil and safe_call(function() return monster:IsValid() end, false) then
            inspected = inspected + 1

            local attacker = get_property(monster, "LastAttacker")
            if attacker ~= nil then
                local owner, owner_method = resolve_owner_chain(attacker)
                if owner ~= nil and owner ~= "Unknown" then
                    candidate_count = candidate_count + 1
                    if unique[owner] == nil then
                        unique[owner] = {
                            count = 1,
                            method = owner_method,
                            monster = monster
                        }
                        unique_count = unique_count + 1
                    else
                        unique[owner].count = unique[owner].count + 1
                        unique[owner].monster = monster
                    end
                end
            end
        end
    end

    local selected = nil
    local method = nil

    -- When only one party member appears in LastAttacker across all monsters,
    -- target identity is irrelevant: every outgoing number belongs to that member.
    if unique_count == 1 then
        for owner, data in pairs(unique) do
            selected = owner
            set_current_enemy(data.monster)
            method = string.format(
                "aggregate_last_attacker unique=1 matches=%d via=%s",
                data.count,
                data.method or "unknown"
            )
        end
    -- Old LastAttacker values may remain on several monsters. Prefer the currently
    -- controlled character only when it is one of the SDK-confirmed candidates.
    elseif unique_count > 1 and unique[active_name] ~= nil then
        selected = active_name
        set_current_enemy(unique[active_name].monster)
        method = string.format(
            "aggregate_last_attacker active_confirmed unique=%d matches=%d",
            unique_count,
            unique[active_name].count
        )
    end

    append_line("AGGREGATE_ATTACKER_SCAN", string.format(
        "scan=%d damage=%.1f critical=%s inspected=%d candidates=%d unique=%d selected=%s method=%s active=%d:%s",
        last_attacker_scan_no,
        damage,
        tostring(critical),
        inspected,
        candidate_count,
        unique_count,
        tostring(selected or "nil"),
        tostring(method or "ambiguous"),
        active_pc,
        active_name
    ))

    aggregate_cache_owner = selected
    aggregate_cache_method = method
    return selected, method
end

install_hook(
    "/Script/DS.DsPlayerController:ClientShowDamageText",
    function(Context, Damage, HitLocation, IsPlayer, bCritical)
        if transition_active then return end

        local damage = tonumber(read_param(Damage, 0)) or 0
        local is_player = read_param(IsPlayer, false) == true
        local critical = read_param(bCritical, false) == true

        if is_player then return end
        if damage <= 0 then return end

        local aggregate_owner, aggregate_method = resolve_aggregate_last_attacker(damage, critical)

        local t = now()
        ensure_session(t)

        table.insert(pending_damage, {
            time = t,
            damage = damage,
            critical = critical,
            active_index = active_pc,
            active_name = active_name,
            aggregate_owner = aggregate_owner,
            aggregate_method = aggregate_method
        })

        append_line("DAMAGE_PENDING", string.format(
            "damage=%.1f critical=%s active=%d:%s pending=%d",
            damage,
            tostring(critical),
            active_pc,
            active_name,
            #pending_damage
        ))
    end
)


-- Production build: diagnostic hooks removed to reduce overhead.

if RegisterKeyBind then
    local function bind_key(key, label, callback)
        local ok, err = pcall(function()
            RegisterKeyBind(key, callback)
        end)

        append_line(
            ok and "KEYBIND_OK" or "KEYBIND_ERROR",
            label .. (ok and "" or (" error=" .. tostring(err)))
        )
    end

    -- F6 is handled only here. Older builds also registered F6 in the WPF
    -- process, so one key press could execute two reset paths.
    bind_key(Key.F6, "F6 reset", function()
        update_active_character()
        reset_meter("F6")
    end)

    bind_key(Key.F9, "F9 overlay", function()
        launch_window()
    end)
end

if LoopAsync then
    LoopAsync(math.floor(ACTIVE_POLL_SECONDS * 1000), function()
        local ok, err = pcall(function()
            update_active_character()
            if not transition_active then
                local tick_time = now()
                prune_owner_resolution_cache(false)
                prune_sources(tick_time)
                process_pending_damage()
                finish_session_if_idle(tick_time)
            end
            process_window_command()
            write_state(false)
        end)

        if not ok then
            -- Recover on the next tick instead of letting one stale-object access
            -- terminate the Lua loop during level streaming or teleportation.
            enter_map_transition("loop error: " .. tostring(err))
        end
        return false
    end)
else
    append_line("WARN", "LoopAsync unavailable")
end

append_line("INIT_DONE", string.format(
    "dynamic_pawn=true cached_controller=true on_demand_monster_cache=true owner_cache_pruning=true optimized_aggregate=true stable_map_travel=true roster_refresh=%.1fs state_write=%.1fs combat_end_idle=%.1fs auto_save_min=%.1fs source_keep=%.1fs deferred=%.0fms",
    ROSTER_REFRESH_SECONDS,
    STATE_WRITE_SECONDS,
    COMBAT_END_IDLE_SECONDS,
    AUTO_SAVE_MIN_DURATION_SECONDS,
    SOURCE_KEEP_SECONDS,
    DAMAGE_DEFER_SECONDS * 1000.0
))

launch_window()
