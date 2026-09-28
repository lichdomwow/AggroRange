-- AggroRange - v1.0.0
-- Classic Era / Hardcore 1.15.9
-- The displayed aggro clearance is an estimate, not a guarantee of Blizzard
-- server behavior.

local ADDON_NAME = ...
local VERSION = "1.0.0"
local AR = CreateFrame("Frame")

local UPDATE_INTERVAL = 0.10
local DEFAULT_BASE = 18
local DEFAULT_MIN_RADIUS = 5
local DEFAULT_CALIBRATION_OFFSET = 5
local MAX_HIGHER_MOB_LEVEL_DELTA = 25
local MAX_LOGS = 100
local MAX_DIAGNOSTIC_LOGS = 250
local AGGRO_DISPLAY_SECONDS = 1.5
local MIND_SOOTHE_REDUCTION = 10
local NAMEPLATE_DISTANCE_CVAR = "nameplateMaxDistance"
local RECOMMENDED_NAMEPLATE_DISTANCE = 41
local TEST_PULLS_PER_BUCKET = 5
local EXCEPTION_OBSERVATION_SCHEMA = 1
local TEST_BUCKETS = {0, 2, 4, 6, 8, 10}
local MIND_SOOTHE_IDS = {[453] = true, [8192] = true, [10953] = true}

local COLORS = {
    safe = {0.20, 1.00, 0.20},
    threshold = {1.00, 0.82, 0.15},
    danger = {1.00, 0.20, 0.20},
    neutral = {0.85, 0.85, 0.85},
    dim = {0.60, 0.60, 0.60},
    title = {0.40, 0.80, 1.00},
}

local defaults = {
    baseDetection = DEFAULT_BASE,
    minRadius = DEFAULT_MIN_RADIUS,
    calibrationOffset = DEFAULT_CALIBRATION_OFFSET,
    showPanel = false,
    showNameplate = true,
    debugChat = false,
    panelPoint = {"CENTER", "UIParent", "CENTER", 300, 0},
    overrides = {},
    pullLog = {},
    diagnosticLog = {},
    exceptionObservations = {},
    validatedExceptions = {},
    testMode = false,
    distanceHintShown = false,
}

local panel
local plateOverlay
local plateText
local targetFrameOverlay
local targetFrameText
local mouseoverOverlay
local mouseoverText
local currentPlateAnchor
local currentTargetFrameAnchor
local currentMouseoverAnchor
local elapsedSinceUpdate = 0
local current = {}
local previousThreatEngaged = false
local lastPreAggroSnapshot = nil
local lastPreAggroGUID = nil
local aggroDisplayUntil = 0
local traceGUID = nil
local traceTransitions = {}
local traceLastKey = nil
local prePullContaminated = false
local prePullContaminationReason = nil

-- Direct item probes mirror one representative Era harmful item from each
-- useful bucket. This is the self-contained primary range engine.
local ITEM_PROBES = {
    {5, 8149, "Voodoo Charm"},
    {10, 9606, "Treant Muisek Vessel"},
    {15, 4559, "CHU's QUEST ITEM"},
    {20, 1191, "Bag of Marbles"},
    {25, 13289, "Egan's Blaster"},
    {30, 835, "Large Rope Net"},
    {35, 18904, "Zorbin's Ultra-Shrinker"},
    {40, 4945, "Faintly Glowing Skull"},
}

-- Fixed state buffers avoid allocating eight probe-result tables every 0.10 s.
-- Target and mouseover must use separate buffers because both can be displayed
-- in the same update pass.
local PROBE_STATE_BUFFERS = {
    target = {},
    mouseover = {},
}

local INVALID_TARGET_DATA = { unit = 'target', valid = false, ignoreReason = 'missing' }
local INVALID_MOUSEOVER_DATA = { unit = 'mouseover', valid = false, ignoreReason = 'missing' }


local function CopyDefaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            if type(v) == "table" then
                dst[k] = {}
                CopyDefaults(dst[k], v)
            else
                dst[k] = v
            end
        elseif type(v) == "table" and type(dst[k]) == "table" then
            CopyDefaults(dst[k], v)
        end
    end
end

local function Round1(n)
    if not n then return nil end
    return math.floor(n * 10 + 0.5) / 10
end

local function FormatNumber(n)
    if n == nil then return "?" end
    if math.abs(n - math.floor(n)) < 0.001 then
        return tostring(math.floor(n))
    end
    return string.format("%.1f", n)
end

local function RoundNearestInt(n)
    if n == nil then return nil end
    if n >= 0 then return math.floor(n + 0.5) end
    return math.ceil(n - 0.5)
end

local function FormatIndicatorNumber(n)
    local rounded = RoundNearestInt(n)
    return rounded and tostring(rounded) or "?"
end

local function SetColor(fontString, color)
    fontString:SetTextColor(color[1], color[2], color[3])
end

local function BoolState(v)
    if v == true or v == 1 then return "IN" end
    if v == false or v == 0 then return "OUT" end
    return "nil"
end

local function GetNameplateDistance()
    local value
    if C_CVar and C_CVar.GetCVar then
        local ok, result = pcall(C_CVar.GetCVar, NAMEPLATE_DISTANCE_CVAR)
        if ok then value = result end
    elseif GetCVar then
        local ok, result = pcall(GetCVar, NAMEPLATE_DISTANCE_CVAR)
        if ok then value = result end
    end
    return tonumber(value)
end

local function SetNameplateDistance(value)
    if C_CVar and C_CVar.SetCVar then
        return pcall(C_CVar.SetCVar, NAMEPLATE_DISTANCE_CVAR, tostring(value))
    elseif SetCVar then
        return pcall(SetCVar, NAMEPLATE_DISTANCE_CVAR, tostring(value))
    end
    return false
end

local function MaybePrintNameplateDistanceHint()
    if AggroRangeDB.distanceHintShown then return end
    local currentDistance = GetNameplateDistance()
    if not currentDistance then return end

    AggroRangeDB.distanceHintShown = true
    if currentDistance + 0.01 < RECOMMENDED_NAMEPLATE_DISTANCE then
        print(string.format(
            '|cff66ccffAggroRange|r: mouseover works best with Nameplate Distance at maximum (%d yd). Current: %s yd. Use |cffffffff/ar distance max|r or change it under Options > Nameplates.',
            RECOMMENDED_NAMEPLATE_DISTANCE, FormatNumber(currentDistance)))
    end
end

local function ProbeState(raw)
    -- Use explicit string states rather than storing OUT as boolean false.
    -- This avoids false/nil ambiguity anywhere in the diagnostic pipeline.
    if raw == true or raw == 1 then return "IN" end
    if raw == false or raw == 0 then return "OUT" end
    return "NIL"
end

local function SummarizeProbeStates(states, apiError)
    if apiError then return apiError end
    local out = {}
    for i, probe in ipairs(ITEM_PROBES) do
        out[i] = FormatNumber(probe[1]) .. ":" .. tostring(states and states[i] or "?")
    end
    return #out > 0 and table.concat(out, "  ") or "No usable probes"
end

local function ProbeUnitRange(unit, states)
    unit = unit or "target"
    states = states or {}

    if not C_Item or not C_Item.IsItemInRange then
        for i = 1, #ITEM_PROBES do states[i] = nil end
        local err = "C_Item.IsItemInRange unavailable"
        return nil, nil, false, err, err, states
    end

    local lastOut = nil
    local firstIn = nil
    local sawIn = false
    local usableCount = 0
    local nonMonotonic = false

    -- Probe every bucket even if one result is odd. Besides finding the bracket,
    -- the full linear pass is an intentional Hardcore safety check for
    -- non-monotonic API results.
    for i, probe in ipairs(ITEM_PROBES) do
        local ok, raw = pcall(C_Item.IsItemInRange, probe[2], unit)
        local state = ok and ProbeState(raw) or "ERR"
        states[i] = state

        if state == "OUT" then
            usableCount = usableCount + 1
            if sawIn then nonMonotonic = true end
            lastOut = probe[1]
        elseif state == "IN" then
            usableCount = usableCount + 1
            sawIn = true
            if firstIn == nil then firstIn = probe[1] end
        end
    end

    if nonMonotonic then
        return nil, nil, false, "Non-monotonic probes: OUT after IN", nil, states
    end
    if usableCount == 0 then
        return nil, nil, false, "No usable item probe results", nil, states
    end
    if lastOut ~= nil and firstIn ~= nil then
        if lastOut >= firstIn then
            return nil, nil, false, "Conflicting item probe boundaries", nil, states
        end
        return lastOut, firstIn, true,
            FormatNumber(lastOut) .. ":OUT -> " .. FormatNumber(firstIn) .. ":IN", nil, states
    end
    if firstIn ~= nil then
        return nil, firstIn, true,
            "all shorter probes IN; <= " .. FormatNumber(firstIn) .. " yd", nil, states
    end
    if lastOut ~= nil then
        return lastOut, nil, true,
            "all available probes OUT; > " .. FormatNumber(lastOut) .. " yd", nil, states
    end

    return nil, nil, false, "Unable to derive item range band", nil, states
