--------------------------------------------------------------------------------
-- BAR: Battle Rhythm
-- Coaching Widget (Public Release)
-- Author: JoozBrorg
--------------------------------------------------------------------------------

function widget:GetInfo()
    return {
        name      = "BAR: Battle Rhythm",
        desc      = "Coaching Widget (Public Release)",
        author    = "JoozBrorg",
        date      = "2025",
        license   = "GPLv2",
        layer     = 0,
        enabled   = true
    }
end

--------------------------------------------------------------------------------
-- STATE / UI
--------------------------------------------------------------------------------

local fontSize = 14
-- UI options (Settings > Custom)
local uiScale = 1.0
local anchorX = 0.5
local anchorY = 0.86

local showPhaseLine    = true
local showReadiness    = true
local showStatusLine   = true
local showMilestones   = true
local showTodo         = true
local showFocusOptions = true


local ecoLabel = "Initialising…"
local rhythmColor = {0.8, 0.85, 0.9, 1}

local phaseLabel = "—"
local phaseColor = {0.9, 0.9, 0.9, 1}
local currentPhaseKey = "opening"

-- Readiness / lens
local readinessText = ""
local readinessWhyText = ""
local readinessColor = {0.85, 0.9, 1, 1}
local readinessWhyColor = {0.8, 0.85, 1, 1}

local lastT2Score = 0
local lastT3Score = 0

local lensText = ""
local lensColor = {0.85, 0.9, 1, 1}
-- Status line (explains context / why suggestions)
local statusText = ""
local statusColor = {0.85, 0.9, 1, 1}

-- Anti-flicker smoothing (Step 3)
local SMOOTH_HOLD_SEC = 1.6
local smooth = { applied={}, appliedColor={}, cand={}, candColor={}, since={} }

local function SmoothTextColor(key, newText, newColor, nowSec, holdSec, force)
    holdSec = holdSec or SMOOTH_HOLD_SEC
    local a = smooth.applied[key]
    if a == nil then
        smooth.applied[key] = newText or ""
        smooth.appliedColor[key] = newColor
        smooth.cand[key] = nil
        smooth.since[key] = nil
        return smooth.applied[key], smooth.appliedColor[key]
    end

    newText = newText or ""
    if force or newText == a then
        if force and newText ~= a then
            smooth.applied[key] = newText
            smooth.appliedColor[key] = newColor
        end
        smooth.cand[key] = nil
        smooth.since[key] = nil
        return smooth.applied[key], smooth.appliedColor[key]
    end

    -- New candidate
    if smooth.cand[key] ~= newText then
        smooth.cand[key] = newText
        smooth.candColor[key] = newColor
        smooth.since[key] = nowSec
        return smooth.applied[key], smooth.appliedColor[key]
    end

    -- Candidate has persisted long enough
    if (nowSec - (smooth.since[key] or nowSec)) >= holdSec then
        smooth.applied[key] = smooth.cand[key]
        smooth.appliedColor[key] = smooth.candColor[key]
        smooth.cand[key] = nil
        smooth.since[key] = nil
    end

    return smooth.applied[key], smooth.appliedColor[key]
end

local function IsUrgentStatus(text)
    text = (text or ""):lower()
    return text:find("crash") or text:find("blocked") or text:find("project")
end


-- Per-resource arrow + color
local eArrow, mArrow = "→", "→"
local eArrowColor = {1,1,1,1}
local mArrowColor = {1,1,1,1}

local myTeamID = Spring.GetMyTeamID()

--------------------------------------------------------------------------------
-- ECONOMY (raw + smoothed)
--------------------------------------------------------------------------------

local eCur,eMax,eInc,eExp = 0,0,0,0
local mCur,mMax,mInc,mExp = 0,0,0,0
local ePct,mPct = 0,0

local eNetRaw, mNetRaw = 0,0
local eNetEMA, mNetEMA = 0,0
local EMA_ALPHA_BASE = 0.25

--------------------------------------------------------------------------------
-- COUNTS / FLAGS
--------------------------------------------------------------------------------

local windCount = 0
local constructorCount = 0
local constructionTurretCount = 0
local buildPowerCount = 0

-- converters detected by stats
local converterCount = 0
local t1ConverterCount = 0
local t2ConverterCount = 0
local t3ConverterCount = 0

local mexCount = 0
local mexUpgradedCount = 0
local t2BuilderCount = 0

local radarCount = 0
local reactorCount = 0
local afusCount = 0

local factoryCount = 0
local t1FactoryCount = 0
local t2FactoryCount = 0
local t3FactoryCount = 0

local hasT1Factory = false
local hasT2Factory = false
local hasT3Factory = false
local buildingT2Factory = false
local seenT2Factory = false
local t2FinishedTime = -999

-- intent/project flags
local bigProjectBuilding = false
local bigSpendBuilding = false
local anyFactoryBuilding = false

-- idle factories
local factoryIdleSince = {}    -- [unitID] = time when became idle
local idleFactoryCount = 0

-- sustained metal crash detection (fixes “false crash” when bank is huge)
local mCrashTicks = 0

--------------------------------------------------------------------------------
-- LISTS
--------------------------------------------------------------------------------

local milestones = {}
local todo = {}
local focus = {}

local function Clear(t)
    for i = #t, 1, -1 do t[i] = nil end
end

