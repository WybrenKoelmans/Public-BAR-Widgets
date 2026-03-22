function widget:GetInfo()
  return {
    name = "Battle Resource Tracker",
    desc = "Shows the resource gains/losses in battles",
    author = "citrine",
    date = "2023",
    license = "GNU GPL, v2 or later",
    version = 9,
    layer = -100,
    enabled = true
  }
end

local config = {
  -- user configuration
  -- =============

  -- the maximum distance at which battles can be combined
  searchRadius = 600,

  -- how long battles stay visible if they haven't changed (in seconds)
  eventTimeout = 15,

  -- font size for battle text
  fontSize = 80,

  -- maximum alpha value for resource delta text (0-1, 1=opaque, 0=transparent)
  maxTextAlpha = 0.8,

  -- what resources to display, and how to combine them
  -- "metal", "energy", "both" (show m and e separately), "combined" (convert e to m and combine)
  resourceMode = "both",

  -- show old events as rates instead of total
  showRates = false,

  -- advanced configuration
  -- ======================

  -- RGB text color that indicates a positive resource delta (your opponents lost resources)
  positiveTextColor = { 0.3, 1, 0.3 },

  -- RGB text color that indicates a negative resource delta (your allyteam lost resources)
  negativeTextColor = { 1, 0.3, 0.3 },

  -- RGB text color for the "m" that denotes metal
  metalTextColor = { 0.8, 0.8, 0.8 },

  -- RGB text color for the "e" that denotes metal
  energyTextColor = { 0.9, 0.9, 0.1 },

  -- RGB text color for the "ᵯ" that denotes metal
  combinedTextColor = { 0.85, 0.85, 0.7 },

  -- the size of the cells that the map is divided into (for performance optimization)
  spatialHashCellSize = 500,

  -- how often to check and remove old events (for performance optimization)
  eventTimeoutCheckPeriod = 30 * 1,

  -- how distance affects font size when drawing using DrawScreenEffects
  distanceScaleFactor = 1800,

  -- how much to increase the size of the text as you zoom out
  farCameraTextBoost = 0.8,

  -- method used to draw text ("gl" or "lua")
  textMode = "lua",

  -- energy per metal ratio for combining metal and energy values
  conversionRatio = 70,

  -- distance to swap between drawing text under units, and above units/icons
  cameraThreshold = 3500,

  -- what drawing mode to use depending on camera distance
  -- "PreDecals", "WorldPreUnit", "World", "ScreenEffects", or nil
  nearCameraMode = "PreDecals",
  farCameraMode = "ScreenEffects",
}

-- engine call optimizations
-- =========================

local SpringGetCameraState = Spring.GetCameraState
local SpringGetGameFrame = Spring.GetGameFrame
local SpringGetGroundHeight = Spring.GetGroundHeight
local SpringGetMyTeamID = Spring.GetMyTeamID
local SpringGetTeamAllyTeamID = Spring.GetTeamAllyTeamID
local SpringGetUnitHealth = Spring.GetUnitHealth
local SpringGetUnitPosition = Spring.GetUnitPosition
local SpringIsGUIHidden = Spring.IsGUIHidden
local SpringWorldToScreenCoords = Spring.WorldToScreenCoords
local SpringIsSphereInView = Spring.IsSphereInView
local SpringGetCameraRotation = Spring.GetCameraRotation
local SpringGetUnitMoveTypeData = Spring.GetUnitMoveTypeData

local glPushMatrix = gl.PushMatrix
local glPopMatrix = gl.PopMatrix
local glTranslate = gl.Translate
local glRotate = gl.Rotate
local glColor = gl.Color
local glText = gl.Text

local mathPi = math.pi
local mathFloor = math.floor
local mathRound = math.round
local mathSqrt = math.sqrt
local mathMin = math.min
local mathMax = math.max

-- utils
-- =====

local function map(list, func)
  local result = {}
  for i, v in ipairs(list) do
    result[i] = func(v, i)
  end
  return result
end

-- spatial hash implementation
-- ===========================

local SpatialHash = {}
SpatialHash.__index = SpatialHash

function SpatialHash.new(cellSize)
  local self = setmetatable({}, SpatialHash)
  self.cellSize = cellSize
  self.cells = {}
  return self
end

function SpatialHash:hashKey(x, z)
  return string.format("%d,%d", mathFloor(x / self.cellSize), mathFloor(z / self.cellSize))