end

local function GetItemProbeSummary(data)
    if not data then return "No usable probes" end
    if data.itemProbeSummary == nil then
        data.itemProbeSummary = SummarizeProbeStates(data.probeStates, data.itemProbeError)
    end
    return data.itemProbeSummary
end

local function GetNPCID(unit)
    local guid = UnitGUID(unit)
    if not guid then return nil end

    local unitType, _, _, _, _, npcID = strsplit("-", guid)
    if unitType ~= "Creature" and unitType ~= "Vehicle" then
        return nil
    end
    return tonumber(npcID)
end

local function GetUnitEligibility(unit)
    if not UnitExists(unit) then return false, "missing" end
    if UnitIsDeadOrGhost(unit) then return false, "dead" end

    local npcID = GetNPCID(unit)
    if not npcID then return false, "non-NPC" end
    if not UnitCanAttack("player", unit) then return false, "not attackable", npcID end

    -- Yellow/neutral mobs can be attacked but do not proximity-aggro, so they
    -- are outside AggroRange's purpose. Reaction 1-3 is hostile/unfriendly;
    -- 4 is neutral and 5+ is friendly/reputation-based. If reaction is
    -- unexpectedly unavailable, UnitIsEnemy is the fallback hostility check.
    local reaction = UnitReaction and UnitReaction(unit, "player") or nil
    if reaction and reaction >= 4 then
        return false, reaction == 4 and "neutral" or "friendly", npcID, reaction
    end
    if UnitIsEnemy and not UnitIsEnemy("player", unit) then
        return false, "non-hostile", npcID, reaction
    end

    return true, nil, npcID, reaction
end

local function GetManualOverride(npcID)
    if not npcID then return nil end
    local value = AggroRangeDB.overrides[npcID]
    if value == nil then value = AggroRangeDB.overrides[tostring(npcID)] end
    return tonumber(value)
end

local function GetBuiltinException(npcID)
    if not npcID or not AggroRangeBuiltinExceptions then return nil end
    return AggroRangeBuiltinExceptions[npcID]
end

local function GetResearchException(npcID)
    if not npcID or not AggroRangeExceptionResearch then return nil end
    return AggroRangeExceptionResearch[npcID]
end

local function IsExceptionValidated(npcID)
    if not npcID then return false end
    return AggroRangeDB.validatedExceptions[npcID] == true or AggroRangeDB.validatedExceptions[tostring(npcID)] == true
end

local function GetDetectionProfile(npcID)
    local manual = GetManualOverride(npcID)
    if manual ~= nil then
        return manual, 'manual', true, nil
    end
    local builtin = GetBuiltinException(npcID)
    if builtin then
        return tonumber(builtin.detection), builtin.source or 'CMaNGOS', IsExceptionValidated(npcID), builtin
    end
    return AggroRangeDB.baseDetection, 'baseline', true, nil
end

local function GetMindSootheInfo(unit)
    unit = unit or 'target'
    if not UnitExists(unit) then return false, nil, nil end
    for i = 1, 16 do
        local name, _, _, _, duration, expirationTime, source, _, _, spellID = UnitDebuff(unit, i)
        if not name then break end
        if spellID and MIND_SOOTHE_IDS[spellID] then
            return true, spellID, expirationTime
        end
    end
    return false, nil, nil
end

local function ResolveTargetLevel(playerLevel, npcID, unit)
    unit = unit or 'target'
    local reported = UnitLevel(unit)
    local classification = UnitClassification(unit) or 'normal'
    if reported and reported >= 0 then
        return reported, reported, classification, 'api'
    end

    -- UnitLevel returns -1 for skull bosses / ?? units. For skull-type bosses,
    -- level-based calculations use player+3. This keeps raid/world bosses in
    -- scope rather than suppressing the feature entirely.
    if classification == 'worldboss' and playerLevel then
        return playerLevel + 3, reported, classification, 'worldboss+3'
    end

    -- If an emulator exception entry carries a concrete Vanilla level, use it
    -- as a provisional fallback for a non-boss skull target.
    local builtin = GetBuiltinException(npcID) or GetResearchException(npcID)
    if builtin and builtin.minLevel and builtin.maxLevel then
        local estimated = math.floor((tonumber(builtin.minLevel) + tonumber(builtin.maxLevel)) / 2 + 0.5)
        return estimated, reported, classification, 'exception-db-level'
    end

    return nil, reported, classification, 'unknown-skull'
end

local function CalculateAggroRadius(playerLevel, targetLevel, base, mindSoothed)
    if not playerLevel or not targetLevel then return nil, nil, nil, nil end

    local levelDifference = playerLevel - targetLevel
    local effectiveDifference = math.max(levelDifference, -MAX_HIGHER_MOB_LEVEL_DELTA)

    local levelAdjusted = base - effectiveDifference
    local sootheModifier = mindSoothed and -MIND_SOOTHE_REDUCTION or 0

    -- Keep the natural minimum before applying our empirical measurement
    -- calibration. Detection=0 remains a special no-proximity-aggro value.
    local rawRadius
    if base == 0 then
        rawRadius = 0
    else
        rawRadius = math.max(AggroRangeDB.minRadius or DEFAULT_MIN_RADIUS, levelAdjusted + sootheModifier)
    end

    local calibrationOffset = AggroRangeDB.calibrationOffset or DEFAULT_CALIBRATION_OFFSET
    local adjustedRadius = math.max(0, rawRadius - calibrationOffset)

    return adjustedRadius, levelDifference, rawRadius, levelAdjusted
end

local function GetThreatEngaged(unit)
    unit = unit or "target"
    if not UnitExists(unit) or not UnitCanAttack("player", unit) then
        return false, nil
    end

    if UnitDetailedThreatSituation then
        local _, status = UnitDetailedThreatSituation("player", unit)
        if status ~= nil then
            return true, status
        end
    end

    local unitTarget = unit .. "target"
    if UnitExists(unitTarget) and UnitIsUnit(unitTarget, "player") then
        return true, nil
    end

    return false, nil
end

local function DetermineState(minRange, maxRange, aggroRadius, threatEngaged)
    if threatEngaged then
        return "danger", nil, "AGGRO", nil, nil, nil
    end

    if aggroRadius == nil then
        -- A hostile unit can occasionally have no usable level (most notably
        -- an unresolved skull/?? target). Never turn that uncertainty into a
        -- reassuring-looking radius. Show an explicit unknown warning instead.
        return "threshold", nil, "?", nil, nil, nil
    end

    -- Range probes give us an interval rather than an exact point. For the
    -- gameplay indicator, AggroRange shows the BEST ESTIMATE: the midpoint of
    -- the current finite probe band minus the working aggro radius. This is
    -- deliberately different from the old guaranteed-minimum display, which
    -- collapsed to +0 for most of the interesting approach.
    --
    -- We preserve the full possible margin interval in the diagnostic panel.
    local possibleLow = minRange and (minRange - aggroRadius) or nil
    local possibleHigh = maxRange and (maxRange - aggroRadius) or nil
    local estimate, uncertainty

    if minRange and maxRange then
        estimate = ((minRange + maxRange) / 2) - aggroRadius
        uncertainty = (maxRange - minRange) / 2
    elseif maxRange then
        -- Close-range open interval: treat 0..max as the available measurement
        -- band for the diagnostic estimate. At this point the player is already
        -- very near the mob, so this is mainly useful for calibration.
        estimate = (maxRange / 2) - aggroRadius
        uncertainty = maxRange / 2
    elseif minRange then
        -- Far-range open interval. We cannot form a midpoint, but if the lower
        -- bound itself is beyond the predicted aggro radius we can still state
        -- a useful minimum clearance.
        if minRange > aggroRadius then
            local margin = minRange - aggroRadius
            return "safe", margin, ">+" .. FormatIndicatorNumber(margin) .. " yd", possibleLow, possibleHigh, nil
        end
        return "threshold", nil, "?", possibleLow, possibleHigh, nil
    else
        return "neutral", nil, "?", nil, nil, nil
    end

    local label
    if estimate > 0.05 then
        label = "+" .. FormatIndicatorNumber(estimate) .. " yd"
    elseif estimate < -0.05 then
        label = FormatIndicatorNumber(estimate) .. " yd"
    else
        label = "0 yd"
    end

    -- Color/state is based on the WHOLE possible interval, not merely the
    -- midpoint. Green means the entire measured band is outside the predicted
    -- boundary; red means the entire band is inside; yellow means it straddles
    -- the boundary. The number itself remains the midpoint estimate.
    local state
    if possibleLow and possibleLow >= 0 then
        state = "safe"
    elseif possibleHigh and possibleHigh <= 0 then
        state = "danger"
    else
        state = "threshold"
    end

    return state, estimate, label, possibleLow, possibleHigh, uncertainty