local function Add(t, text, color, status)
    t[#t+1] = { text = text, color = color, status = status }
end

local function SetPhase(key, label)
    currentPhaseKey = key
    phaseLabel = label
end

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function clamp(x, a, b)
    if x < a then return a end
    if x > b then return b end
    return x
end

local function IsTech2(ud)
    local t = ud.customParams and ud.customParams.techlevel
    return t == "2" or t == 2
end

local function IsTech3(ud)
    local t = ud.customParams and ud.customParams.techlevel
    return t == "3" or t == 3
end

local function IsWind(ud)
    if ud.windGenerator and ud.windGenerator > 0 then return true end
    return ud.name and ud.name:lower():find("wind")
end

-- Keep AFUS name check (usually consistent), but we also count AFUS via high energy output below.
local function IsAFUSName(ud)
    return ud.name and ud.name:lower():find("afus")
end

local function IsUnitComplete(uid)
    local _, _, _, _, buildProgress = Spring.GetUnitHealth(uid)
    if buildProgress == nil then
        return not Spring.GetUnitIsBeingBuilt(uid)
    end
    return buildProgress >= 0.999
end

-- Radar building ONLY
local function IsRadarUnit(ud)
    if not ud then return false end
    if (ud.radarRadius and ud.radarRadius > 0) then return true end
    if (ud.radarDistance and ud.radarDistance > 0) then return true end
    if ud.name then
        local n = ud.name:lower()
        if n:find("radar") then return true end
        if n:find("armrad") or n:find("corrad") then return true end
    end
    return false
end

-- Converter detection by actual conversion stats (energy upkeep -> metal make)
local function IsConverterBuilding(ud)
    if not ud or not ud.isBuilding then return false end
    local em = ud.energyUpkeep or 0
    local mm = ud.metalMake or 0
    return (em > 0.01) and (mm > 0.0001)
end

local function ConverterTier(ud)
    if IsTech3(ud) then return 3 end
    if IsTech2(ud) then return 2 end
    return 1
end

local function PhaseTimingColor(phaseKey, gameTimeSec)
    local targets = {
        opening  = 90,   -- 1:30
        t1Bridge = 210,  -- 3:30
        tech     = 300,  -- 5:00
        t2       = 480,  -- 8:00
        t3       = 660,  -- 11:00
        endgame  = nil,
    }

    local tEnd = targets[phaseKey]
    if not tEnd then return {0.9,0.9,0.9,1} end

    local delta = gameTimeSec - tEnd
    if delta <= 0 then return {0.6,1,0.6,1} end
    if delta <= 60 then return {1,0.95,0.45,1} end
    if delta <= 120 then return {1,0.75,0.35,1} end
    return {1,0.35,0.35,1}
end

--------------------------------------------------------------------------------
-- ECON UPDATE
--------------------------------------------------------------------------------

local function UpdateEconomy(projectActive)
    local alpha = EMA_ALPHA_BASE
    if projectActive then alpha = 0.40 end -- faster response during big spends

    -- In replays/spectating, GetTeamResources can return nil when swapping observed teams.
    eCur,eMax,eInc,eExp = Spring.GetTeamResources(myTeamID,"energy")
    if eCur == nil then
        eCur,eMax,eInc,eExp = 0,1,0,0
    end
    mCur,mMax,mInc,mExp = Spring.GetTeamResources(myTeamID,"metal")
    if mCur == nil then
        mCur,mMax,mInc,mExp = 0,1,0,0
    end

    ePct = (eMax>0) and eCur/eMax or 0
    mPct = (mMax>0) and mCur/mMax or 0

    eNetRaw = eInc - eExp
    mNetRaw = mInc - mExp

    eNetEMA = eNetEMA + alpha * (eNetRaw - eNetEMA)
    mNetEMA = mNetEMA + alpha * (mNetRaw - mNetEMA)
end

--------------------------------------------------------------------------------
-- FACTORY IDLE DETECTION
--------------------------------------------------------------------------------

local function FactoryIsActive(uid)
    -- 1) Actively constructing a unit right now
    local buildTarget = Spring.GetUnitIsBuilding(uid)
    if buildTarget then
        return true
    end

    -- 2) A production queue exists (BAR factories use negative unitDefIDs in command queue)
    local cmds = Spring.GetCommandQueue(uid, 20)
    if cmds and #cmds > 0 then
        for i = 1, #cmds do
            local id = cmds[i].id
            -- negative IDs are build/unit orders
            if id and id < 0 then
                return true
            end
        end
    end

    -- 3) Fallback: engine-supported build queue API
    if Spring.GetFullBuildQueue then
        local q = Spring.GetFullBuildQueue(uid)
        if q and next(q) ~= nil then
            return true
        end
    end

    return false
end

--------------------------------------------------------------------------------
-- UNIT SCAN
--------------------------------------------------------------------------------

local function UpdateUnits()
    windCount,constructorCount,constructionTurretCount = 0,0,0
    converterCount,t1ConverterCount,t2ConverterCount,t3ConverterCount = 0,0,0,0
    mexCount,mexUpgradedCount,t2BuilderCount = 0,0,0
    radarCount,reactorCount,afusCount = 0,0,0
    factoryCount,t1FactoryCount,t2FactoryCount,t3FactoryCount = 0,0,0,0

    hasT1Factory,hasT2Factory,hasT3Factory = false,false,false
    buildingT2Factory = false

    bigProjectBuilding = false
    bigSpendBuilding = false
    anyFactoryBuilding = false

    idleFactoryCount = 0
    local now = Spring.GetGameSeconds()

    for _,uid in ipairs(Spring.GetTeamUnits(myTeamID)) do
        local ud = UnitDefs[Spring.GetUnitDefID(uid)]
        if ud then
            local complete = IsUnitComplete(uid)
            local beingBuilt = not complete

            -- Factories
            if ud.isFactory then
                factoryCount = factoryCount + 1
                if beingBuilt then anyFactoryBuilding = true end

                if IsTech3(ud) then
                    t3FactoryCount = t3FactoryCount + 1
                    if complete then hasT3Factory = true end
                    if beingBuilt then bigProjectBuilding = true end
                elseif IsTech2(ud) then
                    t2FactoryCount = t2FactoryCount + 1
                    if beingBuilt then
                        buildingT2Factory = true
                        bigProjectBuilding = true
                    else
                        hasT2Factory = true
                        if not seenT2Factory then
                            seenT2Factory = true
                            t2FinishedTime = now
                        end
                    end
                else
                    t1FactoryCount = t1FactoryCount + 1
                    hasT1Factory = true
                end

                if complete then
                    local active = FactoryIsActive(uid)
                    if active then
                        factoryIdleSince[uid] = nil
                    else
                        if not factoryIdleSince[uid] then factoryIdleSince[uid] = now end
                        if (now - factoryIdleSince[uid]) > 10 then
                            idleFactoryCount = idleFactoryCount + 1
                        end
                    end
                end
            end

            -- Builders
            if ud.isBuilder and not ud.isFactory then
                if ud.isBuilding then
                    constructionTurretCount = constructionTurretCount + 1
                else
                    constructorCount = constructorCount + 1
                end
                if IsTech2(ud) then
                    t2BuilderCount = t2BuilderCount + 1
                end
            end

            -- Wind
            if IsWind(ud) then windCount = windCount + 1 end

            -- Mex
            if ud.extractsMetal and ud.extractsMetal > 0 then
                mexCount = mexCount + 1
                if IsTech2(ud) then mexUpgradedCount = mexUpgradedCount + 1 end
            end

            -- Radar building ONLY
            if complete and ud.isBuilding and IsRadarUnit(ud) then
                radarCount = radarCount + 1
            end

            -- Converters by stats
            if complete and IsConverterBuilding(ud) then
                converterCount = converterCount + 1
                local tier = ConverterTier(ud)
                if tier == 1 then t1ConverterCount = t1ConverterCount + 1
                elseif tier == 2 then t2ConverterCount = t2ConverterCount + 1
                else t3ConverterCount = t3ConverterCount + 1 end
            end

            -- POWER SPINE DETECTION (FIX)
            -- Instead of name matching (armfus/corfus/etc), detect by net energy production.
            -- Fusion reactors and AFUS will always produce huge sustained energy.
            if complete and ud.isBuilding then
                local eProd = (ud.energyMake or 0) - (ud.energyUpkeep or 0)

                -- Fusion-class spine
                if eProd >= 250 then
                    reactorCount = reactorCount + 1
                    -- AFUS-class (very high output)
                    if eProd >= 650 or IsAFUSName(ud) then
                        afusCount = afusCount + 1
                    end
                end
            end

            -- Project flags: any large metal-cost building being built
            if beingBuilt and ud.isBuilding then
                local cost = ud.metalCost or 0
                if cost >= 600 then
                    bigSpendBuilding = true
                end
            end

            -- Tech/build “project” (if fusion/AFUS itself is being built, it’s a project)
            if beingBuilt and ud.isBuilding then
                local eProd = (ud.energyMake or 0) - (ud.energyUpkeep or 0)
                if eProd >= 250 then
                    bigProjectBuilding = true
                end
            end
        end
    end

    buildPowerCount = constructorCount + constructionTurretCount
