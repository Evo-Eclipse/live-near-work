-- Live Near Work for Surviving Mars Relaunched
-- Auto-relocates colonists closer to their workplace
-- Author: Evo-Eclipse@github
-- Version: 1.2

-- MARK: - Configuration
LiveNearWork = {
    Settings = {
        enabled = true,
        debug = false,
        -- Triggers
        trigger_hours = {6, 14, 22},
        scan_delay = 500,
        -- Rules
        allow_intra_dome = true,
        max_comfort_loss = -10,
        min_intra_score = 10,
        -- Scoring
        dist_score_max = 50,
        dist_score_step = 1000
    }
}

local LNW = LiveNearWork

-- MARK: - Logging

-- Prints a message to console if debug mode is enabled or 'always' flag is set
local function Log(msg, always)
    if always or LNW.Settings.debug then print("[LNW] " .. tostring(msg)) end
end

-- Prints a formatted table of relocation results (only in debug mode)
local function LogTable(rows)
    if not LNW.Settings.debug or #rows == 0 then return end

    local fmt = "%-6s  %-24s  %-26s  %-32s  %-20s"
    print("")
    print(fmt:format("Status", "Colonist", "Dome Transfer", "Residence Transfer", "Reason"))
    print(("-"):rep(116))

    for _, row in ipairs(rows) do
        print(fmt:format(row.status, row.name, row.domes, row.homes, row.reason))
    end
    print("")
end

-- MARK: - Utilities

-- Returns a display name for any game object or a placeholder if invalid
local function GetName(obj)
    if not obj then return "---" end
    if type(obj) == "string" then return obj end
    if IsValid(obj) and obj.GetDisplayName then return _InternalTranslate(obj:GetDisplayName()) end
    return obj.class or "???"
end

-- Formats colonist info as "Name [Spec]" for logging
local SpecShort = {
    engineer = "Eng",
    scientist = "Sci",
    medic = "Med",
    security = "Sec",
    geologist = "Geo",
    botanist = "Bot",
    none = "-"
}

local function FormatColonist(colonist)
    if not IsValid(colonist) then return "???" end
    return ("%s [%s]"):format(GetName(colonist), SpecShort[colonist.specialist] or "-")
end

-- MARK: - Game Queries

-- Returns the dome where colonist's workplace is located
local function GetWorkplaceDome(colonist)
    local workplace = colonist.workplace
    return IsValid(workplace) and (workplace.parent_dome or workplace.dome) or nil
end

-- Returns the dome where colonist currently lives
local function GetResidenceDome(colonist)
    local residence = colonist.residence
    return IsValid(residence) and (residence.parent_dome or residence.dome) or colonist.dome
end

-- Checks if a colonist can live in a specific residence
-- Uses game's native properties: children_only, exclusive_trait
local function CanLiveIn(colonist, residence)
    if not IsValid(residence) or not residence.ui_working then return false end

    local traits = colonist.traits or {}
    local is_child = traits.Child

    -- Children can only live in children_only residences (Nursery)
    -- Adults cannot live in children_only residences
    if residence.children_only ~= (is_child and true or false) then return false end

    -- Check exclusive_trait (Tourist hotels, Senior residences, etc.)
    if residence.exclusive_trait and not traits[residence.exclusive_trait] then return false end

    -- Tourists can only stay in Tourist-exclusive residences
    if traits.Tourist and residence.exclusive_trait ~= "Tourist" then return false end

    return true
end

-- MARK: - Relocation Plan

-- Plan structure for handling cross-relocations
-- (e.g., colonist A: X→Y and colonist B: Y→X simultaneously)
local Plan = {
    moves = {},     -- List of planned moves
    reserved = {},  -- Spaces reserved in target residences (by handle)
    vacating = {}   -- Spaces being freed in source residences (by handle)
}

local function ClearPlan()
    Plan = {
        moves = {},
        reserved = {},
        vacating = {}
    }
end

-- Returns available space in residence, accounting for planned moves
local function GetPlanFreeSpace(residence)
    if not IsValid(residence) then return 0 end
    local handle = residence.handle
    local reserved = Plan.reserved[handle] or 0
    local vacating = Plan.vacating[handle] or 0
    return residence:GetFreeSpace() - reserved + vacating
end

