-- Live Near Work for Surviving Mars Relaunched
-- Auto-relocates colonists closer to their workplace
-- Author: Evo-Eclipse@github
-- Version: 1.1

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

local function Log(msg, always)
    if always or LNW.Settings.debug then
        print("[LNW] " .. tostring(msg))
    end
end

local function LogTable(rows)
    if not LNW.Settings.debug or #rows == 0 then
        return
    end

    local w = {
        s = 6,
        n = 24,
        d = 26,
        h = 32,
        r = 20
    }

    print("")
    print(string.format("%-" .. w.s .. "s  %-" .. w.n .. "s  %-" .. w.d .. "s  %-" .. w.h .. "s  %-" .. w.r .. "s",
        "Status", "Colonist", "Dome Transfer", "Residence Transfer", "Reason"))
    print(string.rep("-", w.s) .. "  " .. string.rep("-", w.n) .. "  " .. string.rep("-", w.d) .. "  " ..
              string.rep("-", w.h) .. "  " .. string.rep("-", w.r))

    for _, r in ipairs(rows) do
        print(string.format("%-" .. w.s .. "s  %-" .. w.n .. "s  %-" .. w.d .. "s  %-" .. w.h .. "s  %-" .. w.r .. "s",
            r.status, r.name, r.domes, r.homes, r.reason))
    end
    print("")
end

-- MARK: - Utilities

local function GetName(obj)
    if not obj then
        return "---"
    end
    if type(obj) == "string" then
        return obj
    end
    if IsValid(obj) and obj.GetDisplayName then
        return _InternalTranslate(obj:GetDisplayName())
    end
    return obj.class or "???"
end

local function FormatColonist(colonist)
    if not IsValid(colonist) then
        return "???"
    end
    local spec_short = {
        engineer = "Eng",
        scientist = "Sci",
        medic = "Med",
        security = "Sec",
        geologist = "Geo",
        botanist = "Bot",
        none = "-"
    }
    return string.format("%s [%s]", GetName(colonist), spec_short[colonist.specialist] or "-")
end

-- MARK: - Game Queries

local function GetWorkplaceDome(colonist)
    local wp = colonist.workplace
    return IsValid(wp) and (wp.parent_dome or wp.dome) or nil
end

local function GetResidenceDome(colonist)
    local res = colonist.residence
    return IsValid(res) and (res.parent_dome or res.dome) or colonist.dome
end

-- Check if a colonist can live in a residence
-- Uses game's native properties: children_only, exclusive_trait
local function CanLiveIn(colonist, residence)
    if not IsValid(residence) then
        return false, "invalid"
    end
    if not residence.ui_working then
        return false, "disabled"
    end

    local traits = colonist.traits or {}

    -- Check children_only residences (Nursery, etc.)
    local is_child = traits.Child
    if residence.children_only and not is_child then
        return false, "children_only"
    end
    if is_child and not residence.children_only then
        return false, "need_nursery"
    end

    -- Check exclusive_trait (Tourist hotels, Senior residences, etc.)
    if residence.exclusive_trait and not traits[residence.exclusive_trait] then
        return false, "exclusive_" .. residence.exclusive_trait
    end

    -- Check if colonist is a Tourist trying to enter non-tourist housing
    if traits.Tourist and residence.exclusive_trait ~= "Tourist" then
        return false, "tourist_needs_hotel"
    end

    return true, "ok"
end

-- MARK: - Relocation Plan

-- Plan for handling cross-relocations (A: X→Y and B: Y→X simultaneously)
local Plan = {
    moves = {},
    reserved = {},
    vacating = {}
}

local function ClearPlan()
    Plan = {
        moves = {},
        reserved = {},
        vacating = {}
    }
end

-- Get available space accounting for planned moves
local function GetPlanFreeSpace(res)
    if not IsValid(res) then
        return 0
    end
    local h = res.handle
    return res:GetFreeSpace() - (Plan.reserved[h] or 0) + (Plan.vacating[h] or 0)
end