end

--------------------------------------------------------------------------------
-- PHASE LOGIC
--------------------------------------------------------------------------------

local function UpdatePhase(t)
    if factoryCount == 0 then
        SetPhase("opening","Opening — Establish production (0:00–1:30)")
        return
    end

    if (not hasT2Factory) and (not buildingT2Factory) then
        SetPhase("t1Bridge","T1 Bridge — Stabilise & expand (1:30–3:30)")
        return
    end

    if buildingT2Factory or (seenT2Factory and t < t2FinishedTime + 20) then
        SetPhase("tech","Tech Window — Secure T2 (~3:30–5:00)")
        return
    end

    if hasT2Factory and not hasT3Factory then
        if (reactorCount > 0 or afusCount > 0) then
            SetPhase("t3","T3 Transition — Fusion/AFUS online (8:00–11:00)")
        else
            SetPhase("t2","T2 Spike — Upgrade mex & convert eco (5:00–8:00)")
        end
        return
    end

    if hasT3Factory then
        SetPhase("endgame","Endgame — Convert eco into power")
        return
    end
end

--------------------------------------------------------------------------------
-- RHYTHM ARROWS (smoothed + intent-aware)
--------------------------------------------------------------------------------

local function ArrowFrom(netEMA, pct, intentSpend)
    local upT = 3
    local flatT = -2
    if intentSpend then flatT = -8 end

    if netEMA > upT then return "↑","good" end
    if netEMA > flatT then return "→","ok" end
    -- If buffers are healthy, don’t scare the player with a ↓ just because they are spending.
    if pct > 0.55 and netEMA > -20 then return "→","ok" end
    if pct > 0.35 and netEMA > -10 then return "→","ok" end
    if pct > 0.15 then
        return intentSpend and "↘" or "↓", intentSpend and "ok" or "warn"
    end
    return "↓↓","danger"
end

local function ColorForState(state)
    if state == "good" then return {0.7,1,0.7,1} end
    if state == "ok" then return {0.9,0.9,0.9,1} end
    if state == "warn" then return {1,0.8,0.4,1} end
    return {1,0.35,0.35,1}
end

local function UpdateRhythm(projectActive)
    local intentSpend = projectActive and (ePct > 0.35)
    local conversionLikely = (converterCount > 0) and (mNetEMA > 0) and (eNetEMA < 0) and (ePct > 0.2)

    local lateGameEco = (hasT3Factory or mInc > 25 or eInc > 6000 or mCur > 2000 or eCur > 15000)

    local eA, eState = ArrowFrom(eNetEMA, ePct, intentSpend)
    local mA, mState = ArrowFrom(mNetEMA, mPct, false)

    eArrow, mArrow = eA, mA
    eArrowColor = ColorForState(eState)
    mArrowColor = ColorForState(mState)

    local label = "Stable Eco"
    local crashing = (eState=="danger") or (mState=="danger")
    local tight = (eState=="warn") or (mState=="warn")

    -- If we're late-game (very high income/banks), avoid scary language for normal project spend.
    if crashing and lateGameEco and (ePct > 0.20 or eCur > 3000) and (mCur > 300 or mPct > 0.12) then
        label = "Heavy Spend — Watch Buffers"
        crashing = false
        tight = true
    end

    if crashing then
        label = "Crashing Eco"
    elseif conversionLikely and tight then
        label = "Converting — Watch Energy"
    elseif intentSpend and tight then
        label = "Project Spend — Hold Steady"
    elseif tight then
        label = "Leaning Tight Eco"
    end

    ecoLabel = label
    rhythmColor = crashing and {1,0.3,0.3,1}
              or tight and {1,0.75,0.35,1}
              or {0.6,1,0.6,1}
end

--------------------------------------------------------------------------------
-- HYBRID BUFFER MODEL (percent OR absolute) + READINESS + WHY
--------------------------------------------------------------------------------

local function ReadinessLabelAndColor(score)
    if score >= 75 then return "Safe window", {0.7,1,0.7,1} end
    if score >= 55 then return "Almost", {1,0.95,0.45,1} end
    return "Prep", {1,0.75,0.35,1}
end

local function WhyFromContrib(contrib, penaltyText, tag)
    if penaltyText and penaltyText ~= "" then
        return "Why: " .. penaltyText
    end

    local lowestKey = "eBuf"
    local lowestVal = contrib.eBuf

    local function chk(k, v)
        if v < lowestVal then lowestVal = v; lowestKey = k end
    end

    chk("mBuf", contrib.mBuf)
    chk("eTrend", contrib.eTrend)
    chk("mTrend", contrib.mTrend)

    if lowestKey == "eBuf" then
        return ("Why: Energy buffer low (%s)"):format(tag or "buffer")
    elseif lowestKey == "mBuf" then
        return ("Why: Metal buffer low (%s)"):format(tag or "buffer")
    elseif lowestKey == "eTrend" then
        return ("Why: Energy trend negative (%.1f/s)"):format(eNetEMA)
    else
        return ("Why: Metal trend negative (%.1f/s)"):format(mNetEMA)
    end
end

-- Converts percent+raw into a 0..1 buffer score, and returns a helpful tag string
local function HybridBufScore(pct, cur, pctFloor, pctSpan, rawFloor, rawSpan)
    local pScore = clamp((pct - pctFloor) / pctSpan, 0, 1)
    local rScore = clamp((cur - rawFloor) / rawSpan, 0, 1)
    local score = (pScore > rScore) and pScore or rScore

    local tag
    local pctTxt = ("%d%%"):format(math.floor(pct*100 + 0.5))
    local rawTxt = ("%d"):format(math.floor(cur + 0.5))

    if rScore > pScore then
        tag = ("raw %s (storage high)"):format(rawTxt)
    else
        tag = ("pct %s"):format(pctTxt)
    end

    return score, tag
end