-- Adds a colonist move to the plan and updates space tracking
local function AddToPlan(colonist, from_residence, to_residence, to_dome, reason)
    table.insert(Plan.moves, {
        colonist = colonist,
        from_res = from_residence,
        to_res = to_residence,
        to_dome = to_dome,
        reason = reason
    })

    -- Reserve a space in the target residence
    local to_handle = to_residence.handle
    Plan.reserved[to_handle] = (Plan.reserved[to_handle] or 0) + 1

    -- Mark a space as being vacated in the source residence
    if IsValid(from_residence) then
        local from_handle = from_residence.handle
        Plan.vacating[from_handle] = (Plan.vacating[from_handle] or 0) + 1
    end
end

-- MARK: - Residence Search

-- Calculates a score for a residence based on comfort and proximity to workplace
-- Higher score = better residence for this colonist
local function CalcResidenceScore(residence, workplace_pos, base_comfort)
    local settings = LNW.Settings
    local score = residence.service_comfort or 0

    -- Penalty for significant comfort decrease (makes this residence less desirable)
    if score - base_comfort < settings.max_comfort_loss then
        score = score - 1000
    end

    -- Bonus for proximity to workplace (linear: max points at dist=0, 0 at max distance)
    if settings.allow_intra_dome and workplace_pos then
        local distance = residence:GetPos():Dist2D(workplace_pos)
        local proximity_bonus = settings.dist_score_max - distance / settings.dist_score_step
        score = score + math.max(0, proximity_bonus)
    end

    return score
end

-- Finds the best available residence in a dome for a colonist
-- Returns: best_residence, best_score (or nil, 0 if none found)
local function FindBestResidence(colonist, dome, exclude_residence)
    if not IsValid(dome) then return nil, 0 end

    local residences = dome.labels and dome.labels.Residence or {}
    if #residences == 0 then return nil, 0 end

    local best_residence = nil
    local best_score = -999999
    local base_comfort = exclude_residence and exclude_residence.service_comfort or 0
    local workplace_pos = IsValid(colonist.workplace) and colonist.workplace:GetPos()

    for _, residence in ipairs(residences) do
        -- Skip current residence, incompatible residences, and full residences
        if residence ~= exclude_residence and CanLiveIn(colonist, residence) and GetPlanFreeSpace(residence) > 0 then
            local score = CalcResidenceScore(residence, workplace_pos, base_comfort)
            if score > best_score then
                best_score = score
                best_residence = residence
            end
        end
    end

    return best_residence, best_score
end

-- MARK: - Main Process

-- Checks if a colonist should be skipped from relocation processing
local function ShouldSkipColonist(colonist)
    if not IsValid(colonist) or colonist:IsDying() or colonist.leaving then return true end

    -- Skip colonists currently in transport
    local command = colonist.command
    if command == "Transport" or command == "TransportByFoot" then return true end

    -- Skip tourists - they have their own housing logic via hotels
    local traits = colonist.traits
    if traits and traits.Tourist then return true end

    -- Skip colonists with manually assigned residence (user_forced_residence is {residence, GameTime()})
    if colonist.user_forced_residence then return true end

    return false
end

