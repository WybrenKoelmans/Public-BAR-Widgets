--- Patches gui_gridmenu.lua to add in cost per second and build time info (based on selected BP)
local function my_get_info()
	return {
		name = "Grid Menu with Costs/Second",
		desc = "(Version 1.0)\nA dynamically patched version of the Grid Menu that adds in cost per second and build time info",
		author = "Original buildmenu by Floris, grid by badosu and resopmok.\nCost/second by engolianth and zenfur.\nMaintained by ChrisFloofyKitsune.",
		date = "June 2024",
		license = "GNU GPL, v2 or later",
		layer = 0,
		enabled = false,
		handler = true,
	}
end

-------------------------------------------------------------------------------
--- Original Widget Loading
-------------------------------------------------------------------------------

local orig_text = VFS.LoadFile("LuaUI/Widgets/gui_gridmenu.lua")

local locals_to_make_accessors_for = {
	"activeCmd",
	"font2",
	"priceFontSize",
	"units",
	"drawCell",
	"showPrice",
	"cellPadding",
	"cellInnerSize",
	"isPregame",
	"startDefID",
	"formatPrice",
	"activeBuilder",
	"activeBuilderID",
	"refreshCommands",
	"hoveredRect",
}

for _, var_name in pairs(locals_to_make_accessors_for) do
	orig_text = orig_text .. '\nfunction get_' .. var_name .. '() return ' .. var_name .. ' end\n'
	orig_text = orig_text .. '\nfunction set_' .. var_name .. '(value) ' .. var_name .. ' = value end\n'
end

orig = loadstring(orig_text)
setfenv(orig, widget)
orig()

function widget:GetInfo()
	return my_get_info()
end

-------------------------------------------------------------------------------
--- Cached Values
-------------------------------------------------------------------------------
local spGetSelectedUnitsSorted = Spring.GetSelectedUnitsSorted
local spGetMouseState = Spring.GetMouseState
local math_floor = math.floor
local math_round = math.round

-------------------------------------------------------------------------------
--- Configuration
-------------------------------------------------------------------------------

local config_cost_per_second = {
	alwaysReturn = true,
	autoSelectFirst = true,
	useLabBuildMode = true,
	showCostPerSecond = false,
	showBuildTime = true,
	showDecimals = false,
	cursorInfo = true,
	cursorInfoSize = 1.5,
	cursorInfoOffset = 10,
}

local OPTION_COST_PER_SECOND_SPECS = {
	{
		configVariable = "alwaysReturn",
		name = Spring.I18N('ui.settings.option.gridmenu_alwaysreturn'),
		description = Spring.I18N('ui.settings.option.gridmenu_alwaysreturn_descr'),
		type = "bool",
		widgetApiFunction = 'setAlwaysReturn',
	},
	{
		configVariable = "autoSelectFirst",
		name = Spring.I18N('ui.settings.option.gridmenu_autoselectfirst'),
		description = Spring.I18N('ui.settings.option.gridmenu_autoselectfirst_descr'),
		type = "bool",
		widgetApiFunction = 'setAutoSelectFirst',
	},
	{
		configVariable = "useLabBuildMode",
		name = Spring.I18N('ui.settings.option.gridmenu_labbuildmode'),
		description = Spring.I18N('ui.settings.option.gridmenu_labbuildmode_descr'),
		type = "bool",
		widgetApiFunction = 'setUseLabBuildMode',
	},
	{
		configVariable = "showCostPerSecond",
		name = "Extra Info - Cost/Second",
		description = "Show dynamic cost/second in the extra info",
		type = "bool",
	},
	{
		configVariable = "showBuildTime",
		name = "Extra Info - Build Time",
		description = "Show dynamic build time in the extra info",
		type = "bool",
	},
	{
		configVariable = "showDecimals",
		name = "Show Decimals",
		description = "Show decimals in the build time. (e.g. 1.5s)",
		type = "bool",
	},
	{
		configVariable = "cursorInfo",
		name = "Cursor Info",
		description = "Show selected building's extra info under the cursor",
		type = "bool",
	},
	{
		configVariable = "cursorInfoSize",
		name = "Cursor Info Size",
		description = "Font size multiplier for the cursor info",
		type = "slider",
		min = 1,
		max = 2,
		step = 0.1,
	},
	{
		configVariable = "cursorInfoOffset",
		name = "Cursor Info Offset",
		description = "Offset from the cursor for the cursor info",
		type = "slider",
		min = 0,
		max = 20,
		step = 1,
	}
}

local function getOptionId(optionSpec)
	return "grid__menu__" .. optionSpec.configVariable
end

local function getWidgetName()
	return "Grid Menu with Costs/Second"
end

local function getOptionValue(optionSpec)
	if optionSpec.type == "slider" then
		return config_cost_per_second[optionSpec.configVariable]
	elseif optionSpec.type == "bool" then
		return config_cost_per_second[optionSpec.configVariable]
	elseif optionSpec.type == "select" then
		-- we have text, we need index
		for i, v in pairs(optionSpec.options) do
			if config_cost_per_second[optionSpec.configVariable] == v then
				return i
			end
		end
	end
