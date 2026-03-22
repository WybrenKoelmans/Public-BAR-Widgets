-- Discord: https://discord.com/channels/549281623154229250/1203485910512173096/1203485910512173096
-- Gist: https://gist.github.com/tetrisface/2f99f5a5b179e3ac42e7e63825880713

if not Spring.Utilities.Gametype.IsRaptors() and not Spring.Utilities.Gametype.IsScavengers() then
	return false
end

function widget:GetInfo()
	return {
		name = 'Raptor Stats Panel With Eco Attraction',
		desc = 'Shows statistics and progress when fighting vs Raptors',
		author = 'quantum, tetrisface',
		date = 'May 04, 2008',
		license = 'GNU GPL, v2 or later',
		layer = -9,
		enabled = true,
		gist = 'https://gist.githubusercontent.com/tetrisface/2f99f5a5b179e3ac42e7e63825880713/raw/gui_raptor_panel_aggro.lua',
		version = 2
	}
end

VFS.Include('luaui/Headers/keysym.h.lua')
local panelTexture = ':n:LuaUI/Images/raptorpanel.tga'
local I18N = Spring.I18N
local isRaptors = Spring.Utilities.Gametype.IsRaptors()
local useWaveMsg = isRaptors and VFS.Include('LuaRules/Configs/raptor_spawn_defs.lua').useWaveMsg or false
local modOptions = Spring.GetModOptions()
local nBosses = modOptions.raptor_queen_count
local fontfile2 = 'fonts/' .. Spring.GetConfigString('bar_font2', 'Exo2-SemiBold.otf')
local bossDefName =
	isRaptors and ('raptor_queen_' .. modOptions.raptor_difficulty) or
	('scavengerbossv4_' .. modOptions.scav_difficulty .. '_scav')
local totalBossHealth =
	UnitDefNames[bossDefName] and UnitDefs[UnitDefNames[bossDefName].id] and UnitDefs[UnitDefNames[bossDefName].id].health or
	(1250000 * 1.5)

local rules = {
	'raptorDifficulty',
	'raptorGracePeriod',
	'scavBossAnger',
	'raptorQueenAnger',
	'RaptorQueenAngerGain_Aggression',
	'RaptorQueenAngerGain_Base',
	'RaptorQueenAngerGain_Eco',
	'raptorQueenHealth',
	'raptorQueensKilled',
	'raptorQueenTime',
	'raptorTechAnger'
}

local nilDefaultRules = {
	['raptorQueensKilled'] = true
}

local colors = {
	{1.000000, 0.783599, 0.109804}, -- yellow_light
	{0.929830, 0.521569, 0.352523}, -- orange_light
	{0.920358, 0.533527, 0.526701}, -- red_light
	{0.899288, 0.539928, 0.713886}, -- magenta_light
	{0.708966, 0.718865, 0.883190}, -- violet_light
	{0.468691, 0.724225, 0.903858}, -- blue_light
	{0.362407, 0.833672, 0.798029}, -- cyan_light
	{0.869282, 1.000000, 0.000000}, -- green_light
	{0.435189, 0.160785, 0.047164}, -- orange_dark
	{0.553861, 0.101186, 0.093198}, -- red_dark
	{0.087730, 0.320904, 0.484819}, -- blue_dark
	{0.419, 0.294, 0.580}, -- lavender_dark
	{0.180, 0.360, 0.278}, -- forest_dark
	{0.549, 0.270, 0.160}, -- clay_dark
	{0.208, 0.380, 0.388}, -- steel_dark
	{0.470, 0.360, 0.470}, -- mauve_dark
	{0.388, 0.321, 0.156}, -- brass_dark
	{0.709804, 0.537255, 0.000000}, -- yellow
	{0.796078, 0.294118, 0.086275}, -- orange
	{0.862745, 0.196078, 0.184314}, -- red
	{0.827451, 0.211765, 0.509804}, -- magenta
	{0.423529, 0.443137, 0.768627}, -- violet
	{0.149020, 0.545098, 0.823529}, -- blue
	{0.164706, 0.631373, 0.596078}, -- cyan
	{0.521569, 0.600000, 0.000000} -- green
}

local panelFontSize = 14
local waveFontSize = 36
local panelScale = 1
local screenScale = 1
local w = 300
local h = 210
local panelMarginX = 30
local bossInfoMarginX = panelMarginX - 15
local bossInfoSubLabelMarginX = bossInfoMarginX + 35
local panelMarginY = 40
local panelSpacingY = 5
local stageGrace = 0
local stageMain = 1
local stageBoss = 2
local waveSpacingY = 7
local waveSpeed = 0.1

local font, font2, font3
local messageArgs, marqueeMessage
local refreshMarqueeMessage = false
local showMarqueeMessage = false
local displayList
local guiPanel
local updatePanel
local hasRaptorEvent = false
local bossToastTimer = Spring.GetTimer()