end

function SpatialHash:clear()
  self.cells = {}
end

function SpatialHash:addEvent(event)
  local key = self:hashKey(event.x, event.z)
  local cell = self.cells[key]
  if not cell then
    cell = {}
    self.cells[key] = cell
  end
  table.insert(cell, event)
end

function SpatialHash:removeEvent(event)
  local key = self:hashKey(event.x, event.z)
  local cell = self.cells[key]
  if cell then
    for i, storedEvent in ipairs(cell) do
      if storedEvent == event then
        table.remove(cell, i)
        break
      end
    end
  end
end

function SpatialHash:allEvents(filterFunc)
  local events = {}
  for _, cell in pairs(self.cells) do
    for _, event in ipairs(cell) do
      if not filterFunc or filterFunc(event) then
        table.insert(events, event)
      end
    end
  end
  return events
end

function SpatialHash:getNearbyEvents(x, z, radius)
  local nearbyEvents = {}
  local startX = mathFloor((x - radius) / self.cellSize)
  local startZ = mathFloor((z - radius) / self.cellSize)
  local endX = mathFloor((x + radius) / self.cellSize)
  local endZ = mathFloor((z + radius) / self.cellSize)

  for i = startX, endX do
    for j = startZ, endZ do
      local key = self:hashKey(i * self.cellSize, j * self.cellSize)
      local cell = self.cells[key]
      if cell then
        for _, event in ipairs(cell) do
          local distance = mathSqrt((event.x - x) ^ 2 + (event.z - z) ^ 2)
          if distance <= radius then
            table.insert(nearbyEvents, event)
          end
        end
      end
    end
  end

  return nearbyEvents
end

-- widget code
-- ===========

local spatialHash = SpatialHash.new(config.spatialHashCellSize)
local drawLocation = nil
local font = nil
local isGameStarted = false
local ignoreUnitDestroyed = {}

local function combineEvents(events)
  -- Calculate the average position (weighted by number of events)
  local totalSubEvents = 0
  local averageX, averageZ = 0, 0
  for _, event in ipairs(events) do
    averageX = averageX + (event.x * event.n)
    averageZ = averageZ + (event.z * event.n)
    totalSubEvents = totalSubEvents + event.n
  end
  averageX = averageX / totalSubEvents
  averageZ = averageZ / totalSubEvents

  -- Sum team metal values
  local totalMetal = {}
  local totalEnergy = {}
  for _, event in ipairs(events) do
    for key, value in pairs(event.metal) do
      totalMetal[key] = (totalMetal[key] or 0) + value
    end

    for key, value in pairs(event.energy) do
      totalEnergy[key] = (totalEnergy[key] or 0) + value
    end
  end

  -- Calculate max game time (most recent event)
  local maxT = 0
  local minT = SpringGetGameFrame()
  for _, event in ipairs(events) do
    maxT = mathMax(event.maxT, maxT)
    minT = mathMin(event.minT, minT)
  end

  -- Create the combined event
  local combinedEvent = {
    x = averageX,
    z = averageZ,
    metal = totalMetal,
    energy = totalEnergy,
    maxT = maxT,
    minT = minT,
    n = totalSubEvents
  }

  return combinedEvent
end

local function scaleText(size, distance)
  return size * config.distanceScaleFactor / distance
end

local function getCameraDistance()
  local cameraState = SpringGetCameraState()
  return cameraState.height or cameraState.dist or cameraState.py or (config.cameraThreshold - 1)
end

local function getDrawLocation()
  if SpringIsGUIHidden() then
    return nil
  end

  local dist = getCameraDistance()
  if dist < config.cameraThreshold then
    return config.nearCameraMode
  else
    return config.farCameraMode
  end
end

local function clamp(min, max, num)
  if (num < min) then
    return min
  elseif (num > max) then
    return max
  end
  return num
end

local function rgbToColorCode(color, a)
  local rs = clamp(0, 255, 255 * color[1])
  local gs = clamp(0, 255, 255 * color[2])
  local bs = clamp(0, 255, 255 * color[3])
  local as = clamp(0, 255, 255 * a)
  local oas = clamp(0, 255, 255 * (a * 1.1))
  return "\254" .. string.char(rs) .. string.char(gs) .. string.char(bs) .. string.char(as) .. string.char(0) .. string.char(0) .. string.char(0) .. string.char(oas)