end

local function FormatRange(minRange, maxRange)
    if minRange and maxRange then
        return FormatNumber(minRange) .. "–" .. FormatNumber(maxRange) .. " yd"
    elseif minRange then
        return "> " .. FormatNumber(minRange) .. " yd"
    elseif maxRange then
        return "≤ " .. FormatNumber(maxRange) .. " yd"
    end
    return "Unavailable"
end

local function GetInteractDiagnostics(unit)
    unit = unit or "target"
    if not CheckInteractDistance then return "Unavailable" end
    local ok3, r3 = pcall(CheckInteractDistance, unit, 3)
    local ok4, r4 = pcall(CheckInteractDistance, unit, 4)
    return string.format("#3=%s  #4=%s", ok3 and BoolState(r3) or "ERR", ok4 and BoolState(r4) or "ERR")
end

local function Snapshot(data)
    return {
        time = date("%Y-%m-%d %H:%M:%S"),
        name = data.name,
        npcID = data.npcID,
        playerLevel = data.playerLevel,
        targetLevel = data.targetLevel,
        baseDetection = data.baseDetection,
        override = data.override,
        aggroRadius = data.aggroRadius,
        rawAggroRadius = data.rawAggroRadius,
        calibrationOffset = data.calibrationOffset,
        minRange = data.minRange,
        maxRange = data.maxRange,
        rangeSource = data.rangeSource,
        directRangeOK = data.directRangeOK,
        directRangeNote = data.directRangeNote,
        itemProbeSummary = GetItemProbeSummary(data),
        state = data.state,
        classification = data.classification,
        creatureType = data.creatureType,
        targetLevelReported = data.targetLevelReported,
        targetLevelSource = data.targetLevelSource,
        detectionSource = data.detectionSource,
        exceptionValidated = data.exceptionValidated,
        exceptionProvisional = data.exceptionProvisional,
        exceptionCandidate = data.exceptionRecord ~= nil,
        exceptionPolicy = data.exceptionRecord and data.exceptionRecord.policy or nil,
        mindSoothed = data.mindSoothed,
        mindSootheSpellID = data.mindSootheSpellID,
        levelAdjustedRadius = data.levelAdjustedRadius,
        levelDifference = data.levelDifference,
    }
end

local function PushPullLog(pre, first)
    local log = {
        time = date("%Y-%m-%d %H:%M:%S"),
        name = first and first.name or (pre and pre.name),
        npcID = first and first.npcID or (pre and pre.npcID),
        pre = pre,
        first = first,
    }

    table.insert(AggroRangeDB.pullLog, 1, log)
    while #AggroRangeDB.pullLog > MAX_LOGS do
        table.remove(AggroRangeDB.pullLog)
    end

    if AggroRangeDB.debugChat then
        print(string.format(
            "|cff66ccffAggroRange|r pull logged: %s (#%s), pre=%s, first=%s, working=%s yd (raw=%s, offset=%s)",
            log.name or "?",
            tostring(log.npcID or "?"),
            pre and FormatRange(pre.minRange, pre.maxRange) or "none",
            first and FormatRange(first.minRange, first.maxRange) or "none",
            first and FormatNumber(first.aggroRadius) or "?",
            first and FormatNumber(first.rawAggroRadius) or "?",
            first and FormatNumber(first.calibrationOffset) or "?"
        ))
    end
end

local function CreatePanel()
    panel = CreateFrame("Frame", "AggroRangeDiagnosticPanel", UIParent, "BackdropTemplate")
    panel:SetSize(560, 440)
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetClampedToScreen(true)
    panel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = {left = 3, right = 3, top = 3, bottom = 3},
    })
    panel:SetBackdropColor(0.03, 0.03, 0.03, 0.92)
    panel:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)

    local point = AggroRangeDB.panelPoint or defaults.panelPoint
    panel:SetPoint(point[1], _G[point[2]] or UIParent, point[3], point[4], point[5])

    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, relativeTo, rp, x, y = self:GetPoint(1)
        AggroRangeDB.panelPoint = {p, relativeTo and relativeTo:GetName() or "UIParent", rp, x, y}
    end)

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    panel.title:SetPoint("TOPLEFT", 12, -10)
    panel.title:SetText("AggroRange — v" .. VERSION .. " debug")
    SetColor(panel.title, COLORS.title)

    panel.subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.subtitle:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -3)
    panel.subtitle:SetText("Validation view — direct probes, formula inputs, exception source, test progress")
    SetColor(panel.subtitle, COLORS.dim)

    panel.body = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.body:SetPoint("TOPLEFT", 12, -52)
    panel.body:SetPoint("BOTTOMRIGHT", -12, 12)
    panel.body:SetJustifyH("LEFT")
    panel.body:SetJustifyV("TOP")
    panel.body:SetSpacing(1)
end

local function CreatePlateOverlay()
    plateOverlay = CreateFrame("Frame", "AggroRangeTargetPlateOverlay", UIParent)
    plateOverlay:SetSize(100, 28)
    plateOverlay:SetFrameStrata("TOOLTIP")
    plateOverlay:SetFrameLevel(10000)
    plateOverlay:EnableMouse(false)

    plateText = plateOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    plateText:SetPoint("CENTER")
    plateText:SetShadowOffset(1, -1)
    plateText:SetText("+0 yd")
    plateOverlay:Hide()

    -- The current target also gets a persistent target-frame readout.  This is
    -- intentionally independent of the nameplate overlay: when a target's
    -- nameplate becomes visible, the target-frame clearance remains available
    -- for off-camera / peripheral movement until the mob actually engages.
    targetFrameOverlay = CreateFrame("Frame", "AggroRangeTargetFrameOverlay", UIParent)
    targetFrameOverlay:SetSize(88, 22)
    targetFrameOverlay:SetFrameStrata("TOOLTIP")
    targetFrameOverlay:SetFrameLevel(10000)
    targetFrameOverlay:EnableMouse(false)

    targetFrameText = targetFrameOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    targetFrameText:SetPoint("CENTER")
    targetFrameText:SetShadowOffset(1, -1)
    targetFrameText:SetText("+0 yd")
    targetFrameOverlay:Hide()

    -- Mouseover gets its own overlay so inspecting a nearby mob never steals
    -- or reanchors the current-target indicator. It is nameplate-only: unlike
    -- the target unit, a mouseover unit has no persistent unit-frame fallback.
    mouseoverOverlay = CreateFrame("Frame", "AggroRangeMouseoverPlateOverlay", UIParent)
    mouseoverOverlay:SetSize(100, 28)
    mouseoverOverlay:SetFrameStrata("TOOLTIP")
    mouseoverOverlay:SetFrameLevel(10001)
    mouseoverOverlay:EnableMouse(false)

    mouseoverText = mouseoverOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    mouseoverText:SetPoint("CENTER")
    mouseoverText:SetShadowOffset(1, -1)
    mouseoverText:SetText("+0 yd")
    mouseoverOverlay:Hide()
end

local function HidePlateText()
    if plateOverlay then plateOverlay:Hide() end
    currentPlateAnchor = nil
end

local function HideTargetFrameText()
    if targetFrameOverlay then targetFrameOverlay:Hide() end
    currentTargetFrameAnchor = nil