end

local function setOptionValue(optionSpec, value)
	if optionSpec.type == "slider" then
		config_cost_per_second[optionSpec.configVariable] = value
	elseif optionSpec.type == "bool" then
		config_cost_per_second[optionSpec.configVariable] = value
	elseif optionSpec.type == "select" then
		-- we have index, we need text
		config_cost_per_second[optionSpec.configVariable] = optionSpec.options[value]
	end
	
	if optionSpec.widgetApiFunction and WG['gridmenu'] ~= nil and WG['gridmenu'][optionSpec.widgetApiFunction] ~= nil then
		WG['gridmenu'][optionSpec.widgetApiFunction](config_cost_per_second[optionSpec.configVariable])
	end
end

local function createOnChangeFunc(optionSpec)
	return function(_, value, __)
		setOptionValue(optionSpec, value)
		get_refreshCommands()()
	end
end

local function addOptionFromSpec(optionSpec)
	local option = table.copy(optionSpec)

	-- Clear option spec fields that are not needed in the option object
	option.configVariable = nil
	option.enabled = nil
	-- Configure the option object
	option.id = getOptionId(optionSpec)
	option.widgetname = getWidgetName()
	option.value = getOptionValue(optionSpec)
	option.onchange = createOnChangeFunc(optionSpec)

	if WG['options'] ~= nil then
		WG['options'].addOption(option)
	end
end

-------------------------------------------------------------------------------
--- INTERFACE VALUES
-------------------------------------------------------------------------------

local selectedBuildPower = 100
local font2

local units = get_units()
units.buildTime = {}
units.buildSpeed = {}
units.canGiveBuildPower = {}

for unitDefID, unitDef in pairs(UnitDefs) do
	units.buildTime[unitDefID] = unitDef.buildTime
	if unitDef.isBuilder then
		units.buildSpeed[unitDefID] = unitDef.buildSpeed or 0
		units.canGiveBuildPower[unitDefID] = unitDef.canAssist ~= false and unitDef.isFactory ~= true
	end
end

-------------------------------------------------------------------------------
--- Helper Functions
-------------------------------------------------------------------------------

local formatPrice = get_formatPrice()

local function formatBuildTime(buildTime)
	if config_cost_per_second.showDecimals then
		if buildTime < 1 then
			return ("%.2f s"):format(buildTime)
		end

		if buildTime < 10 then
			return ("%.1f s"):format(buildTime)
		end
	end

	local seconds = math_round(buildTime % 60)
	if buildTime < 60 then
		return ("%d s"):format(seconds)
	end

	local minutes = math_floor((buildTime % 3600) / 60)
	if buildTime < 3600 then
		return ("%d m %02d s"):format(minutes, seconds)
	end

	local hours = math_floor(buildTime / 3600)
	return ("%d h %02d m %02d s"):format(hours, minutes, seconds)
end