-- Metal-aware weights (T2): Ebuf 0.30 / Mbuf 0.30 / Etrend 0.20 / Mtrend 0.20
local function ReadinessForT2(projectActive)
    local eBuf, eTag = HybridBufScore(ePct, eCur, 0.20, 0.50, 4000, 8000) -- 4k..12k
    local mBuf, mTag = HybridBufScore(mPct, mCur, 0.15, 0.55, 200, 450)   -- 200..650

    local eTrend = clamp((eNetEMA + 8) / 16, 0, 1)
    local mTrend = clamp((mNetEMA + 4) / 10, 0, 1)

    local penalty = 0
    local penaltyText = ""
    local whyTag = ("E %s / M %s"):format(eTag, mTag)

    if projectActive then
        penalty = penalty + 8
        if penaltyText == "" then penaltyText = "Project in progress — protect buffers" end
    end

    if projectActive and buildPowerCount >= 7 and ((ePct < 0.22 and eCur < 4500) or eNetEMA < -10) and ((mCur < 400 and mPct < 0.25) or mNetEMA < -6) then
        penalty = penalty + 15
        penaltyText = ("Buildpower spike risk (%d builders)"):format(buildPowerCount)
    end

    -- IMPORTANT: no “metal crash” penalty here unless buffer is genuinely low
    local lowMetalBuffer = (mPct < 0.15 and mCur < 600) or (mCur < 300)
    if projectActive and lowMetalBuffer and mNetRaw < -6 then
        penalty = penalty + 12
        penaltyText = "Metal buffer low during project"
    end

    local score = 100 * (0.30*eBuf + 0.30*mBuf + 0.20*eTrend + 0.20*mTrend) - penalty
    score = clamp(score, 0, 100)

    local label, col = ReadinessLabelAndColor(score)
    local why = WhyFromContrib({eBuf=eBuf, mBuf=mBuf, eTrend=eTrend, mTrend=mTrend}, penaltyText, whyTag)

    return math.floor(score + 0.5), label, col, why
end

local function ReadinessForT3(projectActive)
    local eBuf, eTag = HybridBufScore(ePct, eCur, 0.25, 0.55, 8000, 14000) -- 8k..22k
    local mBuf, mTag = HybridBufScore(mPct, mCur, 0.20, 0.60, 450, 900)    -- 450..1350

    local eTrend = clamp((eNetEMA + 10) / 20, 0, 1)
    local mTrend = clamp((mNetEMA + 5) / 12, 0, 1)

    local penalty = 0
    local penaltyText = ""
    local whyTag = ("E %s / M %s"):format(eTag, mTag)

    local energyRich = (ePct > 0.60) or (eNetEMA > 6) or (eCur > 12000)
    local metalPressure = (mPct < 0.35) or (mNetEMA < -3) or (mCur < 350)

    if projectActive then
        penalty = penalty + 6
        if penaltyText == "" then penaltyText = "Project in progress — avoid over-commit" end
    end

    if energyRich and metalPressure and t2ConverterCount < 4 then
        penalty = penalty + 12
        penaltyText = ("Need more T2 converters (%d/4)"):format(t2ConverterCount)
    end

    if mexUpgradedCount < 3 then
        penalty = penalty + 10
        if penaltyText == "" then
            penaltyText = ("Need more upgraded mex (%d/3)"):format(mexUpgradedCount)
        end
    end

    local spine = (reactorCount > 0 or afusCount > 0) and 1 or 0
    local spineBonus = spine * 6

    -- Slightly more metal-weighted: Ebuf 0.28 / Mbuf 0.34 / Etrend 0.18 / Mtrend 0.20
    local score = 100 * (0.28*eBuf + 0.34*mBuf + 0.18*eTrend + 0.20*mTrend) + spineBonus - penalty
    score = clamp(score, 0, 100)

    local label, col = ReadinessLabelAndColor(score)
    local why = WhyFromContrib({eBuf=eBuf, mBuf=mBuf, eTrend=eTrend, mTrend=mTrend}, penaltyText, whyTag)

    return math.floor(score + 0.5), label, col, why
end

--------------------------------------------------------------------------------
-- LENS (Boom / Pressure / Balanced)
--------------------------------------------------------------------------------

local function UpdateLens()
    local boom = (mexCount >= 6) and (buildPowerCount >= 4) and (idleFactoryCount == 0)
    local pressure = (mexCount <= 5) and (factoryCount >= 1) and (buildPowerCount <= 3)

    if boom then
        lensText = "Lens: Boom (eco lead) — spend into upgrades/tech"
        lensColor = {0.75,0.95,1,1}
    elseif pressure then
        lensText = "Lens: Pressure (tempo) — keep factory queued"
        lensColor = {1,0.9,0.35,1}
    else
        lensText = "Lens: Balanced — keep tempo & prep next window"
        lensColor = {0.85,0.9,1,1}
    -- Anti-flicker: smooth lens text to avoid rapid mode flips
    local nowSec = Spring.GetGameSeconds()
    lensText, lensColor = SmoothTextColor("lens", lensText, lensColor, nowSec, SMOOTH_HOLD_SEC, IsUrgentStatus(lensText))
    end