end

local function HideMouseoverText()
    if mouseoverOverlay then mouseoverOverlay:Hide() end
    currentMouseoverAnchor = nil
end

local function GetUnitPlateAnchor(unit)
    if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return nil end
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return nil end
    return plate.UnitFrame or plate
end

local function GetTargetPlateAnchor()
    return GetUnitPlateAnchor("target")
end

local function GetTargetFrameAnchor()
    local targetFrame = _G.TargetFrame
    if not targetFrame or not targetFrame:IsShown() then return nil end
    return targetFrame
end

local function AttachPlateText()
    if not AggroRangeDB.showNameplate or not plateOverlay then
        HidePlateText()
        return false
    end

    -- The target nameplate is now an additional world-space readout rather
    -- than the exclusive target display.  If the plate is off-screen or beyond
    -- Classic's nameplate distance, the persistent target-frame readout still
    -- carries the same clearance value.
    local anchor = GetTargetPlateAnchor()
    if not anchor then
        HidePlateText()
        return false
    end

    if currentPlateAnchor ~= anchor then
        plateOverlay:ClearAllPoints()
        plateText:SetFontObject(GameFontNormalLarge)
        plateOverlay:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
        currentPlateAnchor = anchor
    end
    plateOverlay:Show()
    return true
end

local function AttachTargetFrameText()
    if not AggroRangeDB.showNameplate or not targetFrameOverlay then
        HideTargetFrameText()
        return false
    end

    local anchor = GetTargetFrameAnchor()
    if not anchor then
        HideTargetFrameText()
        return false
    end

    if currentTargetFrameAnchor ~= anchor then
        targetFrameOverlay:ClearAllPoints()
        targetFrameOverlay:SetPoint("LEFT", anchor, "RIGHT", 2, -5)
        currentTargetFrameAnchor = anchor
    end
    targetFrameOverlay:Show()
    return true
end

local function UpdatePlateDisplay(data)
    if not AggroRangeDB.showNameplate or not data.valid then
        HidePlateText()
        return
    end

    -- Once the mob has actually engaged, flash AGGRO briefly on any visible
    -- nameplate, then remove the proximity readout.
    if data.threatEngaged and GetTime() > (aggroDisplayUntil or 0) then
        HidePlateText()
        return
    end

    if not AttachPlateText() then return end
    plateText:SetText(data.plateLabel or "?")
    SetColor(plateText, COLORS[data.state] or COLORS.neutral)
end

local function UpdateTargetFrameDisplay(data)
    if not AggroRangeDB.showNameplate or not data.valid then
        HideTargetFrameText()
        return
    end

    -- Unlike the nameplate readout, this stays present for the whole pre-aggro
    -- approach even when a nameplate is visible.  That makes it useful while
    -- threading past a selected mob that is no longer in the camera view.
    if data.threatEngaged and GetTime() > (aggroDisplayUntil or 0) then
        HideTargetFrameText()
        return
    end

    if not AttachTargetFrameText() then return end
    targetFrameText:SetText(data.plateLabel or "?")
    SetColor(targetFrameText, COLORS[data.state] or COLORS.neutral)
end

local function UpdateMouseoverDisplay(data)
    if not AggroRangeDB.showNameplate or not data or not data.valid or not mouseoverOverlay then
        HideMouseoverText()
        return
    end

    -- If mouseover is also the current target, the ordinary target overlay
    -- already owns this nameplate. Suppress the second label completely.
    if UnitExists("target") and UnitIsUnit("mouseover", "target") then
        HideMouseoverText()
        return
    end

    -- Mouseover is deliberately nameplate-only. If the plate is not visible,
    -- there is nowhere sensible to place a transient hover readout.
    local anchor = GetUnitPlateAnchor("mouseover")
    if not anchor then
        HideMouseoverText()
        return
    end

    if currentMouseoverAnchor ~= anchor then
        mouseoverOverlay:ClearAllPoints()
        mouseoverOverlay:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
        currentMouseoverAnchor = anchor
    end

    mouseoverText:SetText(data.plateLabel or "?")
    SetColor(mouseoverText, COLORS[data.state] or COLORS.neutral)
    mouseoverOverlay:Show()
end

local function BuildUnitData(unit, includeInteractDiagnostics)
    unit = unit or 'target'
    local data = { unit = unit }
    data.valid, data.ignoreReason, data.npcID, data.reaction = GetUnitEligibility(unit)
    if not data.valid then return data end

    data.name = UnitName(unit) or 'Unknown'
    data.guid = UnitGUID(unit)
    data.playerLevel = UnitLevel('player')
    data.targetLevel, data.targetLevelReported, data.classification, data.targetLevelSource = ResolveTargetLevel(data.playerLevel, data.npcID, unit)
    data.creatureType = UnitCreatureType(unit) or '?'

    data.baseDetection, data.detectionSource, data.exceptionValidated, data.exceptionRecord = GetDetectionProfile(data.npcID)
    data.override = data.detectionSource == 'manual' and data.baseDetection or nil
    data.exceptionProvisional = data.detectionSource ~= 'baseline' and data.detectionSource ~= 'manual' and not data.exceptionValidated

    data.mindSoothed, data.mindSootheSpellID, data.mindSootheExpiration = GetMindSootheInfo(unit)
    data.aggroRadius, data.levelDifference, data.rawAggroRadius, data.levelAdjustedRadius = CalculateAggroRadius(data.playerLevel, data.targetLevel, data.baseDetection, data.mindSoothed)
    data.calibrationOffset = AggroRangeDB.calibrationOffset or DEFAULT_CALIBRATION_OFFSET

    local probeStates = PROBE_STATE_BUFFERS[unit] or {}
    data.minRange, data.maxRange, data.directRangeOK, data.directRangeNote, data.itemProbeError, data.probeStates = ProbeUnitRange(unit, probeStates)
    data.rangeSource = data.directRangeOK and 'Direct item probes' or 'Unavailable'
    if includeInteractDiagnostics then
        data.itemProbeSummary = GetItemProbeSummary(data)
        data.interactProbeSummary = GetInteractDiagnostics(unit)
    end

    data.threatEngaged, data.threatStatus = GetThreatEngaged(unit)
    data.state, data.margin, data.plateLabel, data.possibleMarginLow, data.possibleMarginHigh, data.marginUncertainty = DetermineState(data.minRange, data.maxRange, data.aggroRadius, data.threatEngaged)
    if data.exceptionProvisional and data.plateLabel and data.plateLabel ~= 'AGGRO' then
        data.plateLabel = '~' .. data.plateLabel
    end
    return data
end

local function BuildCurrentData()
    -- Interact-distance probes are diagnostic-only. Avoid two extra API calls
    -- every 0.10 s during ordinary play when the debug panel is hidden.
    return BuildUnitData('target', AggroRangeDB and AggroRangeDB.showPanel == true)
end

local function HasRelevantMouseover()
    if not AggroRangeDB.showNameplate then return false end
    if not UnitExists('mouseover') then return false end
    if UnitExists('target') and UnitIsUnit('mouseover', 'target') then return false end
    if not GetUnitPlateAnchor('mouseover') then return false end
    local valid = GetUnitEligibility('mouseover')
    return valid == true
end

local function BuildMouseoverData()
    -- Mouseover is purely a nameplate feature. When plate displays are disabled,
    -- do not spend any time probing a unit whose result cannot be shown.
    if not AggroRangeDB.showNameplate then return INVALID_MOUSEOVER_DATA end
    if not UnitExists('mouseover') or (UnitExists('target') and UnitIsUnit('mouseover', 'target')) then
        return INVALID_MOUSEOVER_DATA
    end
    if not GetUnitPlateAnchor('mouseover') then
        return INVALID_MOUSEOVER_DATA
    end
    return BuildUnitData('mouseover', false)
end

local function GetTestBucket(diff)
    if diff == nil then return nil end
    for _, bucket in ipairs(TEST_BUCKETS) do if diff == bucket then return bucket end end
    return nil
end

local function GetTestCounts()
    local counts = {}
    for _, b in ipairs(TEST_BUCKETS) do counts[b] = 0 end
    for _, row in ipairs(AggroRangeDB.diagnosticLog or {}) do
        if row.eligibleBaselineTest and row.testBucket ~= nil and counts[row.testBucket] ~= nil then
            counts[row.testBucket] = counts[row.testBucket] + 1
        end
    end
    return counts