end

local function stripColorCodes(str)
  str = str:gsub("\254........", "")
  str = str:gsub("\255...", "")
  return str
end

local SI_PREFIXES_LOG1K = {
  [10] = "Q",
  [9] = "R",
  [8] = "Y",
  [7] = "Z",
  [6] = "E",
  [5] = "P",
  [4] = "T",
  [3] = "G",
  [2] = "M",
  [1] = "k",
  [0] = "",
  [-1] = "m",
  [-2] = "μ",
  [-3] = "n",
  [-4] = "p",
  [-5] = "f",
  [-6] = "a",
  [-7] = "z",
  [-8] = "y",
  [-9] = "r",
  [-10] = "q",
}

local function toEngineeringNotation(number)
  if number == 0 then
    return "0"
  end

  local sign = 1
  if number < 0 then
    number = number * -1
    sign = -1
  end

  local log1k = math.floor(math.log(number) / math.log(1000))
  local prefix = SI_PREFIXES_LOG1K[log1k]
  if prefix == nil then
    return nil
  end

  number = number / math.pow(1000, log1k)
  local precision = 2 - math.floor(math.log10(number))
  local str = string.format("%." .. precision .. "f", sign * number)

  if string.find(str, "%.") ~= nil then
    local i = string.len(str)
    while i > 0 do
      local c = string.sub(str, i, i)
      if c == "0" then
        i = i - 1
      elseif c == "." then
        i = i - 1
        break
      else
        break
      end
    end
    str = string.sub(str, 1, i)
  end

  return str .. prefix
end