local vsx, vsy = Spring.GetViewGeometry()
local viewSizeX, viewSizeY = 0, 0
local x1 = 0
local y1 = 0
local isMovingWindow
local isAboveBossInfo = false

local waveCount = 0
local waveTime
local gameInfo = {}
local resistancesTable = {}
local currentlyResistantTo = {}
local currentlyResistantToNames = {}
local playerEcoAttractionsRaw = {}
local playerEcoAttractionsRender = {}
local teamIDs = {}
local raptorsTeamID
local scavengersTeamID
local isExpanded = false
local nPanelRows
local bossInfo
local recentlyKilledQueens = {}

local cachedPlayerNames
if not cachedPlayerNames then
	cachedPlayerNames = {}
end

local isObject = {}
for udefID, def in ipairs(UnitDefs) do
	if def.modCategories['object'] or def.customParams.objectify then
		isObject[udefID] = true
	end
end

local function EcoValueDef(unitDef)
	if (unitDef.canMove and not (unitDef.customParams and unitDef.customParams.iscommander)) or isObject[unitDef.name] then
		return 0
	end

	local ecoValue = 1
	if unitDef.energyMake then
		ecoValue = ecoValue + unitDef.energyMake
	end
	if unitDef.energyUpkeep and unitDef.energyUpkeep < 0 then
		ecoValue = ecoValue - unitDef.energyUpkeep
	end
	if unitDef.windGenerator then
		ecoValue = ecoValue + unitDef.windGenerator * 0.75
	end
	if unitDef.tidalGenerator then
		ecoValue = ecoValue + unitDef.tidalGenerator * 15
	end
	if unitDef.extractsMetal and unitDef.extractsMetal > 0 then
		ecoValue = ecoValue + 200
	end

	if unitDef.customParams then
		if unitDef.customParams.energyconv_capacity then
			ecoValue = ecoValue + tonumber(unitDef.customParams.energyconv_capacity) / 2
		end

		-- Decoy fusion support
		if unitDef.customParams.decoyfor == 'armfus' then
			ecoValue = ecoValue + 1000
		end

		-- Make it extra risky to build T2 eco
		if unitDef.customParams.techlevel and tonumber(unitDef.customParams.techlevel) > 1 then
			ecoValue = ecoValue * tonumber(unitDef.customParams.techlevel) * 2
		end

		-- Anti-nuke - add value to force players to go T2 economy, rather than staying T1
		if unitDef.customParams.unitgroup == 'antinuke' or unitDef.customParams.unitgroup == 'nuke' then
			ecoValue = 1000
		end
	end

	return ecoValue
end

local defIDsEcoValues = {}
for unitDefID, unitDef in pairs(UnitDefs) do
	local ecoValue = EcoValueDef(unitDef) or 0
	if ecoValue > 0 then
		defIDsEcoValues[unitDefID] = ecoValue
	end
end