end

local function FormatTestProgress()
    local counts = GetTestCounts()
    local parts = {}
    for _, b in ipairs(TEST_BUCKETS) do
        parts[#parts + 1] = string.format('Δ%d %d/%d', b, math.min(counts[b] or 0, TEST_PULLS_PER_BUCKET), TEST_PULLS_PER_BUCKET)
    end
    return table.concat(parts, '  ')
end

local function UpdatePanel(data)
    if not panel then return end
    if AggroRangeDB.showPanel then panel:Show() else panel:Hide(); return end

    if not data.valid then
        panel.body:SetText(table.concat({
            'Target: |cff999999No hostile living NPC|r' .. (data.ignoreReason and ('  (' .. tostring(data.ignoreReason) .. ')') or ''),
            '',
            'Base detection: ' .. FormatNumber(AggroRangeDB.baseDetection) .. ' yd',
            'Calibration offset: -' .. FormatNumber(AggroRangeDB.calibrationOffset or DEFAULT_CALIBRATION_OFFSET) .. ' yd',
            'Mind Soothe modifier: -10 yd when active',
            'Active provisional exception candidates: ' .. tostring(AggroRangeActiveExceptionCount or 0) .. ' / research ' .. tostring(AggroRangeExceptionResearchCount or 0),
            '',
            'Baseline test mode: ' .. (AggroRangeDB.testMode and '|cff55ff55ON|r' or 'off'),
            FormatTestProgress(),
        }, '\n'))
        return
    end

    local levelText = data.targetLevel and tostring(data.targetLevel) or 'Unknown'
    if data.targetLevelReported and data.targetLevelReported < 0 then levelText = levelText .. ' (skull)' end
    local deltaText = data.levelDifference and string.format('%+d', data.levelDifference) or '?'
    local threatText = data.threatEngaged and '|cffff4444YES|r' or 'No'
    local sourceText = tostring(data.detectionSource or '?')
    if data.exceptionProvisional then sourceText = sourceText .. ' |cffffd044PROVISIONAL|r' end
    if data.exceptionRecord and data.exceptionValidated then sourceText = sourceText .. ' |cff55ff55VALIDATED|r' end
    local stateColor = data.state == 'safe' and '|cff44ff44' or data.state == 'threshold' and '|cffffd044' or data.state == 'danger' and '|cffff4444' or '|cffcccccc'
    local sootheText = data.mindSoothed and '|cff55ff55ACTIVE (-10 yd)|r' or 'No'

    local marginText = 'Unknown'
    if data.margin ~= nil then
        local sign = data.margin > 0 and '+' or ''
        marginText = sign .. FormatNumber(data.margin) .. ' yd (band uncertainty ±' .. FormatNumber(data.marginUncertainty) .. ')'
    elseif data.possibleMarginLow ~= nil then
        marginText = 'at least +' .. FormatNumber(data.possibleMarginLow) .. ' yd'
    end

    panel.body:SetText(table.concat({
        'Target: |cffffffff' .. data.name .. '|r   NPC: |cffffffff' .. tostring(data.npcID or '?') .. '|r   ' .. tostring(data.classification or '?') .. ' / ' .. tostring(data.creatureType or '?'),
        'Levels: player |cffffffff' .. tostring(data.playerLevel or '?') .. '|r / mob |cffffffff' .. levelText .. '|r   delta |cffffffff' .. deltaText .. '|r   source ' .. tostring(data.targetLevelSource or '?'),
        'Detection: |cffffffff' .. FormatNumber(data.baseDetection) .. ' yd|r   source: ' .. sourceText,
        'Level-adjusted: |cffffffff' .. FormatNumber(data.levelAdjustedRadius) .. '|r   Mind Soothe: ' .. sootheText,
        'Raw after floor/aura: |cffffffff' .. FormatNumber(data.rawAggroRadius) .. ' yd|r   calibration: |cffffffff-' .. FormatNumber(data.calibrationOffset) .. '|r   working: |cffffffff' .. FormatNumber(data.aggroRadius) .. ' yd|r',
        '',
        '|cff66ccffDIRECT RANGE PROBES|r',
        'Measured band: |cffffffff' .. FormatRange(data.minRange, data.maxRange) .. '|r   evidence: ' .. tostring(data.directRangeNote or '?'),
        '5/10/15/20/25/30/35/40: |cffffffff' .. tostring(data.itemProbeSummary or '?') .. '|r',
        'Interact: |cffffffff' .. tostring(data.interactProbeSummary or '?') .. '|r',
        '',
        '|cff66ccffAGGRO OUTPUT|r',
        'Clearance midpoint: |cffffffff' .. marginText .. '|r',
        'State: ' .. stateColor .. string.upper(data.state or '?') .. '|r   engaged: ' .. threatText .. '   indicator: ' .. stateColor .. tostring(data.plateLabel or '?') .. '|r',
        '',
        '|cff66ccffBODY-PULL DIAGNOSTICS|r ' .. (AggroRangeDB.testMode and '|cff55ff55ON|r' or 'off'),
        FormatTestProgress(),
        'Current pull contamination: ' .. (prePullContaminated and ('|cffff5555YES — ' .. tostring(prePullContaminationReason or '?') .. '|r') or 'No'),
    }, '\n'))
end

local function ShouldTrackPullDiagnostics(data)
    return AggroRangeDB.testMode == true or (data and data.exceptionRecord ~= nil)
end

local function ResetTraceForTarget(data)
    traceGUID = data and data.guid or nil
    traceTransitions = {}
    traceLastKey = nil
    prePullContaminated = false
    prePullContaminationReason = nil
end

local function TrackRangeTrace(data)
    if not data.valid or not data.guid then return end
    if traceGUID ~= data.guid then ResetTraceForTarget(data) end
    local key = tostring(data.minRange or 'nil') .. '/' .. tostring(data.maxRange or 'nil')
    if key ~= traceLastKey then
        traceLastKey = key
        traceTransitions[#traceTransitions + 1] = { t = GetTime(), minRange = data.minRange, maxRange = data.maxRange, note = data.directRangeNote }
        while #traceTransitions > 20 do table.remove(traceTransitions, 1) end
    end
end

local function CopyTraceRelative(pullTime)
    local out = {}
    for _, row in ipairs(traceTransitions) do
        out[#out + 1] = { dt = Round1(row.t - pullTime), minRange = row.minRange, maxRange = row.maxRange, note = row.note }
    end
    return out
end

local function GetLocationSnapshot()
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit('player') or nil
    return { zone = GetZoneText and GetZoneText() or nil, subzone = GetSubZoneText and GetSubZoneText() or nil, mapID = mapID }
end

local function PushDiagnosticRecord(pre, first)
    if not AggroRangeDB.testMode then return end
    local ref = first or pre
    if not ref then return end
    local bucket = GetTestBucket(ref.levelDifference)
    local eligible = bucket ~= nil
        and ref.classification == 'normal'
        and ref.detectionSource == 'baseline'
        and not ref.mindSoothed
        and ref.directRangeOK
        and not prePullContaminated

    local row = {
        time = date('%Y-%m-%d %H:%M:%S'),
        character = UnitName('player'),
        realm = GetRealmName and GetRealmName() or nil,
        npcID = ref.npcID, name = ref.name,
        playerLevel = ref.playerLevel, targetLevel = ref.targetLevel, targetLevelReported = ref.targetLevelReported,
        levelDifference = ref.levelDifference, classification = ref.classification, creatureType = ref.creatureType,
        detection = ref.baseDetection, detectionSource = ref.detectionSource,
        rawAggroRadius = ref.rawAggroRadius, workingAggroRadius = ref.aggroRadius, calibrationOffset = ref.calibrationOffset,
        mindSoothed = ref.mindSoothed,
        pre = pre, first = first,
        trace = CopyTraceRelative(GetTime()),
        contaminated = prePullContaminated, contaminationReason = prePullContaminationReason,
        eligibleBaselineTest = eligible, testBucket = bucket,
        location = GetLocationSnapshot(),
    }
    table.insert(AggroRangeDB.diagnosticLog, 1, row)
    while #AggroRangeDB.diagnosticLog > MAX_DIAGNOSTIC_LOGS do table.remove(AggroRangeDB.diagnosticLog) end
    if AggroRangeDB.debugChat then
        print(string.format('|cff66ccffAggroRange|r diagnostic pull: %s Δ%s %s', ref.name or '?', tostring(ref.levelDifference or '?'), eligible and '|cff55ff55QUALIFIES|r' or '|cffffd044recorded but not quota-eligible|r'))
    end
end

local function RecordExceptionObservation(pre, first)
    local ref = first or pre
    if not ref or not ref.npcID or not ref.exceptionCandidate then return end
    local key = ref.npcID
    local obs = AggroRangeDB.exceptionObservations[key] or { count = 0, cleanCount = 0, contaminatedCount = 0 }
    obs.count = (obs.count or 0) + 1
    if prePullContaminated then
        obs.contaminatedCount = (obs.contaminatedCount or 0) + 1
    else
        obs.cleanCount = (obs.cleanCount or 0) + 1
    end
    obs.last = {
        time = date('%Y-%m-%d %H:%M:%S'), pre = pre, first = first,
        contaminated = prePullContaminated, contaminationReason = prePullContaminationReason,
        trace = CopyTraceRelative(GetTime()),
    }
    AggroRangeDB.exceptionObservations[key] = obs
end

local function BackfillExceptionObservations()
    if AggroRangeDB.exceptionObservationSchema == EXCEPTION_OBSERVATION_SCHEMA then return end

    -- v0.9.3 stored exception pulls in diagnosticLog but Snapshot omitted the
    -- marker RecordExceptionObservation expected, leaving this table empty.
    -- Rebuild once from the richer diagnostic records so prior field work is
    -- not lost. New observations are maintained incrementally above.
    if not next(AggroRangeDB.exceptionObservations or {}) then
        AggroRangeDB.exceptionObservations = {}
        local rows = AggroRangeDB.diagnosticLog or {}
        for i = #rows, 1, -1 do
            local row = rows[i]
            local npcID = row and row.npcID
            if npcID and GetBuiltinException(npcID) then
                local obs = AggroRangeDB.exceptionObservations[npcID] or { count = 0, cleanCount = 0, contaminatedCount = 0 }
                obs.count = (obs.count or 0) + 1
                if row.contaminated then
                    obs.contaminatedCount = (obs.contaminatedCount or 0) + 1
                else
                    obs.cleanCount = (obs.cleanCount or 0) + 1
                end
                obs.last = {
                    time = row.time, pre = row.pre, first = row.first,
                    contaminated = row.contaminated, contaminationReason = row.contaminationReason,
                    trace = row.trace, backfilled = true,
                }
                AggroRangeDB.exceptionObservations[npcID] = obs
            end
        end
    end

    AggroRangeDB.exceptionObservationSchema = EXCEPTION_OBSERVATION_SCHEMA
end

local function PreAggroSnapshotNeedsRefresh(data)
    local pre = lastPreAggroSnapshot
    if not pre or lastPreAggroGUID ~= data.guid then return true end

    -- Refresh only when information that could matter to the eventual pull log
    -- changes. This preserves the last useful pre-pull state without allocating
    -- a large Snapshot table ten times per second while the player stands in
    -- the same measured band.
    return pre.minRange ~= data.minRange
        or pre.maxRange ~= data.maxRange
        or pre.aggroRadius ~= data.aggroRadius
        or pre.rawAggroRadius ~= data.rawAggroRadius
        or pre.baseDetection ~= data.baseDetection
        or pre.calibrationOffset ~= data.calibrationOffset
        or pre.mindSoothed ~= data.mindSoothed
        or pre.mindSootheSpellID ~= data.mindSootheSpellID
        or pre.directRangeOK ~= data.directRangeOK
        or pre.directRangeNote ~= data.directRangeNote
        or pre.targetLevel ~= data.targetLevel
        or pre.targetLevelSource ~= data.targetLevelSource
        or pre.detectionSource ~= data.detectionSource
        or pre.exceptionValidated ~= data.exceptionValidated
        or pre.exceptionProvisional ~= data.exceptionProvisional
end

local function UpdateAggroTransition(data)
    if not data.valid then
        previousThreatEngaged = false
        lastPreAggroSnapshot = nil
        lastPreAggroGUID = nil
        if traceGUID ~= nil or #traceTransitions > 0 then ResetTraceForTarget(nil) end
        return
    end

    if ShouldTrackPullDiagnostics(data) then
        TrackRangeTrace(data)
    elseif traceGUID ~= nil or #traceTransitions > 0 then
        -- Ordinary production targets do not need forensic range histories.
        ResetTraceForTarget(nil)
    end

    if not data.threatEngaged then
        if PreAggroSnapshotNeedsRefresh(data) then
            lastPreAggroSnapshot = Snapshot(data)
            lastPreAggroGUID = data.guid
        end
        aggroDisplayUntil = 0
    elseif data.threatEngaged and not previousThreatEngaged then
        aggroDisplayUntil = GetTime() + AGGRO_DISPLAY_SECONDS
        local first = Snapshot(data)
        PushPullLog(lastPreAggroSnapshot, first)
        PushDiagnosticRecord(lastPreAggroSnapshot, first)
        RecordExceptionObservation(lastPreAggroSnapshot, first)
    end

    previousThreatEngaged = data.threatEngaged
end

local function UpdateAll()
    -- The common idle case should be almost free. With no target and no hostile
    -- visible mouseover, there is nothing to range-probe or calculate.
    if not UnitExists('target') and not HasRelevantMouseover() then
        current = INVALID_TARGET_DATA
        UpdateAggroTransition(current)
        UpdatePanel(current)
        HideTargetFrameText()
        HidePlateText()
        HideMouseoverText()
        return
    end

    current = UnitExists('target') and BuildCurrentData() or INVALID_TARGET_DATA
    UpdateAggroTransition(current)
    UpdatePanel(current)

    if AggroRangeDB.showNameplate then
        UpdateTargetFrameDisplay(current)
        UpdatePlateDisplay(current)
        UpdateMouseoverDisplay(BuildMouseoverData())
    else
        HideTargetFrameText()
        HidePlateText()
        HideMouseoverText()
    end
end

local function PrintHelp()
    print("|cff66ccffAggroRange v" .. VERSION .. "|r")
    print("  +12 yd = estimated clearance; -2 yd = inside the modeled boundary; ~ = provisional exception; AGGRO = engaged")
    print("  /ar plate on|off          - toggle target/nameplate/mouseover indicators")
    print("  /ar distance [status|max] - show or set native Nameplate Distance")
    print("  /ar reset                 - reset AggroRange settings")
    print("  /ar advanced              - diagnostic/research commands")
end

local function PrintAdvancedHelp()
    print("|cff66ccffAggroRange v" .. VERSION .. "|r advanced commands:")
    print("  /ar debug [on|off]        - toggle diagnostic panel + pull-log chat")
    print("  /ar show | hide           - show/hide diagnostic panel only")
    print("  /ar probes                - print current raw probe summary")
    print("  /ar logs | clearlogs      - inspect/clear recent pull observations")
    print("  /ar exceptions            - show exception observation summary")
    print("  /ar validate target       - locally validate current built-in exception")
    print("  /ar unvalidate target     - remove local validation mark")
    print("  /ar test on|off|status|reset - diagnostic body-pull test mode")
    print("  /ar base <yards>          - set ordinary base detection (default 18)")
    print("  /ar floor <yards>         - set raw minimum radius floor (default 5)")
    print("  /ar offset <yards>        - set empirical calibration offset (default 5)")
    print("  /ar override <id> <yards|clear> - set/clear an experimental NPC override")
end

local function PrintLogs()
    if #AggroRangeDB.pullLog == 0 then
        print("|cff66ccffAggroRange|r: no pull observations logged yet.")
        return
    end

    print("|cff66ccffAggroRange|r recent pulls:")
    for i = 1, math.min(10, #AggroRangeDB.pullLog) do
        local l = AggroRangeDB.pullLog[i]
        local pre = l.pre and FormatRange(l.pre.minRange, l.pre.maxRange) or "none"
        local first = l.first and FormatRange(l.first.minRange, l.first.maxRange) or "none"
        print(string.format("  %d. %s #%s — pre %s, first %s, working %s yd (raw %s)",
            i, l.name or "?", tostring(l.npcID or "?"), pre, first,
            l.first and FormatNumber(l.first.aggroRadius) or "?",
            l.first and FormatNumber(l.first.rawAggroRadius) or "?"))
    end
end

local function PrintProbes()
    if not current or not current.valid then
        print('|cff66ccffAggroRange|r: target a hostile living NPC first.')
        return
    end
    print('|cff66ccffAggroRange|r direct band: ' .. FormatRange(current.minRange, current.maxRange) .. ' (' .. tostring(current.directRangeNote or '?') .. ')')
    print('|cff66ccffAggroRange|r items: ' .. tostring(GetItemProbeSummary(current)))
    print('|cff66ccffAggroRange|r interact: ' .. tostring(current.interactProbeSummary or GetInteractDiagnostics('target')))
    print('|cff66ccffAggroRange|r detection=' .. FormatNumber(current.baseDetection) .. ' source=' .. tostring(current.detectionSource) .. ' working=' .. FormatNumber(current.aggroRadius) .. ' soothe=' .. tostring(current.mindSoothed))
end

local function PrintTestStatus()
    print('|cff66ccffAggroRange|r diagnostic body-pull mode: ' .. (AggroRangeDB.testMode and 'ON' or 'off'))
    print('  ' .. FormatTestProgress())
    local counts = GetTestCounts()
    local total = 0
    for _, b in ipairs(TEST_BUCKETS) do total = total + math.min(counts[b] or 0, TEST_PULLS_PER_BUCKET) end
    print(string.format('  qualifying pulls: %d / %d', total, #TEST_BUCKETS * TEST_PULLS_PER_BUCKET))
end

local function PrintExceptionStatus()
    local observed, validated = 0, 0
    for npcID, _ in pairs(AggroRangeBuiltinExceptions or {}) do
        local obs = AggroRangeDB.exceptionObservations[npcID] or AggroRangeDB.exceptionObservations[tostring(npcID)]
        if obs and (obs.count or 0) > 0 then observed = observed + 1 end
        if IsExceptionValidated(npcID) then validated = validated + 1 end
    end
    print(string.format('|cff66ccffAggroRange|r exception research: %d candidates; active body-pull candidates: %d; scripted/ambiguous excluded: %d; observed: %d; validated: %d',
        AggroRangeExceptionResearchCount or 0, AggroRangeActiveExceptionCount or 0, AggroRangeExcludedExceptionCount or 0, observed, validated))
    if current and current.valid and current.exceptionRecord then
        local obs = AggroRangeDB.exceptionObservations[current.npcID] or AggroRangeDB.exceptionObservations[tostring(current.npcID)] or {}
        print(string.format('  target #%s %s: detection %s yd, policy=%s, pulls=%d (clean %d / contaminated %d), validated=%s',
            tostring(current.npcID), tostring(current.name), FormatNumber(current.baseDetection),
            tostring(current.exceptionRecord.policy or '?'), obs.count or 0, obs.cleanCount or 0, obs.contaminatedCount or 0, tostring(current.exceptionValidated)))
    end
end

local function HandleSlash(msg)
    local command, rest = msg:match("^(%S*)%s*(.-)$")
    command = string.lower(command or "")

    if command == "" then
        PrintHelp()

    elseif command == "help" then
        if string.lower(rest or "") == "advanced" then PrintAdvancedHelp() else PrintHelp() end

    elseif command == "advanced" then
        PrintAdvancedHelp()

    elseif command == "base" then
        local n = tonumber(rest)
        if not n or n < 0 or n > 100 then
            print("|cff66ccffAggroRange|r: base must be a number from 0 to 100.")
            return
        end
        AggroRangeDB.baseDetection = n
        print("|cff66ccffAggroRange|r: base detection set to " .. FormatNumber(n) .. " yd.")
        UpdateAll()

    elseif command == "floor" then
        local n = tonumber(rest)
        if not n or n < 0 or n > 50 then
            print("|cff66ccffAggroRange|r: floor must be a number from 0 to 50.")
            return
        end
        AggroRangeDB.minRadius = n
        print("|cff66ccffAggroRange|r: minimum radius floor set to " .. FormatNumber(n) .. " yd.")
        UpdateAll()

    elseif command == "offset" then
        local n = tonumber(rest)
        if not n or n < -20 or n > 20 then
            print("|cff66ccffAggroRange|r: offset must be a number from -20 to 20.")
            return
        end
        AggroRangeDB.calibrationOffset = n
        print("|cff66ccffAggroRange|r: calibration offset set to " .. FormatNumber(n) .. " yd (subtracted from raw estimate).")
        UpdateAll()

    elseif command == "debug" then
        local value = string.lower(rest or "")
        local enable
        if value == "on" then enable = true
        elseif value == "off" then enable = false
        elseif value == "" then enable = not AggroRangeDB.showPanel
        else
            print("|cff66ccffAggroRange|r: use /ar debug, /ar debug on, or /ar debug off")
            return
        end
        AggroRangeDB.showPanel = enable
        AggroRangeDB.debugChat = enable
        if enable then panel:Show() else panel:Hide() end
        UpdateAll()
        print("|cff66ccffAggroRange|r: debug mode " .. (enable and "ON" or "OFF") .. ".")

    elseif command == "show" then
        AggroRangeDB.showPanel = true
        panel:Show()
        UpdateAll()

    elseif command == "hide" then
        AggroRangeDB.showPanel = false
        panel:Hide()

    elseif command == "plate" then
        local value = string.lower(rest or "")
        if value == "on" then
            AggroRangeDB.showNameplate = true
        elseif value == "off" then
            AggroRangeDB.showNameplate = false
            HidePlateText()
            HideTargetFrameText()
            HideMouseoverText()
        else
            print("|cff66ccffAggroRange|r: use /ar plate on or /ar plate off")
            return
        end
        UpdateAll()

    elseif command == "distance" then
        local value = string.lower(rest or "")
        if value == "" or value == "status" then
            local currentDistance = GetNameplateDistance()
            if currentDistance then
                print(string.format('|cff66ccffAggroRange|r: Nameplate Distance is %s yd. Maximum/recommended for mouseover is %d yd.', FormatNumber(currentDistance), RECOMMENDED_NAMEPLATE_DISTANCE))
            else
                print('|cff66ccffAggroRange|r: could not read the native Nameplate Distance setting.')
            end
        elseif value == "max" then
            local ok = SetNameplateDistance(RECOMMENDED_NAMEPLATE_DISTANCE)
            local currentDistance = GetNameplateDistance()
            if ok and currentDistance and currentDistance + 0.01 >= RECOMMENDED_NAMEPLATE_DISTANCE then
                print(string.format('|cff66ccffAggroRange|r: Nameplate Distance set to maximum (%d yd).', RECOMMENDED_NAMEPLATE_DISTANCE))
            else
                print('|cff66ccffAggroRange|r: the game did not accept the nameplate-distance change. Set it manually under Options > Nameplates.')
            end
            UpdateAll()
        else
            print('|cff66ccffAggroRange|r: use /ar distance, /ar distance status, or /ar distance max')
        end

    elseif command == "override" then
        local idText, valueText = rest:match("^(%d+)%s+(%S+)$")
        local npcID = tonumber(idText)
        if not npcID then
            print("|cff66ccffAggroRange|r: use /ar override <npcID> <yards|clear>")
            return
        end
        if valueText and string.lower(valueText) == "clear" then
            AggroRangeDB.overrides[npcID] = nil
            AggroRangeDB.overrides[tostring(npcID)] = nil
            print("|cff66ccffAggroRange|r: cleared override for NPC " .. npcID .. ".")
        else
            local n = tonumber(valueText)
            if not n or n < 0 or n > 100 then
                print("|cff66ccffAggroRange|r: override must be 0–100 yards, or 'clear'.")
                return
            end
            AggroRangeDB.overrides[npcID] = n
            print("|cff66ccffAggroRange|r: NPC " .. npcID .. " override set to " .. FormatNumber(n) .. " yd.")
        end
        UpdateAll()

    elseif command == "test" then
        local value = string.lower(rest or '')
        if value == 'on' then
            AggroRangeDB.testMode = true
            print('|cff66ccffAggroRange|r: diagnostic body-pull mode ON. Body-pull only; no Mind Soothe or attacks.')
            PrintTestStatus()
        elseif value == 'off' then
            AggroRangeDB.testMode = false
            print('|cff66ccffAggroRange|r: diagnostic body-pull mode OFF.')
        elseif value == 'status' or value == '' then
            PrintTestStatus()
        elseif value == 'reset' then
            wipe(AggroRangeDB.diagnosticLog)
            print('|cff66ccffAggroRange|r: diagnostic body-pull log cleared.')
            PrintTestStatus()
        else
            print('|cff66ccffAggroRange|r: use /ar test on|off|status|reset')
        end

    elseif command == 'exceptions' then
        PrintExceptionStatus()

    elseif command == 'validate' or command == 'unvalidate' then
        if string.lower(rest or '') ~= 'target' or not current or not current.valid or not current.exceptionRecord then
            print('|cff66ccffAggroRange|r: target a built-in provisional exception and use /ar ' .. command .. ' target')
            return
        end
        if command == 'validate' then
            AggroRangeDB.validatedExceptions[current.npcID] = true
            print('|cff66ccffAggroRange|r: marked ' .. current.name .. ' #' .. current.npcID .. ' as live-validated.')
        else
            AggroRangeDB.validatedExceptions[current.npcID] = nil
            print('|cff66ccffAggroRange|r: removed validation mark for ' .. current.name .. ' #' .. current.npcID .. '.')
        end
        UpdateAll()

    elseif command == "probes" then
        UpdateAll()
        PrintProbes()

    elseif command == "logs" then
        PrintLogs()

    elseif command == "clearlogs" then
        wipe(AggroRangeDB.pullLog)
        print("|cff66ccffAggroRange|r: pull observations cleared.")

    elseif command == "reset" then
        AggroRangeDB = {}
        CopyDefaults(AggroRangeDB, defaults)
        panel:ClearAllPoints()
        local p = AggroRangeDB.panelPoint
        panel:SetPoint(p[1], _G[p[2]] or UIParent, p[3], p[4], p[5])
        print("|cff66ccffAggroRange|r: settings reset.")
        UpdateAll()

    else
        PrintHelp()
    end
end

local DIRECT_HOSTILE_SUBEVENTS = {
    SWING_DAMAGE = true, SWING_MISSED = true, RANGE_DAMAGE = true, RANGE_MISSED = true,
    SPELL_DAMAGE = true, SPELL_MISSED = true, SPELL_PERIODIC_DAMAGE = true,
    SPELL_AURA_APPLIED = true, SPELL_AURA_REFRESH = true,
}

local CROSS_TARGET_HOSTILE_SUBEVENTS = {
    SWING_DAMAGE = true, SWING_MISSED = true, RANGE_DAMAGE = true, RANGE_MISSED = true,
    SPELL_DAMAGE = true, SPELL_MISSED = true,
}

local function MarkPrePullContamination(subevent, spellID, otherTarget)
    prePullContaminated = true
    local suffix = spellID and (' spell ' .. tostring(spellID)) or ''
    if otherTarget then
        prePullContaminationReason = 'hostile action vs another unit: ' .. tostring(subevent) .. suffix
    else
        prePullContaminationReason = tostring(subevent) .. suffix
    end
end

local function RequestProbeItemData()
    if not C_Item or not C_Item.RequestLoadItemDataByID then return end
    for _, probe in ipairs(ITEM_PROBES) do
        pcall(C_Item.RequestLoadItemDataByID, probe[2])
    end
end

AR:RegisterEvent("ADDON_LOADED")
AR:RegisterEvent("PLAYER_TARGET_CHANGED")
AR:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
AR:RegisterEvent("NAME_PLATE_UNIT_ADDED")
AR:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
AR:RegisterEvent("UNIT_LEVEL")
AR:RegisterEvent("UNIT_THREAT_LIST_UPDATE")
AR:RegisterEvent("UNIT_THREAT_SITUATION_UPDATE")
AR:RegisterEvent("PLAYER_LEVEL_UP")
AR:RegisterEvent("SPELLS_CHANGED")
AR:RegisterEvent("UNIT_AURA")
AR:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

AR:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end

        AggroRangeDB = AggroRangeDB or {}
        CopyDefaults(AggroRangeDB, defaults)
        BackfillExceptionObservations()

        -- The 30-pull live campaign locked the ordinary empirical calibration
        -- at -5 yd. Migrate only the old shipped default (-3); preserve any
        -- deliberate custom offset the user may already have chosen.
        if not AggroRangeDB.baselineCalibrationV1Locked then
            if AggroRangeDB.calibrationOffset == 3 then
                AggroRangeDB.calibrationOffset = DEFAULT_CALIBRATION_OFFSET
            end
            AggroRangeDB.baselineCalibrationV1Locked = true
        end

        -- v0.9 transitions the addon from calibration-first presentation to
        -- normal-play presentation. Hide the large diagnostic panel and chat
        -- pull spam once on upgrade; /ar debug restores both instantly.
        if not AggroRangeDB.polishMigrationV08 then
            AggroRangeDB.showPanel = false
            AggroRangeDB.debugChat = false
            AggroRangeDB.polishMigrationV08 = true
        end

        CreatePanel()
        CreatePlateOverlay()
        RequestProbeItemData()

        SLASH_AGGRORANGE1 = "/aggrorange"
        SLASH_AGGRORANGE2 = "/ar"
        SlashCmdList.AGGRORANGE = HandleSlash

        -- Keep normal startup quiet. The one-time Nameplate Distance hint is
        -- the only automatic chat message when it is actually actionable.
        MaybePrintNameplateDistanceHint()

        UpdateAll()

    elseif event == "PLAYER_TARGET_CHANGED" then
        previousThreatEngaged = false
        lastPreAggroSnapshot = nil
        lastPreAggroGUID = nil
        aggroDisplayUntil = 0
        ResetTraceForTarget(nil)
        C_Timer.After(0, function() UpdateAll() end)

    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        C_Timer.After(0, function() UpdateAll() end)

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        if arg1 and (UnitIsUnit(arg1, "target") or UnitIsUnit(arg1, "mouseover")) then
            C_Timer.After(0, function() UpdateAll() end)
        end

    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        C_Timer.After(0, function() UpdateAll() end)

    elseif event == "UNIT_LEVEL" then
        if arg1 == "target" or arg1 == "mouseover" or arg1 == "player" then UpdateAll() end

    elseif event == 'COMBAT_LOG_EVENT_UNFILTERED' then
        -- Contamination tracking is research/diagnostic work. Ordinary baseline
        -- gameplay does not need to unpack every combat-log event in the area.
        if not current or not current.valid or current.threatEngaged or not ShouldTrackPullDiagnostics(current) then return end

        local _, subevent, _, sourceGUID, _, _, _, destGUID, _, _, _, eventArg12 = CombatLogGetCurrentEventInfo()
        local spellID = nil
        if subevent and (string.sub(subevent, 1, 6) == 'SPELL_' or string.sub(subevent, 1, 6) == 'RANGE_') then
            spellID = eventArg12
        end

        local playerGUID = UnitGUID('player')
        local petGUID = UnitGUID('pet')
        local fromPlayerOrPet = sourceGUID == playerGUID or (petGUID and sourceGUID == petGUID)
        if fromPlayerOrPet and destGUID and not (spellID and MIND_SOOTHE_IDS[spellID]) then
            if current.guid and destGUID == current.guid and DIRECT_HOSTILE_SUBEVENTS[subevent] then
                MarkPrePullContamination(subevent, spellID, false)
            elseif current.guid and destGUID ~= current.guid and CROSS_TARGET_HOSTILE_SUBEVENTS[subevent] then
                -- This catches the common social-pull failure mode: the test
                -- mob is selected, but the player/pet attacks a neighbour and
                -- the selected mob joins. Periodic ticks are deliberately not
                -- used cross-target to avoid flagging stale DoTs too readily.
                MarkPrePullContamination(subevent, spellID, true)
            end
        end

    elseif event == 'UNIT_AURA' then
        if arg1 == 'target' or arg1 == 'mouseover' then UpdateAll() end

    elseif event == "SPELLS_CHANGED" then
        C_Timer.After(0.6, function() UpdateAll() end)

    else
        UpdateAll()
    end
end)

AR:SetScript("OnUpdate", function(self, elapsed)
    elapsedSinceUpdate = elapsedSinceUpdate + elapsed
    if elapsedSinceUpdate < UPDATE_INTERVAL then return end
    elapsedSinceUpdate = 0
    if AggroRangeDB then UpdateAll() end
end)