-- Main relocation processing logic (called via pcall for error safety)
local function ProcessRelocationInternal()
    ClearPlan()

    local results = {}
    local inter_dome_count = 0
    local intra_dome_count = 0
    local settings = LNW.Settings

    -- Phase 1: Collect candidates for relocation
    local candidates = {}

    for _, colonist in ipairs(UICity.labels.Colonist or {}) do
        if not ShouldSkipColonist(colonist) then
            local workplace_dome = GetWorkplaceDome(colonist)

            if IsValid(workplace_dome) then
                local residence_dome = GetResidenceDome(colonist)
                local is_inter_dome = workplace_dome ~= residence_dome

                -- For inter-dome moves: verify domes are connected (passage/shuttle)
                -- For intra-dome moves: only process if enabled in settings
                local should_process = false
                if is_inter_dome then
                    should_process = AreDomesConnected(residence_dome, workplace_dome)
                else
                    should_process = settings.allow_intra_dome
                end

                if should_process then
                    table.insert(candidates, {
                        colonist = colonist,
                        target_dome = workplace_dome,
                        current_residence = colonist.residence,
                        priority = is_inter_dome and 2 or 1,  -- Inter-dome = higher priority
                        move_type = is_inter_dome and "workplace" or "distance"
                    })
                end
            end
        end
    end

    -- Sort candidates: inter-dome moves first (priority 2), then intra-dome (priority 1)
    table.sort(candidates, function(a, b)
        return a.priority > b.priority
    end)

    -- Phase 2: Plan moves
    for _, candidate in ipairs(candidates) do
        local colonist = candidate.colonist
        local best_residence, best_score = FindBestResidence(colonist, candidate.target_dome, candidate.current_residence)
        local from_dome = GetResidenceDome(colonist)

        if not best_residence or GetPlanFreeSpace(best_residence) <= 0 then
            -- No suitable housing available
            table.insert(results, {
                status = "SKIP",
                name = FormatColonist(colonist),
                domes = GetName(from_dome) .. " -> " .. GetName(candidate.target_dome),
                homes = GetName(candidate.current_residence) .. " -> ???",
                reason = "no_space"
            })
        elseif candidate.priority == 1 then
            -- Intra-dome move: only proceed if improvement is significant
            local current_score = 0
            if IsValid(candidate.current_residence) then
                local workplace_pos = IsValid(colonist.workplace) and colonist.workplace:GetPos()
                current_score = CalcResidenceScore(candidate.current_residence, workplace_pos, 0)
            end

            if best_score > current_score + settings.min_intra_score then
                AddToPlan(colonist, candidate.current_residence, best_residence, candidate.target_dome, candidate.move_type)
                intra_dome_count = intra_dome_count + 1
            end
        else
            -- Inter-dome move: always proceed if housing available
            AddToPlan(colonist, candidate.current_residence, best_residence, candidate.target_dome, candidate.move_type)
            inter_dome_count = inter_dome_count + 1
        end
    end

    -- Phase 3: Execute planned moves
    for _, move in ipairs(Plan.moves) do
        local colonist = move.colonist
        local to_residence = move.to_res
        local to_dome = move.to_dome

        -- Final validation before execution
        if IsValid(colonist) and IsValid(to_residence) and to_residence:GetFreeSpace() > 0 then
            local from_dome = colonist.dome
            local from_residence = move.from_res

            -- Clear any user-forced residence flag
            colonist.user_forced_residence = nil

            -- Set dome first, then residence
            -- Note: SetDome() internally calls SetResidence(false), so order matters
            if IsValid(to_dome) and from_dome ~= to_dome then
                colonist:SetDome(to_dome)
            end
            colonist:SetResidence(to_residence)

            table.insert(results, {
                status = "OK",
                name = FormatColonist(colonist),
                domes = GetName(from_dome) .. " -> " .. GetName(to_dome),
                homes = GetName(from_residence) .. " -> " .. GetName(to_residence),
                reason = move.reason
            })
        end
    end

    -- Output results
    LogTable(results)

    local ok_count = 0
    for _, result in ipairs(results) do
        if result.status == "OK" then
            ok_count = ok_count + 1
        end
    end

    if ok_count > 0 then
        Log(("Done: %d relocated (%d inter-dome, %d intra-dome)"):format(ok_count, inter_dome_count, intra_dome_count), true)
    elseif #results > 0 then
        Log(("Done: 0 relocated, %d skipped"):format(#results))
    end
end

-- Safe wrapper with error handling
local function ProcessRelocation()
    if not LNW.Settings.enabled or not UICity then return end

    local ok, err = pcall(ProcessRelocationInternal)
    if not ok then
        Log("ERROR: " .. tostring(err), true)
    end
end

-- MARK: - Event Handlers

function OnMsg.NewHour(hour)
    for _, trigger_hour in ipairs(LNW.Settings.trigger_hours) do
        if hour == trigger_hour then
            CreateGameTimeThread(function()
                Sleep(LNW.Settings.scan_delay)
                ProcessRelocation()
            end)
            break
        end
    end
end

function OnMsg.CityStart() Log("LNW loaded", true) end
function OnMsg.LoadGame() Log("LNW active", true) end

-- MARK: - Public API

function LNW.Run() ProcessRelocation() end

function LNW.Enable()
    LNW.Settings.enabled = true
    Log("Enabled", true)
end

function LNW.Disable()
    LNW.Settings.enabled = false
    Log("Disabled", true)
end

function LNW.DebugEnable()
    LNW.Settings.debug = true
    Log("Debug: true", true)
end

function LNW.DebugDisable()
    LNW.Settings.debug = false
    Log("Debug: false", true)
end