local function DrawBattleText()
  if not isGameStarted then
    return
  end

  local cameraState = SpringGetCameraState()
  local events = spatialHash:allEvents()
  local currentFrame = SpringGetGameFrame()

  local myTeamID = SpringGetMyTeamID()
  local myAllyTeamID = SpringGetTeamAllyTeamID(myTeamID)

  local currentFontSize = config.fontSize

  if drawLocation == "ScreenEffects" then
    local cameraDistance = getCameraDistance()
    local boostSize = mathMax(0, cameraDistance - config.cameraThreshold) * config.farCameraTextBoost
    currentFontSize = scaleText(currentFontSize, cameraDistance - boostSize)
  end

  for _, event in ipairs(events) do
    local ex, ey, ez = event.x, SpringGetGroundHeight(event.x, event.z), event.z
    if SpringIsSphereInView(ex, ey, ez, 300) then
      -- generate text for the event
      local eventAge = (currentFrame - event.maxT) / (config.eventTimeout * 30) -- fraction of total lifetime left
      local alpha = config.maxTextAlpha * (1 - mathMin(1, eventAge * eventAge * eventAge * eventAge)) -- fade faster as it gets older

      local metalDelta = 0
      for key, value in pairs(event.metal) do
        -- show my allyteam metal lost as negative and any other allyteam as positive
        if key == myAllyTeamID then
          metalDelta = metalDelta - value
        else
          metalDelta = metalDelta + value
        end
      end

      local energyDelta = 0
      for key, value in pairs(event.energy) do
        -- show my allyteam energy lost as negative and any other allyteam as positive
        if key == myAllyTeamID then
          energyDelta = energyDelta - value
        else
          energyDelta = energyDelta + value
        end
      end

      local rate = false
      if config.showRates and (event.maxT - event.minT) > 30 * config.eventTimeout then
        -- show resource rate instead of total change
        rate = true
        energyDelta = energyDelta / ((currentFrame - event.minT) / 30)
        metalDelta = metalDelta / ((currentFrame - event.minT) / 30)
      end

      local function deltaText(value)
        local sign = "+"
        local color = config.positiveTextColor
        if value < 0 then
          sign = ""
          color = config.negativeTextColor
        end

        return rgbToColorCode(color, alpha) .. sign .. toEngineeringNotation(mathRound(value))
      end

      local function drawText(text, fontSize)
        if config.textMode == "gl" then
          local textWithoutColor = stripColorCodes(text)
          local outlineOffset = fontSize * 0.05

          -- draw text outline
          glColor(0, 0, 0, alpha * 0.5)
          glText(textWithoutColor, -outlineOffset, -outlineOffset, fontSize, "cd")
          glText(textWithoutColor, -outlineOffset, outlineOffset, fontSize, "cd")
          glText(textWithoutColor, outlineOffset, -outlineOffset, fontSize, "cd")
          glText(textWithoutColor, outlineOffset, outlineOffset, fontSize, "cd")

          -- draw actual text
          glText(text, 0, 0, fontSize, "cd")
        elseif config.textMode == "lua" then
          font:Print(text, 0, 0, fontSize, "cdo")
        end
      end

      local combinedDeltaText = deltaText(metalDelta + energyDelta / config.conversionRatio)
        .. rgbToColorCode(config.combinedTextColor, alpha * 0.9)
        .. "ᵯ"

      local metalDeltaText = deltaText(metalDelta)
        .. rgbToColorCode(config.metalTextColor, alpha * 0.9)
        .. "m"
      local energyDeltaText = deltaText(energyDelta)
        .. rgbToColorCode(config.energyTextColor, alpha * 0.9)
        .. "e"

      if rate then
        combinedDeltaText = combinedDeltaText .. "/s"
        metalDeltaText = metalDeltaText .. "/s"
        energyDeltaText = energyDeltaText .. "/s"
      end

      -- draw the text
      glPushMatrix()

      if drawLocation == "ScreenEffects" then
        glTranslate(SpringWorldToScreenCoords(ex, ey, ez))
      else
        glTranslate(ex, ey, ez)

        glRotate(-90, 1, 0, 0)
        if cameraState.flipped == 1 then
          -- only applicable in ta camera
          glRotate(180, 0, 0, 1)
        elseif cameraState.mode == 2 then
          -- spring camera
          local rx, ry, rz = SpringGetCameraRotation()
          glRotate(-180 * ry / mathPi, 0, 0, 1)
        end
      end

      if config.resourceMode == "metal" then
        drawText(metalDeltaText, currentFontSize)
      elseif config.resourceMode == "energy" then
        drawText(energyDeltaText, currentFontSize)
      elseif config.resourceMode == "both" then
        drawText(metalDeltaText, currentFontSize)
        drawText("\n" .. energyDeltaText, 0.6 * currentFontSize)
      elseif config.resourceMode == "combined" then
        drawText(combinedDeltaText, currentFontSize)
      end

      glPopMatrix()
    end
  end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
  if ignoreUnitDestroyed[unitID] then
    ignoreUnitDestroyed[unitID] = nil
    return
  end

  local _, _, _, _, buildProgress = SpringGetUnitHealth(unitID)
  local allyTeamID = SpringGetTeamAllyTeamID(unitTeam)
  local x, y, z = SpringGetUnitPosition(unitID)
  local gameTime = SpringGetGameFrame()

  local metal = UnitDefs[unitDefID].metalCost * buildProgress
  local energy = UnitDefs[unitDefID].energyCost * buildProgress

  if metal < 1 and energy < 1 then
    return
  end

  local event = {
    x = x, -- x coordinate of the event
    z = z, -- z coordinate of the event
    maxT = gameTime, -- game time (in frames) when the event happened
    minT = gameTime, -- game time (in frames) when the event happened
    metal = { -- the metal lost in the event, by allyteam that lost the metal
      [allyTeamID] = metal
    },
    energy = { -- the metal lost in the event, by allyteam that lost the metal
      [allyTeamID] = energy
    },
    n = 1 -- how many events have been combined into this one
  }

  -- combine with nearby events if necessary
  local nearbyEvents = spatialHash:getNearbyEvents(x, z, config.searchRadius)
  local combinedEvent = event
  if #nearbyEvents > 0 then
    table.insert(nearbyEvents, event)
    combinedEvent = combineEvents(nearbyEvents)

    for _, nearbyEvent in ipairs(nearbyEvents) do
      spatialHash:removeEvent(nearbyEvent)
    end
  end

  spatialHash:addEvent(combinedEvent)
end

function widget:GameFrame(frame)
  if not isGameStarted then
    isGameStarted = true

    -- initialization for when game actually starts
    widget:ViewResize()
  end

  if frame % config.eventTimeoutCheckPeriod == 0 then
    local oldEvents = spatialHash:allEvents(
      function(event)
        return event.maxT < frame - (config.eventTimeout * 30)
      end
    )

    for _, event in ipairs(oldEvents) do
      spatialHash:removeEvent(event)
    end
  end
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer)
  if UnitDefs[unitDefID].canFly and SpringGetUnitMoveTypeData(unitID).aircraftState == "crashing" then
    widget:UnitDestroyed(unitID, unitDefID, unitTeam, nil, nil, nil)
    ignoreUnitDestroyed[unitID] = true
  end