local function drawDetailedCostLabels(label_x, label_y, uid, fontSize, disabled)
	local _, err = pcall(function()
		if disabled == nil then
			disabled = false
		end

		if uid == nil then
			return
		end
		
		if font2 == nil then
			font2 = get_font2()
		end

		local buildTime = units.buildTime[uid]
		if buildTime == nil or buildTime <= 0 then
			return
		end
		local buildPower = selectedBuildPower or 100

		local metalColor = disabled and "\255\125\125\125" or "\255\245\245\245"
		local energyColor = disabled and "\255\135\135\135" or "\255\255\255\000"
		local timeColor = disabled and "\255\100\100\100" or "\255\185\240\185"

		local infoLines = {}
		if config_cost_per_second.showCostPerSecond then
			local metalCost = units.unitMetalCost[uid]
			local energyCost = units.unitEnergyCost[uid]

			if metalCost ~= nil and energyCost ~= nil then
				infoLines[#infoLines + 1] = metalColor .. formatPrice(math_round(metalCost / buildTime * buildPower)) .. '/s'
				infoLines[#infoLines + 1] = energyColor .. formatPrice(math_round(energyCost / buildTime * buildPower)) .. '/s'
			end
		end
		if config_cost_per_second.showBuildTime then
			infoLines[#infoLines + 1] = timeColor .. formatBuildTime(buildTime / buildPower)
		end

		if #infoLines == 0 then
			return
		end

		for i, line in pairs(infoLines) do
			font2:Print(line, label_x, label_y - (fontSize * i), fontSize, "ro")
		end
	end)

	if err then
		Spring.Echo("Error in drawDetailedCostLabels")
		Spring.Echo(err)
	end
end

local function drawCursorInfo()
	if not config_cost_per_second.cursorInfo or not get_activeBuilder() or get_hoveredRect() then
		return
	end

	local x, y, _, _, _ = spGetMouseState()
	local activeCmd
	if get_isPregame() then
		local prebuildId = WG["pregame-build"] and WG['pregame-build'].getPreGameDefID and WG['pregame-build'].getPreGameDefID()
		activeCmd = prebuildId and -prebuildId or nil
	else
		activeCmd = get_activeCmd()
	end

	if activeCmd ~= nil then
		local offset = config_cost_per_second.cursorInfoOffset
		drawDetailedCostLabels(
			x - offset,
			y - offset,
			-activeCmd,
			config_cost_per_second.cursorInfoSize * get_priceFontSize()
		)
	end
end

local function drawRectInfo(rect)
	local linesToShow = 0
	linesToShow = linesToShow + (config_cost_per_second.showCostPerSecond and 2 or 0)
	linesToShow = linesToShow + (config_cost_per_second.showBuildTime and 1 or 0)

	if linesToShow == 0 then
		return
	end

	local priceFontSize = get_priceFontSize()
	local hotkeyFontSize = priceFontSize * 1.2
	local cellPadding = get_cellPadding()
	local cellInnerSize = get_cellInnerSize()

	if get_showPrice() or rect.opts.hovered then
		drawDetailedCostLabels(
			rect.xEnd - cellPadding - (cellInnerSize * 0.048),
			rect.yEnd - hotkeyFontSize - cellPadding - ((3 - linesToShow) * priceFontSize * 0.8),
			rect.opts.uDefID,
			priceFontSize * (linesToShow > 1 and 0.8 or 1),
			rect.opts.disabled
		)
	end
end

local function calculateSelectedBuildPower()
	local active_builder = get_activeBuilder()
	local build_power = units.buildSpeed[active_builder] or 0

	for unitDefID, unitIds in pairs(spGetSelectedUnitsSorted() or {}) do
		local build_speed = units.buildSpeed[unitDefID] or 0
		if build_speed > 0 and units.canGiveBuildPower[unitDefID] ~= false then
			local is_active_builder = active_builder == unitDefID
			build_power = build_power + (build_speed * (#unitIds - (is_active_builder and 1 or 0)))
		end
	end

	selectedBuildPower = build_power or 100
end

---------------------------------------------------------------------------------
--- Widget Callins Patching
---------------------------------------------------------------------------------
local orig_get_config_data = widget.GetConfigData
function widget:GetConfigData()
	local result = orig_get_config_data(widget)
	for _, option in pairs(OPTION_COST_PER_SECOND_SPECS) do
		result[option.configVariable] = getOptionValue(option)
	end
	return result
end

local orig_set_config_data = widget.SetConfigData
function widget:SetConfigData(data)
	local orig_data = widgetHandler.configData["Grid menu"]
	orig_set_config_data(widget, table.merge(orig_data, data))
	for _, option in pairs(OPTION_COST_PER_SECOND_SPECS) do
		local configVariable = option.configVariable
		if data[configVariable] ~= nil then
			--Spring.Echo("Setting " .. configVariable .. " to " .. tostring(data[configVariable]))
			setOptionValue(option, data[configVariable])
		end
	end
end

local orig_widget_initialize = widget.Initialize
function widget:Initialize()
	local exclusive_widgets = {
		"Grid menu", "Build Menu", -- default widgets
		"Build menu v2", "Grid menu v2", -- old versions of this widgets
		"Build Menu with Costs/Second", -- alternate version of this widget
	}

	for _, widgetName in pairs(exclusive_widgets) do
		if widgetHandler:IsWidgetKnown(widgetName) then
			widgetHandler:DisableWidget(widgetName)
		end
	end

	for _, optionSpec in pairs(OPTION_COST_PER_SECOND_SPECS) do
		addOptionFromSpec(optionSpec)
	end

	orig_widget_initialize(widget)
	font2 = get_font2()

	if get_isPregame() then
		selectedBuildPower = units.buildSpeed[get_startDefID()] or 300
	end
end

local orig_widget_shutdown = widget.Shutdown
function widget:Shutdown()
	orig_widget_shutdown(widget)

	if WG['options'] ~= nil then
		for _, option in pairs(OPTION_COST_PER_SECOND_SPECS) do
			WG['options'].removeOption(getOptionId(option))
		end
	end
end

local orig_widget_update = widget.Update
function widget:Update(dt)
	orig_widget_update(widget, dt)
	if get_isPregame() then
		selectedBuildPower = units.buildSpeed[get_startDefID()] or 300
	end
end

local orig_widget_selection_changed = widget.SelectionChanged
function widget:SelectionChanged(selectedUnits)
	orig_widget_selection_changed(widget, selectedUnits)
	calculateSelectedBuildPower()
end

local orig_widget_draw_screen = widget.DrawScreen
function widget:DrawScreen()
	orig_widget_draw_screen(widget)
	drawCursorInfo()
end

-------------------------------------------------------------------------------
--- Local Function Patching
-------------------------------------------------------------------------------

local orig_refresh_commands = get_refreshCommands()
local function refreshCommands()
	orig_refresh_commands()
	calculateSelectedBuildPower()
end
set_refreshCommands(refreshCommands)

local orig_draw_cell = get_drawCell()
local function drawCell(rect)
	orig_draw_cell(rect)
	drawRectInfo(rect)
end
set_drawCell(drawCell)