local function PlayerName(teamID)
	local playerName = ''

	local playerList = Spring.GetPlayerList(teamID)
	if (not playerList or #playerList == 0) and cachedPlayerNames[teamID] then
		playerName = cachedPlayerNames[teamID]
	elseif #playerList > 1 then
		for _, player in ipairs(playerList) do
			if player then
				playerName = playerName .. (#playerName > 0 and ' & ' or '') .. select(1, Spring.GetPlayerInfo(player))
			end
		end
	elseif #playerList == 1 then
		playerName = select(1, Spring.GetPlayerInfo(playerList[1]))
	else
		_, playerName = Spring.GetAIInfo(teamID)
	end

	if playerName and playerName ~= '' then
		cachedPlayerNames[teamID] = playerName
	end

	return playerName
end

local function PlayerEcoAttractionsAggregation()
	local myTeamId = Spring.GetMyTeamID()
	local playerEcoAttractions = {}
	local sum = 0
	local nPlayerAttractions = 0

	for i = 1, #teamIDs do
		local teamID = teamIDs[i]
		local playerName = PlayerName(teamID)

		if playerName and not (playerName:find('Raptors') or playerName:find('Scavengers')) then
			local ecoAttractionValue = playerEcoAttractionsRaw[teamID] or 0
			ecoAttractionValue = ecoAttractionValue > 0 and ecoAttractionValue or 0

			sum = sum + ecoAttractionValue
			nPlayerAttractions = nPlayerAttractions + 1
			playerEcoAttractions[nPlayerAttractions] = {
				value = ecoAttractionValue,
				name = playerName,
				teamID = teamID,
				me = myTeamId == teamID,
				forced = false
			}
		end
	end
	return playerEcoAttractions, sum
end

local function RaptorStage(currentTime)
	local stage = stageGrace
	if (currentTime and currentTime or Spring.GetGameSeconds()) > gameInfo.raptorGracePeriod then
		if (isRaptors and (gameInfo.raptorQueenAnger < 100)) or (not isRaptors and (gameInfo.scavBossAnger < 100)) then
			stage = stageMain
		else
			stage = stageBoss
		end
	end
	return stage
end

local function SortValueDesc(a, b)
	return a.value > b.value
end

local function Interpolate(value, inMin, inMax, outMin, outMax)
	-- Ensure the value is within the specified range
	value = (value < inMin) and inMin or ((value > inMax) and inMax or value)

	-- Calculate the interpolation
	local t = (value - inMin) / (inMax - inMin)
	return outMin + t * (outMax - outMin)
end

local function UpdatePlayerEcoAttractionRender()
	local maxRows =
		isRaptors and ((RaptorStage() == stageGrace and 4 or 3) + (Spring.GetMyTeamID() == raptorsTeamID and 1 or 0)) or 6
	local playerEcoAttractions, sum = PlayerEcoAttractionsAggregation()

	if sum == 0 then
		return
	end

	table.sort(playerEcoAttractions, SortValueDesc)

	-- add string formatting, forced current player result and limit results
	playerEcoAttractionsRender = {}
	local nPlayerEcoAttractionsRender = 0
	local nPlayerEcoAttractions = #playerEcoAttractions
	local playerEcoAttraction
	for i = 1, nPlayerEcoAttractions do
		playerEcoAttraction = playerEcoAttractions[i]

		-- Always include current player
		if playerEcoAttraction.me or nPlayerEcoAttractionsRender < maxRows then
			if playerEcoAttraction.me then
				maxRows = maxRows + 1
			end
			-- Current player added as last, so forced
			if playerEcoAttraction.me and i > nPlayerEcoAttractionsRender + 1 then
				playerEcoAttraction.forced = true
			end
			playerEcoAttraction.multiple = nPlayerEcoAttractions * playerEcoAttraction.value / sum
			playerEcoAttraction.fraction = playerEcoAttraction.value * 100 / sum
			playerEcoAttraction.multipleString = string.format('%.1fX', playerEcoAttraction.multiple)
			playerEcoAttraction.fractionString = string.format(' (%.0f%%)', playerEcoAttraction.fraction)
			local greenBlue = 1
			local alpha = 1
			if playerEcoAttraction.multiple > 1.7 then
				greenBlue = Interpolate(playerEcoAttraction.multiple, 1.7, 6, 0.5, 0.3)
			elseif playerEcoAttraction.multiple > 1.2 then
				greenBlue = Interpolate(playerEcoAttraction.multiple, 1.2, 1.7, 0.8, 0.5)
			elseif playerEcoAttraction.multiple < 0.8 then
				alpha = 0.8
			end
			playerEcoAttraction.color = {
				red = 1,
				green = greenBlue,
				blue = greenBlue,
				alpha = playerEcoAttraction.forced and 0.6 or alpha
			}
			nPlayerEcoAttractionsRender = nPlayerEcoAttractionsRender + 1
			playerEcoAttractionsRender[nPlayerEcoAttractionsRender] = playerEcoAttraction
		end
	end
end

local function updatePos(x, y)
	local x0 = (viewSizeX * 0.94) - (w * panelScale) / 2
	local y0 = (viewSizeY * 0.89) - (h * panelScale) / 2
	x1 = x0 < x and x0 or x
	y1 = y0 < y and y0 or y

	updatePanel = true
end

local function PanelRow(n)
	return h - panelMarginY - (n - 1) * (panelFontSize + panelSpacingY)
end

local function WaveRow(n)
	return n * (waveFontSize + waveSpacingY)
end

local function CutStringAtPixelWidth(text, width)
	while font:GetTextWidth(text) * panelFontSize > width and text:len() > 0 do
		text = text:sub(1, -2)
	end
	return text
end

local function DrawPlayerAttractions(stage)
	local isMultiBosses = nBosses > 1 and gameInfo.raptorQueensKilled
	-- stageMain is with the two angers % and the timer (2 rows)
	local row = isRaptors and ((stage == stageMain or (stage == stageBoss and isMultiBosses)) and 3 or 2) or 1
	font:Print((isRaptors and 'Player' or 'Raptor') .. ' Eco Attractions:', panelMarginX, PanelRow(row), panelFontSize)
	for i = 1, #playerEcoAttractionsRender do
		local playerEcoAttraction = playerEcoAttractionsRender[i]
		font:SetTextColor(
			playerEcoAttraction.color.red,
			playerEcoAttraction.color.green,
			playerEcoAttraction.color.blue,
			playerEcoAttraction.color.alpha
		)

		local namePosX = i >= 7 - row and 80 or panelMarginX + 11
		local attractionFractionStringWidth =
			math.floor(0.5 + font:GetTextWidth(playerEcoAttraction.fractionString) * panelFontSize)
		local valuesRightX = panelMarginX + 220
		local valuesLeftX = panelMarginX + 145
		local rowY = PanelRow(row + i)
		font:Print(CutStringAtPixelWidth(playerEcoAttraction.name, valuesLeftX - namePosX - 2), namePosX, rowY, panelFontSize)
		font:Print(playerEcoAttraction.multipleString, valuesLeftX, rowY, panelFontSize)
		font:Print(playerEcoAttraction.fractionString, valuesRightX - attractionFractionStringWidth, rowY, panelFontSize)
	end
	font:SetTextColor(1, 1, 1, 1)
end

local function printPanel(text, x, y, size)
	if not size then
		size = panelFontSize
	end
	font:Print(text, x, y, size)
end

local function printBossInfo(text, x, y, size, option)
	if not size then
		size = panelFontSize
	end
	if not option then
		option = 'o'
	end
	font:Print(text or '', x, y, size, option)
end

local function CreatePanelDisplayList()
	local currentTime = Spring.GetGameSeconds()
	local stage = RaptorStage(currentTime)

	gl.PushMatrix()
	gl.Translate(x1, y1, 0)
	gl.Scale(panelScale, panelScale, 1)
	gl.CallList(displayList)

	-- Safety check for font
	if not font then
		if WG['fonts'] then
			font = WG['fonts'].getFont(nil, nil, 0.4, 1.76)
		else
			font = gl.LoadFont('fonts/FreeSansBold.otf', 16, 2, 1.5)
		end
	end

	font:Begin()
	font:SetTextColor(1, 1, 1, 1)
	if stage == stageGrace and isRaptors then
		printPanel(I18N('ui.raptors.gracePeriod', {time = ''}), panelMarginX, PanelRow(1))
		local timeText = string.formatTime(((currentTime - gameInfo.raptorGracePeriod) * -1) - 0.5)
		printPanel(timeText, panelMarginX + 220 - font:GetTextWidth(timeText) * panelFontSize, PanelRow(1))
	elseif stage == stageMain and isRaptors then
		local hatchEvolutionString =
			I18N(
			'ui.raptors.queenAngerWithTech',
			{
				anger = math.min(100, math.floor(0.5 + gameInfo.raptorQueenAnger)),
				techAnger = gameInfo.raptorTechAnger
			}
		)
		printPanel(
			hatchEvolutionString,
			panelMarginX,
			PanelRow(1),
			panelFontSize - Interpolate(font:GetTextWidth(hatchEvolutionString) * panelFontSize, 234, 244, 0, 0.59)
		)

		printPanel(I18N('ui.raptors.queenETA', {count = nBosses, time = ''}):gsub('%.', ''), panelMarginX, PanelRow(2))
		local gain =
			gameInfo.RaptorQueenAngerGain_Base + gameInfo.RaptorQueenAngerGain_Aggression + gameInfo.RaptorQueenAngerGain_Eco
		local time = string.formatTime((100 - gameInfo.raptorQueenAnger) / gain)
		printPanel(time, panelMarginX + 200 - font:GetTextWidth(time:gsub('(.*):.*$', '%1')) * panelFontSize, PanelRow(2))

		if #currentlyResistantToNames > 0 then
			currentlyResistantToNames = {}
			currentlyResistantTo = {}
		end
	elseif stage == stageBoss then
		if isRaptors then
			printPanel(I18N('ui.raptors.queenHealth', {count = nBosses, health = ''}):gsub('%%', ''), panelMarginX, PanelRow(1))
			local healthText = tostring(gameInfo.raptorQueenHealth)
			printPanel(
				gameInfo.raptorQueenHealth .. '%',
				panelMarginX + 210 - font:GetTextWidth(healthText) * panelFontSize,
				PanelRow(1)
			)

			if nBosses > 1 and gameInfo.raptorQueensKilled then
				printPanel(
					Spring.I18N('ui.raptors.queensKilled', {nKilled = gameInfo.raptorQueensKilled, nTotal = nBosses}),
					panelMarginX,
					PanelRow(2)
				)
			end
		end

		if bossInfo then
			printBossInfo((isRaptors and 'Queen' or 'Boss') .. ' resistances: (Ctrl+B Expands)', bossInfoMarginX, PanelRow(11))
			local row = 11
			for i, resistance in ipairs(bossInfo.resistances) do
				row = row + 1
				printBossInfo(resistance.name, bossInfoMarginX + 10, PanelRow(row))
				local resistanceString = isAboveBossInfo and resistance.stringAbsolute or resistance.stringPercent
				printBossInfo(
					resistanceString,
					bossInfoSubLabelMarginX + bossInfo.labelMaxLength + 40 - font:GetTextWidth(resistanceString) * panelFontSize,
					PanelRow(row),
					nil,
					'o'
				)
				if not isExpanded and i > 3 then
					break
				end
			end

			row = row + 1

			printBossInfo(
				'Player ' ..
					(isRaptors and 'Queen' or 'Boss') .. ' Damage: (' .. (isAboveBossInfo and 'absolute' or 'relative') .. ')',
				bossInfoMarginX,
				PanelRow(row)
			)
			for i, damage in ipairs(bossInfo.playerDamages) do
				row = row + 1
				printBossInfo(damage.name, bossInfoMarginX + 10, PanelRow(row))
				local damageString = isAboveBossInfo and damage.stringAbsolute or damage.stringRelative
				printBossInfo(
					damageString,
					bossInfoSubLabelMarginX + bossInfo.labelMaxLength + 40 - font:GetTextWidth(damageString) * panelFontSize,
					PanelRow(row),
					nil,
					'o'
				)
				if not isExpanded and i > 5 then
					break
				end
			end

			row = row + 1

			printBossInfo('Healths:', bossInfoMarginX, PanelRow(row))
			row = row + 1
			local rowWidthPixels = bossInfoMarginX + 10
			local maxRowWidthPixels = w * panelScale - 50
			local healthH = panelFontSize + 0.4

			-- Safety check for font3
			if not font3 then
				if WG['fonts'] then
					font3 = WG['fonts'].getFont(nil, nil, 0.3, 3)
				else
					font3 = gl.LoadFont('fonts/FreeSansBold.otf', 14, 2, 1.5)
				end
			end

			for _, health in ipairs(bossInfo.healths) do
				local newRowWidthPixels = rowWidthPixels + font3:GetTextWidth(health.string) * panelFontSize
				if newRowWidthPixels > maxRowWidthPixels then
					row = row + 1
					rowWidthPixels = bossInfoMarginX + 10
				end
				font3:SetTextColor(health.color[1], health.color[2], health.color[3], 1)
				font3:Print(health.string, rowWidthPixels, PanelRow(row), healthH, 'o')
				rowWidthPixels = rowWidthPixels + font3:GetTextWidth('XXX   ') * panelFontSize
			end
			font3:SetTextColor(1, 1, 1, 1)
			nPanelRows = row
		end
	end

	DrawPlayerAttractions(stage)

	if isRaptors then
		local endless = ''
		if modOptions.raptor_endless then
			endless = ' (' .. I18N('ui.raptors.difficulty.endless') .. ')'
		end
		local difficultyCaption = I18N('ui.raptors.difficulty.' .. modOptions.raptor_difficulty)
		font:Print(I18N('ui.raptors.mode', {mode = difficultyCaption}) .. endless, 80, h - 170, panelFontSize)
	end
	font:End()

	gl.Texture(false)
	gl.PopMatrix()
end

local function getMarqueeMessage(raptorEventArgs)
	local messages = {}
	if raptorEventArgs.type == 'firstWave' then
		messages[1] = I18N('ui.raptors.firstWave1')
		messages[2] = I18N('ui.raptors.firstWave2')
	elseif raptorEventArgs.type == 'queen' then
		messages[1] = I18N('ui.raptors.queenIsAngry1', {count = nBosses})
		messages[2] = I18N('ui.raptors.queenIsAngry2')
	elseif raptorEventArgs.type == 'airWave' then
		messages[1] = I18N('ui.raptors.wave1', {waveNumber = raptorEventArgs.waveCount})
		messages[2] = I18N('ui.raptors.airWave1')
		messages[3] = I18N('ui.raptors.airWave2', {unitCount = raptorEventArgs.number})
	elseif raptorEventArgs.type == 'wave' then
		messages[1] = I18N('ui.raptors.wave1', {waveNumber = raptorEventArgs.waveCount})
		messages[2] = I18N('ui.raptors.wave2', {unitCount = raptorEventArgs.number})
	end

	refreshMarqueeMessage = false

	return messages
end

local function getResistancesMessage()
	local messages = {}
	messages[1] = I18N('ui.raptors.resistanceUnits', {count = nBosses})
	for i = 1, #resistancesTable do
		local attackerName = UnitDefs[resistancesTable[i]].name
		messages[i + 1] = I18N('units.names.' .. attackerName)
		currentlyResistantToNames[#currentlyResistantToNames + 1] = I18N('units.names.' .. attackerName)
	end
	resistancesTable = {}

	refreshMarqueeMessage = false

	return messages
end

function widget:DrawScreen()
	if updatePanel then
		if guiPanel then
			gl.DeleteList(guiPanel)
		end
		guiPanel = gl.CreateList(CreatePanelDisplayList)
		updatePanel = false
	end

	if guiPanel then
		gl.CallList(guiPanel)
	end

	if showMarqueeMessage then
		local t = Spring.GetTimer()

		local waveY = viewSizeY - Spring.DiffTimers(t, waveTime) * waveSpeed * viewSizeY
		if waveY > 0 then
			if refreshMarqueeMessage or not marqueeMessage then
				marqueeMessage = getMarqueeMessage(messageArgs)
			end

			-- Safety check for font2
			if not font2 then
				if WG['fonts'] then
					font2 = WG['fonts'].getFont(fontfile2)
				else
					font2 = gl.LoadFont('fonts/FreeSansBold.otf', 20, 2, 1.5)
				end
			end

			font2:Begin()
			font2:SetTextColor(1, 1, 1, 1)
			for i, message in ipairs(marqueeMessage) do
				font2:Print(message, viewSizeX / 2, waveY - (WaveRow(i) * screenScale), waveFontSize * screenScale, 'co')
			end
			font2:End()
		else
			showMarqueeMessage = false
			messageArgs = nil
			waveY = viewSizeY
		end
	elseif #resistancesTable > 0 then
		marqueeMessage = getResistancesMessage()
		waveTime = Spring.GetTimer()
		showMarqueeMessage = true
	end
end

local function UpdateRules()
	for i = 1, #rules do
		local rule = rules[i]
		gameInfo[rule] = Spring.GetGameRulesParam(rule) or (nilDefaultRules[rule] and nil or 0)
	end

	updatePanel = true
end

function RaptorEvent(raptorEventArgs)
	if
		raptorEventArgs.type == 'firstWave' or
			(raptorEventArgs.type == 'queen' and Spring.DiffTimers(Spring.GetTimer(), bossToastTimer) > 20)
	 then
		showMarqueeMessage = true
		refreshMarqueeMessage = true
		messageArgs = raptorEventArgs
		waveTime = Spring.GetTimer()
		if raptorEventArgs.type == 'queen' then
			bossToastTimer = Spring.GetTimer()
		end
	end

	if raptorEventArgs.type == 'queenResistance' then
		if raptorEventArgs.number then
			if not currentlyResistantTo[raptorEventArgs.number] then
				resistancesTable[#resistancesTable + 1] = raptorEventArgs.number
				currentlyResistantTo[raptorEventArgs.number] = true
			end
		end
	end

	if
		(raptorEventArgs.type == 'wave' or raptorEventArgs.type == 'airWave') and useWaveMsg and
			gameInfo.raptorQueenAnger <= 99
	 then
		waveCount = waveCount + 1
		raptorEventArgs.waveCount = waveCount
		showMarqueeMessage = true
		refreshMarqueeMessage = true
		messageArgs = raptorEventArgs
		waveTime = Spring.GetTimer()
	end
end

local function RegisterUnit(unitDefID, unitTeamID)
	if playerEcoAttractionsRaw[unitTeamID] then
		local ecoValue = defIDsEcoValues[unitDefID]
		if ecoValue and ecoValue > 0 then
			playerEcoAttractionsRaw[unitTeamID] = playerEcoAttractionsRaw[unitTeamID] + ecoValue
		end
	end
end

local function DeregisterUnit(unitDefID, unitTeamID)
	if playerEcoAttractionsRaw[unitTeamID] then
		playerEcoAttractionsRaw[unitTeamID] = playerEcoAttractionsRaw[unitTeamID] - (defIDsEcoValues[unitDefID] or 0)
	end
end

function widget:UnitCreated(_, unitDefID, unitTeamID)
	RegisterUnit(unitDefID, unitTeamID)
end

function widget:UnitGiven(_, unitDefID, unitTeam, oldTeam)
	RegisterUnit(unitDefID, unitTeam)
	DeregisterUnit(unitDefID, oldTeam)
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam)
	DeregisterUnit(unitDefID, unitTeam)

	if bossInfo then
		for _, health in ipairs(bossInfo.healths) do
			if health.id == unitID then
				recentlyKilledQueens[unitID] = true
				WG['ObjectSpotlight'].removeSpotlight('unit', 'me', unitID)
			end
		end
	end
end

function widget:Initialize()
	playerEcoAttractionsRaw = {}
	Spring.SendCommands('disablewidget Raptor Stats Panel')
	widget:ViewResize()

	-- Initialize fonts with proper error checking
	if WG['fonts'] then
		font = WG['fonts'].getFont(nil, nil, 0.4, 1.76)
		font2 = WG['fonts'].getFont(fontfile2)
		font3 = WG['fonts'].getFont(nil, nil, 0.3, 3)
	else
		-- Fallback if fonts widget is not available
		font = gl.LoadFont('fonts/FreeSansBold.otf', 16, 2, 1.5)
		font2 = gl.LoadFont('fonts/FreeSansBold.otf', 20, 2, 1.5)
		font3 = gl.LoadFont('fonts/FreeSansBold.otf', 14, 2, 1.5)
	end

	displayList =
		gl.CreateList(
		function()
			gl.Blending(true)
			gl.Color(1, 1, 1, 1)
			gl.Texture(panelTexture)
			gl.TexRect(0, 0, w, h)
		end
	)

	widgetHandler:RegisterGlobal('RaptorEvent', RaptorEvent)
	UpdateRules()
	viewSizeX, viewSizeY = gl.GetViewSizes()
	local x = math.abs(math.floor(viewSizeX - 320))
	local y = math.abs(math.floor(viewSizeY - 300)) - (Spring.Utilities.Gametype.IsScavengers() and 257 or 0)

	updatePos(x, y)

	teamIDs = Spring.GetTeamList()
	local tempTeamIDs = table.copy(teamIDs)
	for i = 1, #tempTeamIDs - 1 do
		local teamID = tempTeamIDs[i]
		local teamLuaAI = Spring.GetTeamLuaAI(teamID)
		if teamLuaAI then
			if string.find(teamLuaAI, 'Raptors') then
				raptorsTeamID = teamID
				table.remove(teamIDs, i)
			elseif string.find(teamLuaAI, 'Scavengers') then
				scavengersTeamID = teamID
				table.remove(teamIDs, i)
			end
		else
			playerEcoAttractionsRaw[teamID] = 0
		end
	end
	if raptorsTeamID == nil then
		raptorsTeamID = Spring.GetGaiaTeamID()
	end

	if scavengersTeamID == nil then
		scavengersTeamID = Spring.GetGaiaTeamID()
	end

	local allUnits = Spring.GetAllUnits()
	for i = 1, #allUnits do
		local unitID = allUnits[i]
		local unitDefID = Spring.GetUnitDefID(unitID)
		local unitTeamID = Spring.GetUnitTeam(unitID)
		if unitTeamID ~= raptorsTeamID then
			RegisterUnit(unitDefID, unitTeamID)
		end
	end
end

function widget:Shutdown()
	if hasRaptorEvent then
		Spring.SendCommands({'luarules HasRaptorEvent 0'})
	end

	if guiPanel then
		gl.DeleteList(guiPanel)
		guiPanel = nil
	end

	gl.DeleteList(displayList)
	gl.DeleteTexture(panelTexture)
	widgetHandler:DeregisterGlobal('RaptorEvent')
end

local function sortRawDamageDescNameAsc(a, b)
	if not a or not b then
		return false
	end
	if a.raw == b.raw and a.damage and b.damage then
		if a.damage == b.damage then
			return a.name < b.name
		end
		return a.damage > b.damage
	end
	return a.raw > b.raw
end

local function UpdateBossInfo()
	local bossInfoRaw = Spring.GetGameRulesParam('pveBossInfo')
	if not bossInfoRaw then
		return
	end
	bossInfoRaw = Json.decode(Spring.GetGameRulesParam('pveBossInfo'))
	bossInfo = {resistances = {}, playerDamages = {}, healths = {}, labelMaxLength = 0}

	local i = 0
	for defID, resistance in pairs(bossInfoRaw.resistances) do
		i = i + 1
		if resistance.percent >= 0.1 then
			local name = UnitDefs[tonumber(defID)].translatedHumanName
			if font:GetTextWidth(name) * panelFontSize > bossInfo.labelMaxLength then
				bossInfo.labelMaxLength = font:GetTextWidth(name) * panelFontSize
			end
			table.insert(
				bossInfo.resistances,
				{
					name = name,
					raw = resistance.percent,
					damage = resistance.damage,
					stringPercent = string.format('%.0f%%', resistance.percent * 100),
					stringAbsolute = string.formatSI(resistance.damage)
				}
			)
		end
	end
	table.sort(bossInfo.resistances, sortRawDamageDescNameAsc)

	for teamID, damage in pairs(bossInfoRaw.playerDamages) do
		local name = PlayerName(teamID)
		if font:GetTextWidth((name or '') .. 'XX') * panelFontSize > bossInfo.labelMaxLength then
			bossInfo.labelMaxLength = font:GetTextWidth((name or '') .. 'XX') * panelFontSize
		end
		damage = math.max(damage, 1)
		table.insert(
			bossInfo.playerDamages,
			{
				name = name,
				raw = damage,
				stringAbsolute = string.formatSI(damage),
				stringRelative = string.format('%.1fX', damage / totalBossHealth)
			}
		)
	end
	table.sort(bossInfo.playerDamages, sortRawDamageDescNameAsc)

	local screenOverflowX = x1 + bossInfo.labelMaxLength + bossInfoSubLabelMarginX + 36 - vsx
	x1 = screenOverflowX > 0 and x1 - screenOverflowX or x1

	for queenID, status in pairs(bossInfoRaw.statuses) do
		table.insert(
			bossInfo.healths,
			{
				id = tonumber(queenID),
				name = tonumber(queenID),
				raw = status.health / status.maxHealth,
				string = string.format('%.0f%%', (status.health / status.maxHealth) * 100),
				isDead = status.isDead
			}
		)
	end
	table.sort(
		bossInfo.healths,
		function(a, b)
			return a.id < b.id
		end
	)

	local colorsTemp = table.copy(colors)
	for _, health in ipairs(bossInfo.healths) do
		if #colorsTemp == 0 then
			colorsTemp = table.copy(colors)
		end
		health.color = table.remove(colorsTemp, 1)
	end

	for n = #bossInfo.healths, 1, -1 do
		local status = bossInfo.healths[n]
		if status and (status.isDead or status.raw == 0 or recentlyKilledQueens[status.id]) then
			table.remove(bossInfo.healths, n)
		end
	end
	table.sort(bossInfo.healths, sortRawDamageDescNameAsc)
end

function widget:GameFrame(n)
	if not hasRaptorEvent and n > 1 then
		Spring.SendCommands({'luarules HasRaptorEvent 1'})
		hasRaptorEvent = true
	end
	if n % 30 == 17 then
		UpdateRules()
		UpdatePlayerEcoAttractionRender()
		UpdateBossInfo()
	end
end

function widget:IsAbove(x, y)
	if not bossInfo or RaptorStage() ~= stageBoss or not nPanelRows then
		return
	end

	local bottomY = y1 + PanelRow(nPanelRows + 1)
	local wasAboveBossInfo = isAboveBossInfo
	isAboveBossInfo = x > x1 and x < x1 + (w * panelScale) and y < y1 and y > math.max(0, bottomY)

	if isAboveBossInfo then
		for _, health in ipairs(bossInfo.healths) do
			if not health.isDead and not recentlyKilledQueens[health.id] then
				WG['ObjectSpotlight'].addSpotlight(
					'unit',
					'me',
					health.id,
					{health.color[1], health.color[2], health.color[3], 1},
					{duration = 3}
				)
			end
		end
	end
	if isAboveBossInfo ~= wasAboveBossInfo then
		updatePanel = true
	end
end

function widget:MouseMove(_, _, dx, dy)
	if isMovingWindow then
		updatePos(x1 + dx, y1 + dy)
	end
end

local function isMouseWithinPanel(x, y)
	if not x or not y then
		x, y = Spring.GetMouseState()
	end
	return x > x1 and x < x1 + (w * panelScale) and y > y1 and y < y1 + (h * panelScale)
end

function widget:MousePress(x, y)
	if isMouseWithinPanel(x, y) then
		isMovingWindow = true
	end
	return isMovingWindow
end

function widget:MouseRelease()
	isMovingWindow = nil
end

function widget:ViewResize()
	vsx, vsy = Spring.GetViewGeometry()

	x1 = math.floor(x1 - viewSizeX)
	y1 = math.floor(y1 - viewSizeY)
	viewSizeX, viewSizeY = vsx, vsy
	screenScale = (0.75 + (viewSizeX * viewSizeY / 10000000))
	panelScale = screenScale * panelScale
	x1 = viewSizeX + x1 + ((x1 / 2) * (panelScale - 1))
	y1 = viewSizeY + y1 + ((y1 / 2) * (panelScale - 1))

	-- Reinitialize fonts on view resize
	if WG['fonts'] then
		font = WG['fonts'].getFont(nil, nil, 0.4, 1.76)
		font2 = WG['fonts'].getFont(fontfile2)
		font3 = WG['fonts'].getFont(nil, nil, 0.3, 3)
	end

	updatePanel = true
end

function widget:LanguageChanged()
	refreshMarqueeMessage = true
	updatePanel = true
end
local isCtrlDown = false

function widget:KeyPress(key, mods, isRepeat)
	if isRepeat then
		return
	end
	if key == KEYSYMS.B and mods.ctrl and not mods.shift and not mods.alt then
		isExpanded = not isExpanded
		updatePanel = true
		return
	end
	if mods.ctrl then
		isCtrlDown = true
	end
end

function widget:KeyRelease(key)
	if key == KEYSYMS.LCTRL then
		isCtrlDown = false
	end
end

-- on ctrl +mouse wheel up/down, change the scale of the panel (customScale)
function widget:MouseWheel(up, value)
	-- is mouse within panel
	if isCtrlDown and isMouseWithinPanel() then
		panelScale = panelScale + (up and 0.02 or -0.02)
		vsx, vsy = Spring.GetViewGeometry()

		-- Reinitialize fonts with proper error checking
		if WG['fonts'] then
			font = WG['fonts'].getFont(nil, nil, 0.4, 1.76)
			font2 = WG['fonts'].getFont(fontfile2)
			font3 = WG['fonts'].getFont(nil, nil, 0.3, 3)
		end

		viewSizeX, viewSizeY = vsx, vsy
		updatePanel = true
		return true
	end
	return false
end