function UpdateStatusLine(projectActive, milestonesDone)
    -- Keep this calm + descriptive. Never command.
    if projectActive then
        statusText = "Status: Project in progress — protect buffers, avoid over-assist"
        statusColor = {1, 0.9, 0.35, 1}
        return
    end

    -- Eco stress states (use ecoLabel as player-facing summary)
    if ecoLabel:find("Crashing") then
        statusText = "Status: Eco crashing — stabilise before committing"
        statusColor = {1, 0.35, 0.35, 1}
        return
    end
    if ecoLabel:find("Tight") or ecoLabel:find("Leaning") or ecoLabel:find("Converting") then
        statusText = "Status: Eco stressed — stabilise, then choose next focus"
        statusColor = {1, 0.75, 0.35, 1}
        return
    end

    -- Stable
    if milestonesDone and (#todo == 0) then
        statusText = "Status: Eco stable — choose a focus (eco consistency / tempo / tech prep)"
        statusColor = {0.75, 0.95, 1, 1}
    else
        statusText = "Status: Eco stable — complete phase items, then pick a focus"
        statusColor = {0.85, 0.9, 1, 1}
    end
    -- Anti-flicker: smooth status text; urgent states swap immediately
    local nowSec = Spring.GetGameSeconds()
    local force = projectActive or IsUrgentStatus(statusText)
    statusText, statusColor = SmoothTextColor("status", statusText, statusColor, nowSec, SMOOTH_HOLD_SEC, force)
end
end

--------------------------------------------------------------------------------
-- GUIDANCE (Milestones + Todo + Prep fallback + slider/storage + idle + buildpower)
--------------------------------------------------------------------------------

local function UpdateGuidance(projectActive)
    Clear(milestones)
    Clear(todo)
    Clear(focus)

    local t = Spring.GetGameSeconds()
    phaseColor = PhaseTimingColor(currentPhaseKey, t)
    UpdateLens()

    local function done(cond) return cond and "done" or nil end

    -- Phase-scoped buildpower milestones (ranges, eco-gated)
    local function AddBuildpowerMilestones()
        if currentPhaseKey == "opening" then
            Add(milestones, "Buildpower: 2+ builders", nil, done(buildPowerCount >= 2))
        elseif currentPhaseKey == "t1Bridge" then
            Add(milestones, "Buildpower: 3–4 builders", nil, done(buildPowerCount >= 3))
        elseif currentPhaseKey == "t2" then
            Add(milestones, "Buildpower: 5–7 builders OR 1 CT", nil, done(buildPowerCount >= 5 or constructionTurretCount >= 1))
        elseif currentPhaseKey == "t3" then
            Add(milestones, "Buildpower: 6+ builders OR 2 CT (eco dependent)", nil, done(buildPowerCount >= 6 or constructionTurretCount >= 2))
        end
    end

    -- Milestones (phase-scoped)
    if currentPhaseKey == "opening" then
        Add(milestones,"Get first factory online (Bot Lab)",nil,done(hasT1Factory))
        Add(milestones,"Secure 2–4 mex",nil,done(mexCount >= 2))
        Add(milestones,"Wind online (5+)",nil,done(windCount >= 5))
        AddBuildpowerMilestones()
        Add(milestones,"Next Phase: T1 Bridge","hint")
    elseif currentPhaseKey == "t1Bridge" then
        Add(milestones,"4+ mex secured",nil,done(mexCount >= 4))
        Add(milestones,"Radar coverage (radar building)",nil,done(radarCount >= 1))
        AddBuildpowerMilestones()
        Add(milestones,"Next Phase: Tech Window (T2)","hint")
    elseif currentPhaseKey == "tech" then
        Add(milestones,"T2 Factory started",nil,done(buildingT2Factory or hasT2Factory))
        Add(milestones,"T2 Factory completed",nil,done(hasT2Factory))
        Add(milestones,"Next Phase: T2 Spike","hint")
    elseif currentPhaseKey == "t2" then
        Add(milestones,"T2 Factory",nil,done(hasT2Factory))
        Add(milestones,"T2 Builder (T2 constructor)",nil,done(t2BuilderCount >= 1))
        Add(milestones,"3+ mex upgraded",nil,done(mexUpgradedCount >= 3))
        AddBuildpowerMilestones()
        Add(milestones,"Next Phase: T3 Transition","hint")
    elseif currentPhaseKey == "t3" then
        Add(milestones,"Power spine: Fusion/AFUS online",nil,done((reactorCount > 0 or afusCount > 0)))
        Add(milestones,"T2 eco stable (no crashing)",nil,done((ecoLabel ~= "Crashing Eco") and (lastT3Score >= 75)))
        AddBuildpowerMilestones()
        Add(milestones,"Next Phase: Endgame","hint")
    else
        Add(milestones,"T3 online (if/when built)",nil,done(hasT3Factory))
        Add(milestones,"Spend eco into production",nil, done(factoryCount > 0 and idleFactoryCount == 0))
        Add(milestones,"Next Phase: —","hint")
    end

    local function AllMilestonesDone()
        for _,m in ipairs(milestones) do
            if m.color ~= "hint" and m.status ~= "done" then return false end
        end
        return true
    end

    -- If T2 Spike milestones are all done, show “ready” tone (without changing phase)
    if currentPhaseKey == "t2" and AllMilestonesDone() then
        phaseLabel = "T2 Spike — READY for Eco Spine (Fusion/AFUS) / T3 Prep"
    end

    -- Todo = ASAP (max 6)
    local function AddASAP(text, color)
        if #todo < 6 then Add(todo, text, color) end
    end

    local energySafe    = (ePct > 0.30 or eCur > 4500) and (eNetEMA >= -1)
    local energyDipping = (eNetEMA < -6) or (ePct < 0.18 and eCur < 2500)
    local energyCrash   = (ePct < 0.10 and eCur < 1200) and (eNetEMA < -10)

    local metalLow      = (mCur < 220) or ((mPct < 0.20) and (mCur < 800))
    if mCur > 3000 then metalLow = false end -- ignore % when banked metal is high
    local metalPressure = metalLow or (mNetEMA < -3) or (mNetRaw < -5)

    local energyRich    = (ePct > 0.60) or (eNetEMA > 6) or (eCur > 9000)
    local energyWasted  = (ePct > 0.90) and (eNetEMA > 4)

    -- Readiness lines (with “Why”)
    readinessText, readinessWhyText = "", ""

    if currentPhaseKey == "t1Bridge" or currentPhaseKey == "tech" then
        local score, label, col, why = ReadinessForT2(projectActive)
        lastT2Score = score
        if projectActive then
            readinessText = ("T2 Build: IN PROGRESS — %d (%s)"):format(score, label)
        else
            readinessText = ("T2 Readiness: %d — %s"):format(score, label)
        end
        readinessWhyText = why
        readinessColor = col
        readinessWhyColor = {0.8, 0.85, 1, 1}
    elseif currentPhaseKey == "t2" or currentPhaseKey == "t3" then
        local score, label, col, why = ReadinessForT3(projectActive)
        lastT3Score = score
        if projectActive and (anyFactoryBuilding or bigSpendBuilding) then
            readinessText = ("T3 Prep: PROJECT ACTIVE — %d (%s)"):format(score, label)
        else
            readinessText = ("T3 Readiness: %d — %s"):format(score, label)
        end
        readinessWhyText = why
        readinessColor = col
        readinessWhyColor = {0.8, 0.85, 1, 1}
    end
    -- Anti-flicker: smooth readiness lines (project swaps immediately)
    do
        local nowSec = Spring.GetGameSeconds()
        local force = projectActive
        readinessText, readinessColor = SmoothTextColor("readiness", readinessText, readinessColor, nowSec, 1.2, force)
        readinessWhyText, readinessWhyColor = SmoothTextColor("readinessWhy", readinessWhyText, readinessWhyColor, nowSec, 1.2, force)
    end


    -- Emergency (energy)
    if energyCrash then
        AddASAP("Emergency: Energy crashing — stop stacking builds", "block")
        AddASAP("Blocked by: Energy crash (finish power / wind first)", "block")
        return
    end

    -- Sustained metal crash detection (FIX)
    -- Only warn if:
    --  - projectActive, AND
    --  - sustained sharp negative raw metal, AND
    --  - buffer is genuinely low (NOT “5k metal but storage huge”)
    local lowMetalBuffer = (mPct < 0.15 and mCur < 600) or (mCur < 300)
    if projectActive and (mNetRaw < -6) then
        mCrashTicks = math.min(mCrashTicks + 1, 10)
    else
        mCrashTicks = 0
    end

    if projectActive and lowMetalBuffer and (mCrashTicks >= 2) then
        AddASAP("CRITICAL: Metal buffer low during project — stop assisting", "block")
        if energyRich then
            AddASAP("Fix: scale converters / slider to hold Metal", "warn")
        else
            AddASAP("Fix: pause queues + stabilise (bank Metal)", "warn")
        end
    end

    -- Eco comfort gate
    local ecoComfort = (ePct > 0.25 or eCur > 3000) and (mPct > 0.20 or mCur > 160) and (eNetEMA > -8)

    -- Idle factories (only if eco is comfortable)
    if ecoComfort and idleFactoryCount > 0 then
        AddASAP(("Idle factory detected (%d) → queue units"):format(idleFactoryCount), "warn")
    end

    -- Slider / conversion / storage guidance (smart preference)
    if energyWasted then
        if (metalPressure or projectActive or currentPhaseKey == "tech" or currentPhaseKey == "t3") then
            if converterCount <= 0 then
                AddASAP("Energy overflowing + metal pressure → build converters", "good")
            else
                AddASAP("Energy overflowing → adjust conversion slider → more Metal", "good")
                if (currentPhaseKey == "t2" or currentPhaseKey == "t3" or currentPhaseKey == "endgame") and t2ConverterCount < 4 then
                    AddASAP("Scale T2 converters (avoid metal choke)", "warn")
                elseif (currentPhaseKey == "t1Bridge") and t1ConverterCount < 2 then
                    AddASAP("Add 1–2 T1 converters (smooth T2 start)", "warn")
                end
            end
        else
            AddASAP("Energy overflowing → build energy storage (stop waste)", "warn")
        end
    end

    if energyDipping and converterCount > 0 then
        AddASAP("Energy dipping → adjust conversion slider → less Metal (save Energy)", "warn")
    end

    -- Buildpower Todo triggers (eco-gated)
    if ecoComfort and not projectActive then
        local floatingMetal = (mPct > 0.60) or (mNetEMA > 2)
        local floatingEnergy = (ePct > 0.70) or (eNetEMA > 6) or (eCur > 12000)

        if (floatingMetal or (floatingEnergy and metalPressure)) then
            if currentPhaseKey == "t1Bridge" and buildPowerCount < 4 then
                AddASAP("Floating eco → add buildpower (1 constructor)", "good")
            elseif (currentPhaseKey == "t2" or currentPhaseKey == "t3") and (constructionTurretCount < 1 and buildPowerCount < 6) then
                AddASAP("Spending slow → build 1 Construction Turret", "good")
            end
        end
    end

    if (buildPowerCount >= 6) and (energyDipping or eNetRaw < -6) then
        AddASAP("Buildpower spike risk → stop assisting / pause extra builders", "warn")
    end

    -- Phase-critical guidance
    if currentPhaseKey == "opening" then
        if not hasT1Factory then AddASAP("Build T1 Bot Lab NOW", "warn") end
        if windCount < 5 then AddASAP("Build Wind (aim 5+)", "warn") end
        if mexCount < 2 then AddASAP("Capture mex (2+)", "warn") end

    elseif currentPhaseKey == "t1Bridge" then
        if mexCount < 4 then AddASAP("Expand: secure 4+ mex", "warn") end
        if radarCount < 1 then AddASAP("Build radar building (awareness)", "warn") end

        if metalLow and energyRich then
            if converterCount == 0 then
                AddASAP("Metal tight + energy rich → build T1 converters", "good")
            else
                AddASAP("Metal tight → adjust conversion slider → more Metal", "good")
            end
        end

        if #todo == 0 and AllMilestonesDone() then
            if not energySafe then
                AddASAP("Prep T2: add power buffer", "prep")
                AddASAP("Blocked by: Energy dipping", "block")
            else
                AddASAP("Prep T2: bank metal (convert if needed)", "prep")
            end
        end

    elseif currentPhaseKey == "tech" then
        if not (buildingT2Factory or hasT2Factory) then
            if energySafe and not energyDipping and not metalPressure then
                AddASAP("Start T2 Factory (safe window)", "good")
            else
                AddASAP("Prep T2 Factory", "warn")
                if energyDipping then AddASAP("Blocked by: Energy dipping", "block") end
                if metalPressure then AddASAP("Blocked by: Metal too low (bank/convert)", "block") end
            end
        else
            if metalPressure and energyRich then
                AddASAP("Project spend + metal pressure → scale converters", "warn")
                AddASAP("Adjust conversion slider → more Metal", "good")
            elseif metalPressure then
                AddASAP("Protect metal: reduce assisting / pause extras", "warn")
            end

            if energyDipping then
                AddASAP("Stabilise: pause extra builds to finish T2", "warn")
                AddASAP("Blocked by: Energy dipping", "block")
            else
                AddASAP("Finish T2 clean (avoid hard stall)", "good")
            end
        end

    elseif currentPhaseKey == "t2" then
        if t2BuilderCount < 1 then
            AddASAP("Get a T2 constructor ASAP", "warn")
            AddASAP("Blocked by: Need T2 factory online", (hasT2Factory and "prep" or "block"))
        end
        if mexUpgradedCount < 3 then AddASAP("Upgrade mex (aim 3+)", "warn") end

        if metalPressure and energyRich then
            if t2ConverterCount < 4 then AddASAP("Prep T3: build T2 converters (aim 4+)", "good") end
            if converterCount > 0 then AddASAP("Prep T3: adjust conversion slider → more Metal", "good") end
        end

    elseif currentPhaseKey == "t3" then
        if (reactorCount == 0 and afusCount == 0) then
            if energySafe and not energyDipping and not metalPressure then
                AddASAP("Start Fusion/AFUS (safe window)", "good")
            else
                AddASAP("Prep Fusion/AFUS", "warn")
                if energyDipping then AddASAP("Blocked by: Energy dipping", "block") end
                if metalPressure then AddASAP("Blocked by: Metal too low (convert/bank)", "block") end
            end
        end

        if metalPressure and energyRich and (t2ConverterCount < 6) then
            AddASAP("Scale T2 converters (feed T3 soon)", "good")
        end

    else
        if metalPressure and energyRich then
            AddASAP("Metal tight: add converters before big spends", "warn")
            AddASAP("Adjust conversion slider → more Metal", "good")
        elseif ecoComfort and idleFactoryCount > 0 then
            AddASAP("Endgame: keep factories queued (tempo)", "warn")
        else
            AddASAP("Spend eco into production (avoid floating)", "good")
        end
    end

    -- Prep fallback if Todo empty + on track + milestones done
    local onTrack = (phaseColor[1] > 0.55 and phaseColor[2] > 0.9)
    if (#todo == 0) and onTrack and AllMilestonesDone() then
        local function AddPREP(text)
            if #todo < 3 then Add(todo, "Prep: " .. text, "prep") end
        end

        if currentPhaseKey == "opening" then
            AddPREP("keep wind climbing (buffer for expansion)")
            AddPREP("secure extra mex if safe")
        elseif currentPhaseKey == "t2" then
            AddPREP("prepare spine: power + converters")
            AddPREP("avoid idle factories (keep tempo)")
        elseif currentPhaseKey == "t3" then
            AddPREP("stabilise eco spine before huge queues")
            AddPREP("scale converters so metal doesn’t choke endgame")
        else
            AddPREP("keep spending — eco idle is lost tempo")
        end
    end

    
    ------------------------------------------------------------------------
    -- Focus Options (Hybrid coaching)
    -- Shows 2–3 neutral "lanes" when eco is comfortable (OS50-style choices)
    ------------------------------------------------------------------------
    local function AddFocusLine(txt)
        Add(focus, txt, {0.85,0.9,1,1}, nil)
    end

    local function AddFocusOptions()
        if not ecoComfort then return end
        if ecoLabel ~= "Stable Eco" then return end

        local maxLines = 3
        local function push(txt)
            if #focus < maxLines then AddFocusLine(txt) end
        end

        -- During projects: protective guidance only (soft)
        if projectActive then
            push("During project: protect buffers (avoid stalls)")
            if buildPowerCount >= 7 and ((eNetEMA < -10) or (mNetEMA < -6)) then
                push("During project: avoid over-assist if eco is dipping")
            end
            if (ePct > 0.75 or eCur > 9000) and (mCur < 600) and (converterCount < 4) then
                push("After project: add converters / adjust conversion slider")
            end
            return
        end

        -- Behaviour bias (light): only when eco is comfortable
        if idleFactoryCount > 0 then
            push("Tempo: keep factories producing (avoid idle time)")
        end

        -- Phase bias (light)
        if currentPhaseKey == "opening" or currentPhaseKey == "t1Bridge" then
            push("Eco consistency: smooth power (wind/storage) before tech")
            push("Map focus: scout/expand while eco is stable")
        elseif currentPhaseKey == "tech" then
            push("Prep tech: bank metal + keep power steady")
            push("Eco consistency: prevent dips before starting T2")
        elseif currentPhaseKey == "t2" then
            push("Buildpower: add 1–2 builders/turrets if eco allows")
            push("Eco consistency: scale converters if metal is the choke")
        elseif currentPhaseKey == "t3" then
            push("Prep T3: bank metal + keep eco spine smooth")
            push("Tempo: turn eco into production (avoid idle)")
        else
            push("Endgame: spend eco into production (avoid idle)")
            push("Eco consistency: prevent stalls under big queues")
        end

        -- If we still have room, add a gentle universal option
        if #focus < maxLines then
            push("Optional: add storage to reduce small waste/spikes")
        end
    end

    -- Show focus options when nothing urgent is screaming (todo light), or milestones mostly complete
    local function ShouldShowFocus()
        if #todo == 0 then return true end
        if AllMilestonesDone and AllMilestonesDone() then return true end
        return false
    end

    if ShouldShowFocus() then
        AddFocusOptions()
    end


-- Status line (why / context)
    UpdateStatusLine(projectActive, AllMilestonesDone())

end

--------------------------------------------------------------------------------
-- DRAW (centered + colored arrows + readiness + WHY + lens)
--------------------------------------------------------------------------------

function widget:DrawScreen()
    local vsx,vsy = Spring.GetViewGeometry()
    local cx = vsx * anchorX
    local y = vsy * anchorY
    local fs = fontSize * uiScale
    local line = fs * 1.25

    -- Rhythm base line
    local prefix = "Rhythm: " .. ecoLabel .. " — "
    local baseLine = prefix .. "E " .. eArrow .. "  M " .. mArrow

    gl.Color(rhythmColor)
    gl.Text(baseLine, cx, y, fs * 1.6, "oc")

    -- overlay colored arrows (approx)
    local totalW = gl.GetTextWidth(baseLine) * (fs * 1.6)
    local xLeft = cx - (totalW * 0.5)
    local wPrefix = gl.GetTextWidth(prefix) * (fs * 1.6)

    local xE = xLeft + wPrefix + gl.GetTextWidth("E ") * (fs * 1.6)
    local xM = xLeft + wPrefix + gl.GetTextWidth("E " .. eArrow .. "  M ") * (fs * 1.6)

    gl.Color(eArrowColor)
    gl.Text(eArrow, xE, y, fs * 1.6, "o")

    gl.Color(mArrowColor)
    gl.Text(mArrow, xM, y, fs * 1.6, "o")

    y = y - line*1.2

    if showPhaseLine then
    -- Phase
    gl.Color(phaseColor[1], phaseColor[2], phaseColor[3], phaseColor[4])
    gl.Text("Phase: "..phaseLabel, cx, y, fs * 1.15, "oc")
    y = y - line

    end
    if showReadiness then
    -- Readiness
    if readinessText ~= "" then
        gl.Color(readinessColor[1], readinessColor[2], readinessColor[3], readinessColor[4])
        gl.Text(readinessText, cx, y, fs * 1.05, "oc")
        y = y - line*0.95

        if readinessWhyText ~= "" then
            gl.Color(readinessWhyColor[1], readinessWhyColor[2], readinessWhyColor[3], readinessWhyColor[4])
            gl.Text(readinessWhyText, cx, y, fs * 0.98, "oc")
            y = y - line
        else
            y = y - line*0.4
        end
    end

    end
    if showStatusLine then
    -- Status line
    if statusText ~= "" then
        gl.Color(statusColor[1], statusColor[2], statusColor[3], statusColor[4])
        gl.Text(statusText, cx, y, fs * 1.02, "oc")
        y = y - line*1.05
    end

    -- Lens line
    if lensText ~= "" then
        gl.Color(lensColor[1], lensColor[2], lensColor[3], lensColor[4])
        gl.Text(lensText, cx, y, fs * 1.02, "oc")
        y = y - line*1.2
    else
        y = y - line*0.6
    end

    end
    if showMilestones then
    -- Milestones header
    gl.Color(0.75, 0.9, 1, 1)
    gl.Text("Milestones", cx, y, fs * 1.12, "oc")
    y = y - line

    for _,m in ipairs(milestones) do
        local r,g,b = 1,1,1
        if m.status=="done" then r,g,b = 0.6,1,0.6
        elseif m.color=="hint" then r,g,b = 0.8,0.85,1 end
        gl.Color(r,g,b,1)
        gl.Text((m.status=="done" and "✓ " or "• ")..m.text, cx, y, fs * 1.02, "oc")
        y = y - line
    end

    y = y - line*0.5

    end
    if showTodo then
    -- Todo header
    gl.Color(1, 0.9, 0.35, 1)
    gl.Text("Todo (ASAP / Prep)", cx, y, fs * 1.12, "oc")
    y = y - line

    for _,t in ipairs(todo) do
        local r,g,b = 1,1,1
        if t.color=="good" then r,g,b=0.7,1,0.7
        elseif t.color=="warn" then r,g,b=1,0.8,0.4
        elseif t.color=="block" then r,g,b=1,0.5,0.5
        elseif t.color=="prep" then r,g,b=0.75,0.9,1 end
        gl.Color(r,g,b,1)
        gl.Text("• "..t.text, cx, y, fs * 1.05, "oc")
        y = y - line
    end

    end
    -- Focus Options (shown only when available)
    if showFocusOptions and #focus > 0 then
        y = y - line*0.4
        gl.Color(0.85, 0.9, 1, 1)
        gl.Text("Focus options", cx, y, fs * 1.08, "oc")
        y = y - line
        for _,f in ipairs(focus) do
            local r,g,b = 0.85,0.9,1
            if f.color=="good" then r,g,b=0.7,1,0.7
            elseif f.color=="warn" then r,g,b=1,0.8,0.4
            elseif f.color=="block" then r,g,b=1,0.5,0.5
            elseif f.color=="prep" then r,g,b=0.75,0.9,1 end
            gl.Color(r,g,b,1)
            gl.Text("• "..f.text, cx, y, fs * 1.02, "oc")
            y = y - line
        end
    end

end

--------------------------------------------------------------------------------
-- UPDATE LOOP
--------------------------------------------------------------------------------

function widget:GameFrame(f)
    if f % 30 ~= 0 then return end -- ~1s

    -- projectActive computed from last unit scan; do quick prediction using cached flags too
    local projectActive = buildingT2Factory or anyFactoryBuilding or bigSpendBuilding or bigProjectBuilding

    UpdateEconomy(projectActive)
    UpdateUnits()

    -- recompute with fresh unit scan (more accurate for this tick)
    projectActive = buildingT2Factory or anyFactoryBuilding or bigSpendBuilding or bigProjectBuilding

    UpdatePhase(Spring.GetGameSeconds())
    UpdateRhythm(projectActive)
    UpdateGuidance(projectActive)
end

--------------------------------------------------------------------------------
-- CONFIG (persist Settings > Custom across restarts)
--------------------------------------------------------------------------------

function widget:GetConfigData()
    return {
        uiScale = uiScale,
        anchorX = anchorX,
        anchorY = anchorY,
        showPhaseLine = showPhaseLine,
        showReadiness = showReadiness,
        showStatusLine = showStatusLine,
        showMilestones = showMilestones,
        showTodo = showTodo,
        showFocusOptions = showFocusOptions,
    }
end

function widget:SetConfigData(data)
    if type(data) ~= "table" then return end

    if type(data.uiScale) == "number" then uiScale = data.uiScale end
    if type(data.anchorX) == "number" then anchorX = data.anchorX end
    if type(data.anchorY) == "number" then anchorY = data.anchorY end

    if type(data.showPhaseLine) == "boolean" then showPhaseLine = data.showPhaseLine end
    if type(data.showReadiness) == "boolean" then showReadiness = data.showReadiness end
    if type(data.showStatusLine) == "boolean" then showStatusLine = data.showStatusLine end
    if type(data.showMilestones) == "boolean" then showMilestones = data.showMilestones end
    if type(data.showTodo) == "boolean" then showTodo = data.showTodo end
    if type(data.showFocusOptions) == "boolean" then showFocusOptions = data.showFocusOptions end
end

--------------------------------------------------------------------------------
-- SETTINGS (Settings > Custom)
--------------------------------------------------------------------------------

function widget:Initialize()
    if not (WG and WG.options and WG.options.addOption) then
        return
    end

    -- Prevent duplicate Settings > Custom entries when toggling the widget off/on.
    -- WG persists across widget reloads, so we keep a single shared options registration.
    if WG.__BR_BattleRhythm_OptionsAdded then
        return
    end
    WG.__BR_BattleRhythm_OptionsAdded = true

    local function SafeAdd(opt)
        pcall(WG.options.addOption, opt)
    end

    local wname = "BAR: Battle Rhythm"
    local group = "custom"
    local category = 2

    SafeAdd({
        widgetname = wname,
        id = "br_ui_scale",
        group = group,
        category = category,
        name = "UI Scale",
        type = "slider",
        min = 0.75,
        max = 1.75,
        step = 0.05,
        value = uiScale,
        description = "Scale the Battle Rhythm UI.",
        onchange = function(_, value)
            uiScale = tonumber(value) or uiScale
        end
    })

    SafeAdd({
        widgetname = wname,
        id = "br_pos_x",
        group = group,
        category = category,
        name = "Position X",
        type = "slider",
        min = 0.05,
        max = 0.99,
        step = 0.01,
        value = anchorX,
        description = "Horizontal position of the UI (0=left, 1=right).",
        onchange = function(_, value)
            anchorX = tonumber(value) or anchorX
        end
    })

    SafeAdd({
        widgetname = wname,
        id = "br_pos_y",
        group = group,
        category = category,
        name = "Position Y",
        type = "slider",
        min = 0.05,
        max = 0.99,
        step = 0.01,
        value = anchorY,
        description = "Vertical position of the UI (0=bottom, 1=top).",
        onchange = function(_, value)
            anchorY = tonumber(value) or anchorY
        end
    })

    -- Section toggles (shown if your options UI supports bool types)
    local function AddToggle(id, label, getterSetter)
        SafeAdd({
            widgetname = wname,
            id = id,
            group = group,
            category = category,
            name = label,
            type = "bool",
            value = getterSetter(),
            description = "Show/hide this section.",
            onchange = function(_, value)
                getterSetter(value)
            end
        })
    end

    AddToggle("br_show_phase", "Show Phase", function(v) if v ~= nil then showPhaseLine = v end return showPhaseLine end)
    AddToggle("br_show_readiness", "Show Readiness", function(v) if v ~= nil then showReadiness = v end return showReadiness end)
    AddToggle("br_show_status", "Show Status line", function(v) if v ~= nil then showStatusLine = v end return showStatusLine end)
    AddToggle("br_show_milestones", "Show Milestones", function(v) if v ~= nil then showMilestones = v end return showMilestones end)
    AddToggle("br_show_todo", "Show Todo", function(v) if v ~= nil then showTodo = v end return showTodo end)
    AddToggle("br_show_focus", "Show Focus options", function(v) if v ~= nil then showFocusOptions = v end return showFocusOptions end)
end