local function AddToPlan(colonist, from_res, to_res, to_dome, reason)
    table.insert(Plan.moves, {
        colonist = colonist,
        from_res = from_res,
        to_res = to_res,
        to_dome = to_dome,
        reason = reason
    })
    Plan.reserved[to_res.handle] = (Plan.reserved[to_res.handle] or 0) + 1
    if IsValid(from_res) then
        Plan.vacating[from_res.handle] = (Plan.vacating[from_res.handle] or 0) + 1
    end
end

-- MARK: - Residence Search

-- Find the best residence in a dome
-- Score = comfort + proximity_bonus (configurable via Settings)
-- Proximity bonus: max at dist=0, 0 at dist>=max_dist (linear interpolation)
local function FindBestResidence(colonist, dome, exclude)
    if not IsValid(dome) then
        return nil, 0, "no_dome"
    end

    local residences = dome.labels and dome.labels.Residence or {}
    if #residences == 0 then
        return nil, 0, "no_housing"
    end

    local best, best_score, reject_reason = nil, -999999, "no_space"
    local cur_comfort = exclude and exclude.service_comfort or 0
    local wp_pos = IsValid(colonist.workplace) and colonist.workplace:GetPos()
    local settings = LNW.Settings

    for _, res in ipairs(residences) do
        if res ~= exclude then
            local can, reason = CanLiveIn(colonist, res)
            if not can then
                reject_reason = reason
            elseif GetPlanFreeSpace(res) <= 0 then
                reject_reason = "no_space"
            else
                local score = res.service_comfort or 0

                -- Penalty for significant comfort decrease
                if score - cur_comfort < settings.max_comfort_loss then
                    score = score - 1000
                end

                -- Bonus for proximity to workplace
                -- Dist2D returns distance in game units
                if settings.allow_intra_dome and wp_pos then
                    local dist = res:GetPos():Dist2D(wp_pos)
                    local bonus = settings.dist_score_max - dist / settings.dist_score_step
                    score = score + math.max(0, bonus)
                end

                if score > best_score then
                    best_score, best = score, res
                end
            end
        end
    end

    return best, best_score, best and "ok" or reject_reason
end

local function AddToPlan(colonist, from_res, to_res, to_dome, reason)
    table.insert(Plan.moves, {
        colonist = colonist,
        from_res = from_res,
        to_res = to_res,
        to_dome = to_dome,
        reason = reason
    })
    Plan.reserved[to_res.handle] = (Plan.reserved[to_res.handle] or 0) + 1
    if IsValid(from_res) then
        Plan.vacating[from_res.handle] = (Plan.vacating[from_res.handle] or 0) + 1
    end
end

-- MARK: - Main Process

-- Check if colonist should be skipped from relocation
local function ShouldSkipColonist(colonist)
    if not IsValid(colonist) then
        return true, "invalid"
    end
    if colonist:IsDying() or colonist.leaving then
        return true, "dying_or_leaving"
    end
    if colonist.command == "Transport" or colonist.command == "TransportByFoot" then
        return true, "in_transport"
    end
    -- Skip tourists - they have their own housing logic
    if colonist.traits and colonist.traits.Tourist then
        return true, "tourist"
    end
    -- user_forced_residence is a table {residence, GameTime()} or nil
    if colonist.user_forced_residence then
        return true, "user_forced"
    end
    return false, nil
end