end

local function initializeFont()
  --(file, size, outlineSize, outlineStrength)
  font = WG['fonts'].getFont("fonts/" .. Spring.GetConfigString("bar_font2", "Exo2-SemiBold.otf"), nil, 1.2, 1.1)
end

function widget:ViewResize()
  initializeFont()
end

function widget:Update(dt)
  drawLocation = getDrawLocation()
end

local RESOURCE_MODES = { "metal", "energy", "both", "combined" }

local OPTION_SPECS = {
  {
    configVariable = "searchRadius",
    name = "Event Combine Distance",
    description = "Maximum distance at which events can be combined",
    type = "slider",
    min = 100,
    max = 2000,
    step = 50,
  },
  {
    configVariable = "eventTimeout",
    name = "Event Timeout",
    description = "How long events stay visible if they haven't changed (seconds)",
    type = "slider",
    min = 5,
    max = 120,
    step = 5,
  },
  {
    configVariable = "fontSize",
    name = "Text Size",
    description = "Font size for event text",
    type = "slider",
    min = 10,
    max = 200,
    step = 5,
  },
  {
    configVariable = "maxTextAlpha",
    name = "Text Opacity",
    description = "Initial opacity for event text (text starts at this opacity, and fades over time if it remains unchanged)",
    type = "slider",
    min = 0.1,
    max = 1,
    step = 0.1,
  },
  {
    configVariable = "resourceMode",
    name = "Resource Mode",
    description = "How to display each resource",
    type = "select",
    options = RESOURCE_MODES,
  },
  {
    configVariable = "showRates",
    name = "Show Rates",
    description = "For events that have existed for a long time, show the resource change rate, instead of total change",
    type = "bool",
  }
}

local function getOptionId(option)
  return "battle_resource_tracker__" .. option.configVariable
end

local function getWidgetName()
  return "Battle Resource Tracker"
end

local function getOptionValue(option)
  if option.type == "slider" then
    return config[option.configVariable]
  elseif option.type == "select" then
    -- we have text, we need index
    for i, v in ipairs(option.options) do
      if config[option.configVariable] == v then
        return i
      end
    end
  end
end

local function setOptionValue(optionSpec, value)
  if optionSpec.type == "slider" then
    config[optionSpec.configVariable] = value
  elseif optionSpec.type == "bool" then
    config[optionSpec.configVariable] = value
  elseif optionSpec.type == "select" then
    -- we have index, we need text
    config[optionSpec.configVariable] = optionSpec.options[value]
  end
end

local function createOnChange(option)
  return function(i, value, force)
    setOptionValue(option, value)
  end
end

function widget:Initialize()
  if WG['options'] ~= nil then
    WG['options'].addOptions(map(OPTION_SPECS, function(option)
      local tempOption = table.copy(option)
      tempOption.configVariable = nil
      tempOption.id = getOptionId(option)
      tempOption.widgetname = getWidgetName()
      tempOption.value = getOptionValue(option)
      tempOption.onchange = createOnChange(option)
      return tempOption
    end))
  end
end

function widget:Shutdown()
  if WG['options'] ~= nil then
    WG['options'].removeOptions(map(OPTION_SPECS, getOptionId))
  end
end

function widget:GetConfigData()
  local result = {}
  for _, option in ipairs(OPTION_SPECS) do
    result[option.configVariable] = getOptionValue(option)
  end
  return result
end

function widget:SetConfigData(data)
  for _, option in ipairs(OPTION_SPECS) do
    local configVariable = option.configVariable
    if data[configVariable] ~= nil then
      setOptionValue(option, data[configVariable])
    end
  end
end

-- draw functions

function widget:DrawPreDecals()
  if drawLocation == "PreDecals" then
    DrawBattleText()
  end
end

function widget:DrawWorldPreUnit()
  if drawLocation == "WorldPreUnit" then
    DrawBattleText()
  end
end

function widget:DrawWorld()
  if drawLocation == "World" then
    DrawBattleText()
  end
end

function widget:DrawScreenEffects()
  if drawLocation == "ScreenEffects" then
    DrawBattleText()
  end
end