local function ProcessRelocationInternal()
    ClearPlan()
    local results = {}
    local inter, intra = 0, 0
    local settings = LNW.Settings

    -- Collect and filter candidates
    local candidates = {}
    for _, colonist in ipairs(UICity.labels.Colonist or {}) do
        local skip, reason = ShouldSkipColonist(colonist)
        if skip then
            goto skip
        end

        local wp_dome = GetWorkplaceDome(colonist)
        if not IsValid(wp_dome) then
            goto skip
        end

        local res_dome = GetResidenceDome(colonist)
        local is_inter = wp_dome ~= res_dome

        -- For inter-dome moves, verify domes are connected
        if is_inter and not AreDomesConnected(res_dome, wp_dome) then
            goto skip
        end

        if not is_inter and not settings.allow_intra_dome then
            goto skip
        end

        table.insert(candidates, {
            colonist = colonist,
            target = wp_dome,
            cur_res = colonist.residence,
            priority = is_inter and 2 or 1,
            type = is_inter and "workplace" or "distance"
        })
        ::skip::
    end

    -- Inter-dome relocations first (priority 2)
    table.sort(candidates, function(a, b)
        return a.priority > b.priority
    end)

    -- Planning phase
    for _, c in ipairs(candidates) do
        local best, best_score, reason = FindBestResidence(c.colonist, c.target, c.cur_res)
        local from_dome = GetResidenceDome(c.colonist)

        if not best or GetPlanFreeSpace(best) <= 0 then
            -- SKIP: no suitable housing available
            table.insert(results, {
                status = "SKIP",
                name = FormatColonist(c.colonist),
                domes = GetName(from_dome) .. " -> " .. GetName(c.target),
                homes = GetName(c.cur_res) .. " -> ???",
                reason = best and "plan_full" or reason
            })
            goto next
        end

        -- For intra-dome moves, verify significant improvement
        if c.priority == 1 then
            local cur_score = 0
            if IsValid(c.cur_res) then
                cur_score = c.cur_res.service_comfort or 0
                if IsValid(c.colonist.workplace) then
                    local dist = c.cur_res:GetPos():Dist2D(c.colonist.workplace:GetPos())
                    local bonus = settings.dist_score_max - dist / settings.dist_score_step
                    cur_score = cur_score + math.max(0, bonus)
                end
            end
            if best_score <= cur_score + settings.min_intra_score then
                goto next
            end
        end

        AddToPlan(c.colonist, c.cur_res, best, c.target, c.type)
        if c.priority == 2 then
            inter = inter + 1
        else
            intra = intra + 1
        end
        ::next::
    end

    -- Execution phase
    for _, m in ipairs(Plan.moves) do
        local colonist, to_res, to_dome = m.colonist, m.to_res, m.to_dome

        -- Verify objects are still valid and space is available
        if IsValid(colonist) and IsValid(to_res) and to_res:GetFreeSpace() > 0 then
            local from_dome, from_res = colonist.dome, m.from_res

            -- Clear user-forced residence (it's a table {residence, time} or nil)
            colonist.user_forced_residence = nil

            -- Set dome first, then residence
            -- Note: SetDome internally calls SetResidence(false), so order matters
            if IsValid(to_dome) and from_dome ~= to_dome then
                colonist:SetDome(to_dome)
            end
            colonist:SetResidence(to_res)

            table.insert(results, {
                status = "OK",
                name = FormatColonist(colonist),
                domes = GetName(from_dome) .. " -> " .. GetName(to_dome),
                homes = GetName(from_res) .. " -> " .. GetName(to_res),
                reason = m.reason
            })
        end
    end

    -- Output results
    LogTable(results)

    local ok_count = 0
    for _, r in ipairs(results) do
        if r.status == "OK" then
            ok_count = ok_count + 1
        end
    end

    if ok_count > 0 then
        Log(string.format("Done: %d relocated (%d inter-dome, %d intra-dome)", ok_count, inter, intra), true)
    elseif #results > 0 then
        Log(string.format("Done: 0 relocated, %d skipped", #results))
    end
end

-- Safe wrapper with error handling
local function ProcessRelocation()
    if not LNW.Settings.enabled or not UICity then
        return
    end

    local ok, err = pcall(ProcessRelocationInternal)
    if not ok then
        Log("ERROR: " .. tostring(err), true)
    end
end

-- MARK: - Event Handlers

function OnMsg.NewHour(hour)
    for _, h in ipairs(LNW.Settings.trigger_hours) do
        if hour == h then
            CreateGameTimeThread(function()
                -- Delay to let colonists settle into their shifts
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
function LNW.Enable() LNW.Settings.enabled = true; Log("Enabled", true) end
function LNW.Disable() LNW.Settings.enabled = false; Log("Disabled", true) end
function LNW.DebugEnable() LNW.Settings.debug = true; Log("Debug: true", true) end
function LNW.DebugDisable() LNW.Settings.debug = false; Log("Debug: false", true) end
