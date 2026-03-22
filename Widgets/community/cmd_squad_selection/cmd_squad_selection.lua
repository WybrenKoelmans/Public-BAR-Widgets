function widget:GetInfo()
	return {
		name = "Squad Selection",
		desc = "Automagical squad creation and proximity-based selection",
		author = "Baldric, yyyy",
		date = "2026",
		license = "GNU GPL, v2 or later",
		layer = -999998,
		enabled = true,
	}
end


-------------------------------------------------------------------------------
-- Config
-------------------------------------------------------------------------------

local config = {
	leftClickSelectsSquad = true, -- left-click can be used to select squads
	cyclingToNextSquad = true, -- when full squad/type is selected, exclude it to cycle to next
	rightClickSquadCreate = true, -- right-click creates squads; toggle with squad_create_toggle action
	visualizationMode = "coloredLabel", -- "convexHull" or "coloredLabel"
	convexHullPaddingLand = 50, -- space (in elmos?) between the units and the hull boundary
	convexHullPaddingNavy = 50,
	convexHullPaddingAir = 50, -- for idle airplanes this padding is relative to the position they went idle at
	convexHullArcResolution = math.rad(30), -- angle that each chord of the arc spans
	convexHullAirHeightBoost = 200,
	convexHullAirFloorDelta = 200, -- grid size (elmos?)
	convexHullAirFloorCurtainSlope = 0.2,
	convexHullAirFloorSearchDistance = 1000,
	convexHullFillOpacity = 0.1,
	convexHullBorderOpacity = 0.2,
	convexHullBorderThickness = 2,
}

-------------------------------------------------------------------------------
-- Localized Spring API
--
-- Avoids repeated global table lookups. Matters most in DrawScreen where we
-- iterate every tracked unit each frame; negligible for one-shot calls in
-- Initialize, but kept here as an at-a-glance "imports" list.
-------------------------------------------------------------------------------

local spEcho = Spring.Echo
local spGetMyTeamID = Spring.GetMyTeamID
local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitPosition = Spring.GetUnitPosition
local spGetSelectedUnits = Spring.GetSelectedUnits
local spSelectUnitArray = Spring.SelectUnitArray
local spGetMouseState = Spring.GetMouseState
local spTraceScreenRay = Spring.TraceScreenRay
local spWorldToScreenCoords = Spring.WorldToScreenCoords
local spIsGUIHidden = Spring.IsGUIHidden
local spGetModKeyState = Spring.GetModKeyState
local spGetSpectatingState = Spring.GetSpectatingState
local spGetActiveCommand = Spring.GetActiveCommand
local spGetMyPlayerID = Spring.GetMyPlayerID
local spGetGroupUnits = Spring.GetGroupUnits
local spGetUnitGroup = Spring.GetUnitGroup
local spGetMouseCursor = Spring.GetMouseCursor
local spIsReplay = Spring.IsReplay
local spGetGroundHeight = Spring.GetGroundHeight
local spGetUnitCommands = Spring.GetUnitCommands
local spGetTeamColor = Spring.GetTeamColor

local glColor = gl.Color
local glText = gl.Text
local glDepthTest = gl.DepthTest
local glBeginEnd = gl.BeginEnd
local glLineWidth = gl.LineWidth
local glVertex = gl.Vertex

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local squads = {} -- ordered list of squad arrays; reserve squads are always first
local unit_squad = {} -- unitID -> the squad array it belongs to
local unit_slot = {} -- unitID -> index within that squad (for O(1) removal)
local reserve_squads = {} -- domain string -> reserve squad for that domain
local factory_squad = {} -- factoryUnitID -> squad
local DOMAINS = {"land", "air", "naval"}

-------------------------------------------------------------------------------
-- Debug
-------------------------------------------------------------------------------

local DEBUG = false

local function log(msg)
	if DEBUG then
		spEcho("[Squad] " .. tostring(msg))
	end
end


local function log_squads()
	if not DEBUG then
		return
	end
	log("  " .. #squads .. " squad(s):")
	for _, squad in ipairs(squads) do
		local label = squad.letter or "?"
		if squad.domain then
			label = label .. ":" .. squad.domain
		end
		log("    [" .. label .. "] " .. #squad .. " units")
	end
end


-------------------------------------------------------------------------------
-- Utility
-------------------------------------------------------------------------------

-- more readable way to limit a value at two ends
local function constrain(x, min, max)
	return math.max(min, math.min(max, x))
end


-------------------------------------------------------------------------------
-- Squad-eligible exceptions
--
-- Units listed here are treated as squad-eligible even if they don't pass the
-- normal combat-unit filter (mobile + armed + no build options). Use the
-- internal unit name (UnitDefs[defID].name), NOT the human-readable name.
-------------------------------------------------------------------------------

local SQUAD_ELIGIBLE_EXTRAS = {
	corfink = true, -- Cortex T1 air scout
	corawac = true, -- Cortex T2 air scout
	armpeep = true, -- Arm T1 air scout
	armawac = true, -- Arm T2 air scout
}

-------------------------------------------------------------------------------
-- Squad appearance
--
-- Each squad gets a color and a letter, assigned on
-- creation.  These are stored directly on the squad table as string-keyed
-- fields (squad.color, squad.letter) which don't interfere with the integer-
-- keyed unit list or #squad.
-------------------------------------------------------------------------------

local SQUAD_COLORS = {
	{1.0, 0.3, 0.3}, -- red
	{0.3, 1.0, 0.3}, -- green
	{0.3, 0.5, 1.0}, -- blue
	{1.0, 1.0, 0.3}, -- yellow
	{1.0, 0.3, 1.0}, -- magenta
	{0.3, 1.0, 1.0}, -- cyan
	{1.0, 0.6, 0.2}, -- orange
	{0.7, 0.3, 1.0} -- purple
}

local SQUAD_LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ+#@!$=&"
local next_squad_tag = 0

local FACTORY_RESERVE_COLOR = {1, 1, 1}

local DOMAIN_SYMBOL = {
	land = "-",
	air = "^",
	naval = "~",
}

local function assign_squad_tag(squad)
	next_squad_tag = next_squad_tag + 1
	local ci = (next_squad_tag - 1) % #SQUAD_COLORS + 1
	local li = (next_squad_tag - 1) % #SQUAD_LETTERS + 1
	squad.color = SQUAD_COLORS[ci]
	squad.letter = SQUAD_LETTERS:sub(li, li)
end


-------------------------------------------------------------------------------
-- Unit classification
--
-- is_combat[defID] — true if the unit type is squad-eligible.
-- unit_domain[defID] — "land", "air", or "naval".
-- Both tables are fully populated once by classify_unitdefs() in Initialize,
-- so runtime lookups are a single table index with no branching.
-------------------------------------------------------------------------------

local defid_of = {} -- unitID -> defID  (false when lookup fails)
local is_combat = {} -- defID  -> bool
local unit_domain = {} -- defID -> "land" | "air" | "naval"
local is_factory = {} -- defID  -> bool (immobile with buildOptions)
local factory_domain = {} -- defID -> "land" | "air" | "naval" (from buildOptions)

local function get_defid(unit_id)
	local v = defid_of[unit_id]
	if v ~= nil then
		return v
	end
	local id = spGetUnitDefID(unit_id)
	v = id or false
	defid_of[unit_id] = v
	return v
end


--- Pre-compute is_combat and unit_domain for every defID in one pass.
local function classify_unitdefs()
	for defID, def in pairs(UnitDefs) do
		-- Domain
		if def.canFly then
			unit_domain[defID] = "air"
		elseif def.minWaterDepth and def.minWaterDepth > 0 then
			unit_domain[defID] = "naval"
		else
			unit_domain[defID] = "land"
		end

		-- Squad eligibility
		if SQUAD_ELIGIBLE_EXTRAS[def.name] then
			is_combat[defID] = true
		elseif not def.isBuilding and def.weapons and #def.weapons > 0 and not (def.buildOptions and #def.buildOptions > 0) then
			is_combat[defID] = true
		else
			is_combat[defID] = false
		end

		-- Factory detection
		if def.isFactory then
			is_factory[defID] = true
		end
	end

	-- Second pass: determine factory domains from their buildOptions
	for defID, def in pairs(UnitDefs) do
		if is_factory[defID] then
			factory_domain[defID] = unit_domain[def.buildOptions[1]] or "land"
		end
	end
end


-------------------------------------------------------------------------------
-- Squad operations
-------------------------------------------------------------------------------

local function add_to_squad(unit_id, squad)
	local slot = #squad + 1
	squad[slot] = unit_id
	unit_squad[unit_id] = squad
	unit_slot[unit_id] = slot
end


-- Swap-with-last removal: O(1), order within a squad is not meaningful.
local function remove_from_squad(unit_id)
	local squad = unit_squad[unit_id]
	if not squad then
		return
	end

	local slot = unit_slot[unit_id]
	local last = squad[#squad]

	if last ~= unit_id then
		squad[slot] = last
		unit_slot[last] = slot
	end

	squad[#squad] = nil
	unit_squad[unit_id] = nil
	unit_slot[unit_id] = nil
end


-- Remove squads that have become empty (never removes reserve squads).
local function prune_empty_squads()
	for i = #squads, 1, -1 do
		local sq = squads[i]
		if not sq.is_reserve and #sq == 0 then
			log("Squad [" .. (sq.letter or "?") .. "] emptied and removed")
			table.remove(squads, i)
		end
	end
end


-- Check whether any factory still references the given squad.
-- If none do, clear is_reserve so the squad becomes prunable.
local function update_factory_squad_reserve(sq)
	if not sq or not sq.from_factory then
		return
	end
	for _, fsq in pairs(factory_squad) do
		if fsq == sq then
			return
		end
	end
	sq.is_reserve = false
	sq.from_factory = false
	assign_squad_tag(sq)
end


-------------------------------------------------------------------------------
-- Squad creation from selection
-------------------------------------------------------------------------------

-- Returns true when the selection and the squad are exactly the same set. 
-- In that case right-clicking is a no-op. This preserves the squad label and color.
local function selection_is_existing_squad(selected)
	local squad = nil
	local combat_count = 0
	for i = 1, #selected do
		local u = selected[i]
		local def_id = get_defid(u)
		if def_id and is_combat[def_id] then
			combat_count = combat_count + 1
			local s = unit_squad[u]
			if s and s.is_reserve then
				return false
			end
			if squad == nil then
				squad = s
			elseif s ~= squad then
				return false
			end
		end
	end
	return squad ~= nil and #squad == combat_count
end


local function assign_factory_squad()
	local selected = spGetSelectedUnits()
	local factories = {}
	for i = 1, #selected do
		local u = selected[i]
		local def_id = get_defid(u)
		if def_id and is_factory[def_id] then
			factories[#factories + 1] = u
		end
	end
	if #factories == 0 or #factories ~= #selected then
		return
	end

	-- Count how many factories already have an assignment
	local assigned_count = 0
	for i = 1, #factories do
		if factory_squad[factories[i]] then
			assigned_count = assigned_count + 1
		end
	end

	-- Clear existing assignments if any
	if assigned_count > 0 then
		local affected = {}
		for i = 1, #factories do
			local sq = factory_squad[factories[i]]
			if sq then
				affected[sq] = true
			end
			factory_squad[factories[i]] = nil
		end
		for sq in pairs(affected) do
			update_factory_squad_reserve(sq)
		end
		prune_empty_squads()
		log("Removed factory squad assignments from " .. assigned_count .. " factory(s)")
		-- If ALL were assigned, just toggle off
		if assigned_count == #factories then
			return
		end
	end

	-- Create a new factory reserve squad
	local new_squad = {}
	assign_squad_tag(new_squad)
	new_squad.color = FACTORY_RESERVE_COLOR
	new_squad.is_reserve = true
	new_squad.from_factory = true

	local first_def = get_defid(factories[1])
	local domain = factory_domain[first_def] or "land"
	new_squad.domain = domain

	local sym = DOMAIN_SYMBOL[domain] or "-"
	new_squad.letter = sym .. new_squad.letter .. sym

	for i = 1, #factories do
		factory_squad[factories[i]] = new_squad
	end
	squads[#squads + 1] = new_squad

	log("Factory squad [" .. new_squad.letter .. "] assigned to " .. #factories .. " factory(s)")
	log_squads()
end


local function create_squad_from_selection()
	local selected = spGetSelectedUnits()
	if #selected == 0 then
		return
	end

	if selection_is_existing_squad(selected) then
		return
	end

	local new_squad = {}
	for i = 1, #selected do
		local u = selected[i]
		local def_id = get_defid(u)
		if def_id and is_combat[def_id] then
			remove_from_squad(u)
			add_to_squad(u, new_squad)
		end
	end

	if #new_squad == 0 then
		return
	end

	assign_squad_tag(new_squad)
	squads[#squads + 1] = new_squad
	prune_empty_squads()

	log("New squad [" .. new_squad.letter .. "]: " .. #new_squad .. " units")
	log_squads()
end


-------------------------------------------------------------------------------
-- Finding closest unit
--
-- Returns the mouse cursor's world position, then iterates all tracked units
-- to find the one nearest to it. 
-------------------------------------------------------------------------------

local function get_mouse_world_pos()
	local mx, my = spGetMouseState()
	local _, coords = spTraceScreenRay(mx, my, true)
	if not coords then
		return nil
	end
	return coords[1], coords[3] -- world x, world z
end


-- Returns the unitID closest to the mouse cursor, or nil if none found.
-- Optional filter_defs (defID set) and exclude (unitID set) narrow the search.
local function find_closest_unit(filter_defs, exclude)
	local wx, wz = get_mouse_world_pos()
	if not wx then
		return nil
	end

	local best_unit = nil
	local best_dist_sq = math.huge

	for _, squad in ipairs(squads) do
		for j = 1, #squad do
			local u = squad[j]
			if not (exclude and exclude[u]) then
				if not filter_defs or (defid_of[u] and filter_defs[defid_of[u]]) then
					local x, _, z = spGetUnitPosition(u)
					if x then
						local dx = x - wx
						local dz = z - wz
						local dist_sq = dx * dx + dz * dz
						if dist_sq < best_dist_sq then
							best_dist_sq = dist_sq
							best_unit = u
						end
					end
				end
			end
		end
	end

	return best_unit
end


-------------------------------------------------------------------------------
-- Selection analysis
--
-- Classifies the current selection into one of four states:
--   no filter       — no tracked units selected (builders/empty)
--   single-squad    — all tracked units belong to one squad
--   multi-squad     — tracked units span multiple squads
--   full squad      — single-squad AND every unit in that squad is selected
--   full type match — single-squad AND every unit matching the filter types
--                     in that squad is selected (full squad implies this)
--
-- Returns a table with all the information both actions need.
-------------------------------------------------------------------------------

--- Inspect the current selection and return a summary used by squad-select actions.
--
-- Returns a table with:
--   selected          — array of currently selected unitIDs (from engine)
--   selected_set      — set (unitID → true) for O(1) membership tests
--   selected_type_set — set of defIDs present in the selection (only from
--                        tracked squad units). Used to filter squads by unit
--                        type, e.g. "select all Grunts in the closest squad".
--   has_tracked_units — true when at least one selected unit is a tracked
--                        squad unit with a known type. When false, callers
--                        fall back to type-agnostic behavior.
--   single_squad      — the squad table if every tracked unit belongs to the
--                        same squad, nil otherwise (mixed-squad or no squads).
--   is_full_squad     — true when the entire single_squad is selected.
--   is_full_type_match — true when every unit in single_squad whose type
--                        appears in selected_type_set is already selected.
--                        A full squad trivially satisfies this. Used by
--                        filtered-select to decide whether to cycle.
local function analyze_selection()
	local selected = spGetSelectedUnits()
	local selected_set = {}
	local selected_type_set = {}
	local has_tracked_units = false
	local single_squad = nil
	local from_multiple_squads = false
	local tracked_count = 0

	for i = 1, #selected do
		local u = selected[i]
		selected_set[u] = true
		local sq = unit_squad[u]
		if sq then
			tracked_count = tracked_count + 1
			local def_id = defid_of[u]
			if def_id then
				selected_type_set[def_id] = true
				has_tracked_units = true
			end
			if single_squad == nil then
				single_squad = sq
			elseif sq ~= single_squad then
				from_multiple_squads = true
			end
		end
	end

	if from_multiple_squads then
		single_squad = nil
	end

	local is_full_squad = single_squad ~= nil and tracked_count == #single_squad

	-- Check if all units of matching types in the single squad are selected.
	-- A full squad trivially satisfies this (every type is fully selected).
	local is_full_type_match = is_full_squad
	if single_squad and has_tracked_units and not is_full_squad then
		local matching_total = 0
		local matching_selected = 0
		for j = 1, #single_squad do
			local u = single_squad[j]
			local def_id = defid_of[u]
			if def_id and selected_type_set[def_id] then
				matching_total = matching_total + 1
				if selected_set[u] then
					matching_selected = matching_selected + 1
				end
			end
		end
		is_full_type_match = matching_total > 0 and matching_selected == matching_total
	end

	return {
		selected = selected,
		selected_set = selected_set,
		selected_type_set = selected_type_set,
		has_tracked_units = has_tracked_units,
		single_squad = single_squad,
		is_full_squad = is_full_squad,
		is_full_type_match = is_full_type_match,
	}
end


--- Filter a squad down to units whose defID is in the given set.
local function filter_squad_by_defs(squad, defs)
	local result = {}
	for j = 1, #squad do
		local u = squad[j]
		local def_id = defid_of[u]
		if def_id and defs[def_id] then
			result[#result + 1] = u
		end
	end
	return result
end


-------------------------------------------------------------------------------
-- Closest squad selection action
--
-- See development.md "Selection action decision matrix" for the full table.
-- Only excludes selected units from the closest-unit search when the entire
-- squad is already selected (to cycle to the next squad).
-------------------------------------------------------------------------------

local function closest_squad_select(_, _, args)
	local sel = analyze_selection()
	local append = args and args[1] == "append"

	-- Full squad: cycle to next squad (exclude selected) or fall through as multi-squad
	local exclude = nil
	if sel.is_full_squad and config.cyclingToNextSquad then
		exclude = sel.selected_set
	end

	local unit = find_closest_unit(nil, exclude)
	if not unit then
		return
	end

	local squad = unit_squad[unit]
	if not squad then
		return
	end

	spSelectUnitArray(squad, append)
	log("Selected squad [" .. (squad.letter or "?") .. "] (" .. #squad .. " units)" .. (append and " +append" or ""))
end


-------------------------------------------------------------------------------
-- Squad creation toggle + on-demand creation
-------------------------------------------------------------------------------

local function squad_create_toggle()
	config.rightClickSquadCreate = not config.rightClickSquadCreate
	spEcho("[Squad] Squad creation " .. (config.rightClickSquadCreate and "enabled" or "disabled"))
end


local function squad_create()
	assign_factory_squad()
	create_squad_from_selection()
end


-------------------------------------------------------------------------------
-- Filtered squad selection
--
-- See development.md "Selection action decision matrix" for the full table.
-- Three paths:
--   1. Single-squad, not all matching types selected → complete the type
--      selection within that squad (no closest-unit search needed).
--   2. Full type match → exclude selected and search for the next squad.
--   3. No filter / multi-squad → search for closest matching unit.
-------------------------------------------------------------------------------

local function closest_squad_select_filtered(_, _, args)
	local sel = analyze_selection()
	local append = args and args[1] == "append"

	-- Full type match: cycle to next squad (exclude selected) or fall through as multi-squad
	local exclude = nil
	if sel.is_full_type_match and config.cyclingToNextSquad then
		exclude = sel.selected_set
	end

	local search_defs = sel.has_tracked_units and sel.selected_type_set or nil
	local closest = find_closest_unit(search_defs, exclude)
	if not closest then
		return
	end

	local squad = unit_squad[closest]
	if not squad then
		return
	end

	-- If no filter types from selection, use the closest unit's type
	local defs = sel.selected_type_set
	if not sel.has_tracked_units then
		local def_id = defid_of[closest]
		if not def_id then
			spSelectUnitArray({closest}, append)
			return
		end
		defs = {
			[def_id] = true,
		}
	end

	local result = filter_squad_by_defs(squad, defs)
	spSelectUnitArray(result, append)
	log("Filtered select from squad [" .. (squad.letter or "?") .. "]: " .. #result .. "/" .. #squad .. " units" .. (append and " +append" or ""))
end


-------------------------------------------------------------------------------
-- Control group intersection
--
-- Selects the intersection of a control group and the closest squad.
-- Algorithm: get units in group N → filter to tracked → find closest to
-- mouse → get its squad → select squad ∩ group.
-------------------------------------------------------------------------------

--- Build a set of unitIDs belonging to a control group.
-- Tries GetGroupUnits first, falls back to iterating tracked units.
local function build_group_set(group_num)
	local group_units
	if spGetGroupUnits then
		group_units = spGetGroupUnits(group_num)
	end

	local group_set = {}
	if group_units and #group_units > 0 then
		for i = 1, #group_units do
			group_set[group_units[i]] = true
		end
	else
		for _, squad in ipairs(squads) do
			for j = 1, #squad do
				local u = squad[j]
				if spGetUnitGroup(u) == group_num then
					group_set[u] = true
				end
			end
		end
	end
	return group_set
end


local function squad_select_group(_, _, args)
	if not args or not args[1] then
		return
	end
	local group_num = tonumber(args[1])
	if not group_num then
		return
	end
	local append = args[2] == "append"

	local group_set = build_group_set(group_num)

	-- Cycling: if current selection exactly matches a squad∩group intersection,
	-- exclude those units so we cycle to the next squad.
	local exclude = nil
	if config.cyclingToNextSquad then
		local selected = spGetSelectedUnits()
		if #selected > 0 then
			local selected_set = {}
			for i = 1, #selected do
				selected_set[selected[i]] = true
			end
			-- Check if selection is a single squad's intersection with this group
			local sel_squad = nil
			local all_match = true
			for i = 1, #selected do
				local u = selected[i]
				local sq = unit_squad[u]
				if not sq or not group_set[u] then
					all_match = false
					break
				end
				if sel_squad == nil then
					sel_squad = sq
				elseif sq ~= sel_squad then
					all_match = false
					break
				end
			end
			if all_match and sel_squad then
				-- Check that the full intersection is selected (no unselected group members in that squad)
				local full_intersection = true
				for j = 1, #sel_squad do
					local u = sel_squad[j]
					if group_set[u] and not selected_set[u] then
						full_intersection = false
						break
					end
				end
				if full_intersection then
					exclude = selected_set
				end
			end
		end
	end

	-- Filter to tracked units only and find closest to mouse
	local wx, wz = get_mouse_world_pos()
	if not wx then
		return
	end

	local best_unit = nil
	local best_dist_sq = math.huge

	for uid, _ in pairs(group_set) do
		if unit_squad[uid] and not (exclude and exclude[uid]) then
			local x, _, z = spGetUnitPosition(uid)
			if x then
				local dx = x - wx
				local dz = z - wz
				local dist_sq = dx * dx + dz * dz
				if dist_sq < best_dist_sq then
					best_dist_sq = dist_sq
					best_unit = uid
				end
			end
		end
	end

	if not best_unit then
		return
	end

	local squad = unit_squad[best_unit]
	if not squad then
		return
	end

	-- Select intersection of squad and control group
	local result = {}
	for j = 1, #squad do
		local u = squad[j]
		if group_set[u] then
			result[#result + 1] = u
		end
	end

	if #result > 0 then
		spSelectUnitArray(result, append)
		log("Group " .. group_num .. " ∩ squad [" .. (squad.letter or "?") .. "]: " .. #result .. " units" .. (append and " +append" or ""))
	end
end


-------------------------------------------------------------------------------
-- Portion selection
--
-- Progressive, distance-sorted selection within a squad. Each step selects
-- more units. The current step is determined statelessly from the selection:
-- count how many pool units are already selected, then pick the first step
-- whose resolved count exceeds that.
-------------------------------------------------------------------------------

--- Convert a step value to a unit count.
-- 0 → 1 unit; 0 < step <= 1 → percentage; step > 1 → fixed count.
local function step_to_count(step, pool_size)
	if pool_size <= 0 then
		return 0
	end
	if step <= 0 then
		return 1
	end
	if step <= 1 then
		return math.max(1, math.ceil(step * pool_size))
	end
	return math.min(math.floor(step), pool_size)
end


--- Parse portion action args: optional "append" keyword + step numbers.
local function parse_portion_args(args)
	if not args then
		return false, {}
	end
	local append = false
	local steps = {}
	for i = 1, #args do
		if args[i] == "append" then
			append = true
		else
			local n = tonumber(args[i])
			if n then
				steps[#steps + 1] = n
			end
		end
	end
	return append, steps
end


--- Sort a unit array in-place by distance to a world point.
local function sort_units_by_distance(units, wx, wz)
	local dist_cache = {}
	for i = 1, #units do
		local u = units[i]
		local x, _, z = spGetUnitPosition(u)
		if x then
			dist_cache[u] = (x - wx) * (x - wx) + (z - wz) * (z - wz)
		else
			dist_cache[u] = math.huge
		end
	end
	table.sort(units, function(a, b)
		return dist_cache[a] < dist_cache[b]
	end
)
end


--- Filter a squad to units matching optional filter_defs and group_set.
local function get_portion_pool(squad, filter_defs, group_set)
	local pool = {}
	for j = 1, #squad do
		local u = squad[j]
		if not group_set or group_set[u] then
			if not filter_defs or (defid_of[u] and filter_defs[defid_of[u]]) then
				pool[#pool + 1] = u
			end
		end
	end
	return pool
end


--- Core portion selection logic (stateless).
local function do_portion_select(append, steps, filter_defs, group_set)
	if #steps == 0 then
		return
	end

	local wx, wz = get_mouse_world_pos()
	if not wx then
		return
	end

	local sel = analyze_selection()

	-- Find target squad
	-- Append mode always uses the closest unit's squad so the player can
	-- target a different squad than what's already selected.
	local target_squad
	if sel.single_squad and not append then
		target_squad = sel.single_squad
	else
		-- Find closest matching unit globally (respecting filter + group constraints)
		local best_unit, best_dist_sq = nil, math.huge
		for _, squad in ipairs(squads) do
			for j = 1, #squad do
				local u = squad[j]
				if not group_set or group_set[u] then
					if not filter_defs or (defid_of[u] and filter_defs[defid_of[u]]) then
						local x, _, z = spGetUnitPosition(u)
						if x then
							local dx, dz = x - wx, z - wz
							local d = dx * dx + dz * dz
							if d < best_dist_sq then
								best_dist_sq = d
								best_unit = u
							end
						end
					end
				end
			end
		end
		target_squad = best_unit and unit_squad[best_unit]
	end

	if not target_squad then
		return
	end

	-- Build pool
	local pool = get_portion_pool(target_squad, filter_defs, group_set)
	if #pool == 0 then
		return
	end

	-- Count how many pool units are already selected
	local current_count = 0
	for i = 1, #pool do
		if sel.selected_set[pool[i]] then
			current_count = current_count + 1
		end
	end

	-- Find first step whose resolved count > current_count
	local target_count = nil
	for i = 1, #steps do
		local c = step_to_count(steps[i], #pool)
		if c > current_count then
			target_count = c
			break
		end
	end

	-- Past last step: repeat the last step's count in both modes.
	if not target_count then
		target_count = step_to_count(steps[#steps], #pool)
	end

	if append then
		-- Append mode: select target_count closest *unselected* pool units
		sort_units_by_distance(pool, wx, wz)
		local to_select = {}
		for i = 1, #pool do
			if not sel.selected_set[pool[i]] then
				to_select[#to_select + 1] = pool[i]
				if #to_select >= target_count then
					break
				end
			end
		end
		if #to_select == 0 then
			return
		end
		spSelectUnitArray(to_select, true)
		log("Portion select: +" .. #to_select .. " from squad [" .. (target_squad.letter or "?") .. "] (append)")
	else
		-- Replace mode: select target_count closest from full pool
		sort_units_by_distance(pool, wx, wz)
		local to_select = {}
		for i = 1, target_count do
			to_select[i] = pool[i]
		end
		spSelectUnitArray(to_select, false)
		log("Portion select: " .. target_count .. "/" .. #pool .. " from squad [" .. (target_squad.letter or "?") .. "]")
	end
end


-------------------------------------------------------------------------------
-- Portion action handlers
-------------------------------------------------------------------------------

local function squad_select_portion(_, _, args)
	local append, steps = parse_portion_args(args)
	do_portion_select(append, steps, nil, nil)
end


local function squad_select_portion_filtered(_, _, args)
	local append, steps = parse_portion_args(args)
	local sel = analyze_selection()
	local filter_defs
	if sel.has_tracked_units then
		filter_defs = sel.selected_type_set
	else
		local closest = find_closest_unit(nil, nil)
		if not closest then
			return
		end
		local def_id = defid_of[closest]
		if not def_id then
			return
		end
		filter_defs = {
			[def_id] = true,
		}
	end
	do_portion_select(append, steps, filter_defs, nil)
end


local function squad_select_portion_group(_, _, args)
	if not args or not args[1] then
		return
	end
	local group_num = tonumber(args[1])
	if not group_num then
		return
	end
	-- Remaining args (after group number) are append + steps
	local remaining = {}
	for i = 2, #args do
		remaining[#remaining + 1] = args[i]
	end
	local append, steps = parse_portion_args(remaining)
	local group_set = build_group_set(group_num)
	do_portion_select(append, steps, nil, group_set)
end


-- compute a nicer surface to project the aircraft convex hulls onto
-- airplane_floor is a 2d array containing
-- sampled map heights, with cliffs turn into hills
-- like draping a stiff blanket over the map
-- for example, it turns this
--                 ___                                                         
--                |   |                                                       
--                |   |                                                       
--  ______________|   |___________________________                            
--                                                                            
--                                                                            
-- into this                                                                  
--                 ___                                                        
--             _ -     - _                                                   
--          _ -           - _                                                 
--  ______-                   -__________________                          
--                                                                                     
--                                                                            
--                          

-- map dimensions for determining grid size
-- and for limiting lookups to be inside the floor
local map_xmax = Game.mapSizeX
local map_ymax = Game.mapSizeZ

local airplane_floor = {}
local function create_airplane_floor()

	local curtain_slope = config.convexHullAirFloorCurtainSlope -- shorter name

	-- number of boxes in the grid. each box has 4 lookup points
	local n_box_x = math.floor(map_xmax / config.convexHullAirFloorDelta)
	local n_box_y = math.floor(map_ymax / config.convexHullAirFloorDelta)

	-- pass 1 - sample random map points in the area
	-- from the actual map
	for i = 0, n_box_x do
		airplane_floor[i] = {}
		for j = 0, n_box_y do
			local map_height = spGetGroundHeight(i * config.convexHullAirFloorDelta, j * config.convexHullAirFloorDelta)
			local floor_height = map_height
			for r = 0, config.convexHullAirFloorSearchDistance, 200 do
				for theta = 0, 6 do
					local sample_height = spGetGroundHeight(i * config.convexHullAirFloorDelta + r * math.cos(theta), j * config.convexHullAirFloorDelta + r * math.sin(theta))
					floor_height = math.max(floor_height, sample_height - r * curtain_slope)
				end
			end
			airplane_floor[i][j] = floor_height
		end
	end

	-- pass 2 - sample every point in the vicinity
	-- taken from the floor computed in pass 1
	for i = 0, n_box_x do
		for j = 0, n_box_y do
			local floor_height = 0
			local curtain_block_length = math.ceil(config.convexHullAirFloorSearchDistance / config.convexHullAirFloorDelta)
			for ii = math.max(0, i - curtain_block_length), math.min(n_box_x, i + curtain_block_length) do
				for jj = math.max(0, j - curtain_block_length), math.min(n_box_y, j + curtain_block_length) do
					local distance = ((i - ii) ^ 2 + (j - jj) ^ 2) ^ 0.5 * config.convexHullAirFloorDelta
					floor_height = math.max(floor_height, airplane_floor[ii][jj] - distance * curtain_slope)
				end
			end
			airplane_floor[i][j] = floor_height
		end
	end
end


-- bilinear interpolation of the airplane floor
local function airplane_floor_height(x, y)
	x = constrain(x, 0, map_xmax - config.convexHullAirFloorDelta)
	y = constrain(y, 0, map_ymax - config.convexHullAirFloorDelta)
	local left = math.floor(x / config.convexHullAirFloorDelta)
	local bottom = math.floor(y / config.convexHullAirFloorDelta)
	local right = left + 1
	local top = bottom + 1
	local box_x = (x - left * config.convexHullAirFloorDelta) / config.convexHullAirFloorDelta
	local box_y = (y - bottom * config.convexHullAirFloorDelta) / config.convexHullAirFloorDelta
	local weight_bottomleft = (1 - box_x) * (1 - box_y)
	local weight_bottomright = (box_x) * (1 - box_y)
	local weight_topleft = (1 - box_x) * (box_y)
	local weight_topright = (box_x) * (box_y)
	return airplane_floor[left][bottom] * weight_bottomleft + airplane_floor[right][bottom] * weight_bottomright + airplane_floor[left][top] * weight_topleft + airplane_floor[right][top] * weight_topright
end


-------------------------------------------------------------------------------
-- Settings action — toggle/set config values from chat
-- Usage:
--   /luaui squad_setting toggle rightClickSquadCreate
--   /luaui squad_setting toggle cyclingToNextSquad
--   /luaui squad_setting set visualizationMode convexHull
--   /luaui squad_setting set visualizationMode coloredLabel
--   /luaui squad_setting get cyclingToNextSquad
-------------------------------------------------------------------------------

local function squad_setting(_, _, args)
	if not args or not args[1] then
		spEcho("[Squad] Usage: squad_setting toggle|set|get <key> [value]")
		return
	end
	local action = args[1]
	local key = args[2]
	if not key or config[key] == nil then
		spEcho("[Squad] Unknown config key: " .. tostring(key))
		return
	end

	if action == "toggle" then
		if type(config[key]) ~= "boolean" then
			spEcho("[Squad] Cannot toggle non-boolean key: " .. key)
			return
		end
		config[key] = not config[key]
		spEcho("[Squad] " .. key .. " = " .. tostring(config[key]))
	elseif action == "set" then
		local value = args[3]
		if not value then
			spEcho("[Squad] Missing value for set")
			return
		end
		-- coerce to number or boolean if appropriate
		if value == "true" then
			value = true
		elseif value == "false" then
			value = false
		elseif tonumber(value) then
			value = tonumber(value)
		end
		if key == "visualizationMode" and value == "convexHull" then
			create_airplane_floor()
		end
		config[key] = value
		spEcho("[Squad] " .. key .. " = " .. tostring(config[key]))
	elseif action == "get" then
		spEcho("[Squad] " .. key .. " = " .. tostring(config[key]))
	else
		spEcho("[Squad] Unknown action: " .. action .. " (use toggle, set, or get)")
	end
end


-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function widget:Initialize()
	if spGetSpectatingState() or spIsReplay() then
		log("Spectating or replay mode detected, not initializing")
		widgetHandler:RemoveWidget()
		return
	end

	squads = {}
	reserve_squads = {}
	factory_squad = {}
	unit_squad = {}
	unit_slot = {}
	next_squad_tag = 0

	classify_unitdefs()

	for _, domain in ipairs(DOMAINS) do
		local sq = {}
		sq.is_reserve = true
		sq.domain = domain
		reserve_squads[domain] = sq
		squads[#squads + 1] = sq
	end

	local team_id = spGetMyTeamID()
	local all = spGetTeamUnits(team_id)
	local count = 0

	for i = 1, #all do
		local u = all[i]
		local def_id = get_defid(u)
		if def_id and is_combat[def_id] then
			add_to_squad(u, reserve_squads[unit_domain[def_id]])
			count = count + 1
		end
	end

	widgetHandler:AddAction("closest_squad_select", closest_squad_select, nil, "p")
	widgetHandler:AddAction("closest_squad_select_filtered", closest_squad_select_filtered, nil, "p")
	widgetHandler:AddAction("squad_create_toggle", squad_create_toggle, nil, "p")
	widgetHandler:AddAction("squad_create", squad_create, nil, "p")
	widgetHandler:AddAction("squad_select_group", squad_select_group, nil, "p")
	widgetHandler:AddAction("squad_select_portion", squad_select_portion, nil, "p")
	widgetHandler:AddAction("squad_select_portion_filtered", squad_select_portion_filtered, nil, "p")
	widgetHandler:AddAction("squad_select_portion_group", squad_select_portion_group, nil, "p")
	widgetHandler:AddAction("squad_setting", squad_setting, nil, "t")

	-- WG interface for gui_options.lua integration
	WG['squadselection'] = {
		getCycling = function()
			return config.cyclingToNextSquad
		end
,
		setCycling = function(v)
			config.cyclingToNextSquad = v
		end
,
		getLeftClickSelects = function()
			return config.leftClickSelectsSquad
		end
,
		setLeftClickSelects = function(v)
			config.leftClickSelectsSquad = v
		end
,
		getRightClickSquadCreate = function()
			return config.rightClickSquadCreate
		end
,
		setRightClickSquadCreate = function(v)
			config.rightClickSquadCreate = v
		end
,
		getVisualizationMode = function()
			return config.visualizationMode
		end
,
		setVisualizationMode = function(v)
			if v == "convexHull" then
				create_airplane_floor()
			end
			config.visualizationMode = v
		end
,
	}

	if config.visualizationMode == "convexHull" then
		create_airplane_floor()
	end

	log("Initialized — " .. count .. " combat units across reserve squads")
	log_squads()
end


function widget:Shutdown()
	WG['squadselection'] = nil
	widgetHandler:RemoveAction("closest_squad_select")
	widgetHandler:RemoveAction("closest_squad_select_filtered")
	widgetHandler:RemoveAction("squad_create_toggle")
	widgetHandler:RemoveAction("squad_create")
	widgetHandler:RemoveAction("squad_select_group")
	widgetHandler:RemoveAction("squad_select_portion")
	widgetHandler:RemoveAction("squad_select_portion_filtered")
	widgetHandler:RemoveAction("squad_select_portion_group")
	widgetHandler:RemoveAction("squad_setting")
	log("Shutdown")
end


function widget:PlayerChanged(playerID)
	if playerID ~= spGetMyPlayerID() then
		return
	end
	if spGetSpectatingState() then
		log("Became spectator, shutting down")
		widgetHandler:RemoveWidget()
	end
end


function widget:GameOver()
	widgetHandler:RemoveWidget()
end


function widget:UnitCreated(unit_id, unit_def_id, unit_team, builder_id)
	if unit_team ~= spGetMyTeamID() then
		return
	end
	defid_of[unit_id] = unit_def_id or false

	if unit_def_id and is_combat[unit_def_id] then
		if builder_id and factory_squad[builder_id] then
			local sq = factory_squad[builder_id]
			add_to_squad(unit_id, sq)
			log("Unit " .. unit_id .. " created → factory squad [" .. (sq.letter or "?") .. "] (" .. #sq .. " units)")
		else
			local domain = unit_domain[unit_def_id]
			local sq = reserve_squads[domain]
			add_to_squad(unit_id, sq)
			log("Unit " .. unit_id .. " created → reserve:" .. domain .. " (" .. #sq .. " units)")
		end
	end
end


local last_idle_locations = {}
function widget:UnitDestroyed(unit_id, unit_def_id, unit_team, attacker_id)
	local tracked = unit_squad[unit_id] ~= nil
	local fq = factory_squad[unit_id]

	remove_from_squad(unit_id)
	defid_of[unit_id] = nil
	factory_squad[unit_id] = nil

	if fq then
		update_factory_squad_reserve(fq)
	end

	if tracked or fq then
		prune_empty_squads()
		log("Unit " .. unit_id .. " destroyed — " .. #squads .. " squad(s) remain")
	end

	-- location where a unit became idle is useful
	-- for constructing less visually obnoxious aircraft convex hulls
	last_idle_locations[unit_id] = nil
end


function widget:UnitTaken(unit_id, unit_def_id, unit_team, new_team)
	if unit_team ~= spGetMyTeamID() then
		return
	end

	local tracked = unit_squad[unit_id] ~= nil
	local fq = factory_squad[unit_id]

	remove_from_squad(unit_id)
	defid_of[unit_id] = nil
	factory_squad[unit_id] = nil

	if fq then
		update_factory_squad_reserve(fq)
	end

	if tracked or fq then
		prune_empty_squads()
		log("Unit " .. unit_id .. " taken by team " .. new_team)
	end
end


function widget:UnitGiven(unit_id, unit_def_id, unit_team, old_team)
	if unit_team ~= spGetMyTeamID() then
		return
	end
	defid_of[unit_id] = unit_def_id or false

	if unit_def_id and is_combat[unit_def_id] then
		local domain = unit_domain[unit_def_id]
		local sq = reserve_squads[domain]
		add_to_squad(unit_id, sq)
		log("Unit " .. unit_id .. " given to us → reserve:" .. domain .. " (" .. #sq .. " units)")
	end
end


-- idle detection for convex hull visualization: for less visually distracting aircraft hulls
function widget:UnitIdle(unitID, unitDefID, unitTeam)
	if unitTeam ~= spGetMyTeamID() then
		return
	end
	local x, y, z = spGetUnitPosition(unitID)
	local idle_pos = {
		x = x,
		y = y,
		z = z,
	}
	last_idle_locations[unitID] = idle_pos
end


-------------------------------------------------------------------------------
-- Input
-------------------------------------------------------------------------------
function widget:MousePress(x, y, button)
	if button == 3 and config.rightClickSquadCreate then
		local alt, ctrl, meta, shift = spGetModKeyState()
		if not (alt or ctrl or meta or shift) then
			create_squad_from_selection()
		end
	elseif button == 1 and config.leftClickSelectsSquad then
		local alt, ctrl, _, shift = spGetModKeyState()
		if alt or ctrl or shift then
			-- Skip when an active command is pending (fight, patrol, build, etc.)
			local _, cmdID = spGetActiveCommand()
			if cmdID then
				return
			end
			local cursor = spGetMouseCursor()
			local hit_type = spTraceScreenRay(x, y)
			local has_selection = spGetSelectedUnits()[1] ~= nil
			if (not has_selection or cursor == "Move") and hit_type ~= "unit" then
				if alt and shift then
					closest_squad_select_filtered(nil, nil, {"append"})
				elseif alt and ctrl then
					closest_squad_select_filtered(nil, nil, nil)
				elseif shift then
					closest_squad_select(nil, nil, {"append"})
				elseif ctrl then
					closest_squad_select(nil, nil, nil)
				end
			end
		end
	end
	-- Never return true: let the click pass through to the engine.
end


-------------------------------------------------------------------------------
-- Settings persistence (data/LuaUi/Config/BYAR.lua -> Squad Selection)
-------------------------------------------------------------------------------

function widget:SetConfigData(data)
	for key, value in pairs(data) do
		if config[key] ~= nil then
			config[key] = value
		end
	end
end


function widget:GetConfigData()
	return config
end


-------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------

function widget:DrawScreenEffects()
	if spIsGUIHidden() or config.visualizationMode ~= "coloredLabel" then
		return
	end

	for _, squad in ipairs(squads) do
		if #squad > 0 and squad.color and squad.letter then
			local c = squad.color
			glColor(c[1], c[2], c[3], 0.75)
			for j = 1, #squad do
				local _, _, _, x, y, z = spGetUnitPosition(squad[j], true)
				if x then
					local sx, sy = spWorldToScreenCoords(x, y, z - 40)
					if sx then
						glText(squad.letter, sx, sy, 10, "co")
					end
				end
			end
		end
		glColor(1, 1, 1, 1)
	end

	-- Draw labels on assigned factory buildings
	for fid, sq in pairs(factory_squad) do
		local c = sq.color
		glColor(c[1], c[2], c[3], 0.75)
		local _, _, _, x, y, z = spGetUnitPosition(fid, true)
		if x then
			local sx, sy = spWorldToScreenCoords(x, y, z)
			if sx then
				glText(sq.letter, sx, sy + 14, 16, "co")
			end
		end
	end

	glColor(1, 1, 1, 1)
end


-------------------------------------------------------------------------------
-- Convex hull
-------------------------------------------------------------------------------

-- the position for a unit that is used to create the convex hull
-- for a squad the unit is in
-- 
-- this is typically just the unit position
-- but idle aircraft use the position that they went idle at
local function unit_hull_reference_position(u)
	local command_queue_length = spGetUnitCommands(u, 0)
	local unit_def = get_defid(u)
	local domain = unit_def and unit_domain[unit_def]
	local x, y, z = spGetUnitPosition(u)
	if not command_queue_length or not x or not y or not z or not unit_def then
		return nil, nil, nil
	end -- return nil if unit got detroyed mid-function
	if command_queue_length > 0 then
		return x, y, z
	end
	local idle_pos = last_idle_locations[u]
	if idle_pos and domain == "air" then
		return idle_pos.x, idle_pos.y, idle_pos.z
	end
	return x, y, z
end


local function convex_hull(points)
	local function compare(a, b)
		return a.x < b.x or (a.x == b.x and a.y < b.y)
	end


	table.sort(points, compare)
	local function cross(o, a, b)
		return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
	end


	local hull = {}
	for _, p in ipairs(points) do
		while #hull >= 2 and cross(hull[#hull - 1], hull[#hull], p) <= 0 do
			table.remove(hull)
		end
		hull[#hull + 1] = p
	end
	local upper = {}
	for i = #points, 1, -1 do
		local p = points[i]
		while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], p) <= 0 do
			table.remove(upper)
		end
		upper[#upper + 1] = p
	end
	for i = 2, #upper - 1 do
		hull[#hull + 1] = upper[i]
	end
	return hull
end


-- Compute right normal for CCW edge
local function edge_normal(dx, dy)
	return dy, -dx
end


-- circle for squads with only one unit
local function padded_circle(center, radius, arc_segments_angle)
	local arc_angle = 2 * math.pi
	local segments = math.ceil(arc_angle / arc_segments_angle)
	segments = math.max(segments, 3)
	local points = {}
	for i = 0, segments - 1 do
		local angle = 2 * math.pi * i / segments
		points[#points + 1] = {
			x = center.x + radius * math.cos(angle),
			y = center.y + radius * math.sin(angle),
		}
	end
	return points
end


-- rounded padded convex hull for 2+ units
local function padded_more_than_one_unit(hull, radius, arc_segments_angle)
	local n = #hull
	local points = {}
	for i = 1, n do

		-- neighbors
		local prev = hull[i == 1 and n or i - 1]
		local curr = hull[i]
		local next = hull[i == n and 1 or i + 1]

		-- Edge directions
		local dx_prev, dy_prev = curr.x - prev.x, curr.y - prev.y
		local dx_next, dy_next = next.x - curr.x, next.y - curr.y

		-- Right normals (outward for CCW)
		local nx_prev, ny_prev = edge_normal(dx_prev, dy_prev)
		local nx_next, ny_next = edge_normal(dx_next, dy_next)

		-- Arc at corner from prev normal to next normal
		local angle_prev = math.atan2(ny_prev, nx_prev)
		local angle_next = math.atan2(ny_next, nx_next)
		local angle_diff = angle_next - angle_prev
		while angle_diff < 0 do
			angle_diff = angle_diff + 2 * math.pi
		end
		local arc_segments = math.ceil(angle_diff / arc_segments_angle)
		arc_segments = math.max(arc_segments, 1)
		for j = 0, arc_segments do
			local t = j / arc_segments
			local theta = angle_prev + t * angle_diff
			points[#points + 1] = {
				x = curr.x + radius * math.cos(theta),
				y = curr.y + radius * math.sin(theta),
			}
		end
	end
	return points
end


-- Choose the correct function for the current squad
local function get_padded_hull(worldPoints, radius, arc_segments_angle)
	if #worldPoints == 1 then
		return padded_circle(worldPoints[1], radius, arc_segments_angle)
	elseif #worldPoints >= 2 then
		local hull = convex_hull(worldPoints)
		return padded_more_than_one_unit(hull, radius, arc_segments_angle)
	else
		return {}
	end
end


local team_r, team_g, team_b, team_a = spGetTeamColor(spGetMyTeamID())
local HULL_PARAMETERS_FULLY_SELECTED = {
	fillColor = {1, 1, 1, config.convexHullFillOpacity},
	borderColor = {1, 1, 1, config.convexHullBorderOpacity},
	borderThickness = config.convexHullBorderThickness,
}
local HULL_PARAMETERS_UNSELECTED = {
	fillColor = {team_r, team_g, team_b, config.convexHullFillOpacity},
	borderColor = {team_r, team_g, team_b, config.convexHullBorderOpacity},
	borderThickness = config.convexHullBorderThickness,
}

function widget:DrawWorldPreUnit()
	if spIsGUIHidden() or config.visualizationMode ~= "convexHull" then
		return
	end

	if not squads or #squads == 0 then
		return
	end

	-- build list of selected units, for later use
	local selectedUnitList = spGetSelectedUnits()
	local selectedUnits = {}
	for _, id in ipairs(selectedUnitList) do
		selectedUnits[id] = true
	end

	for _, squad in ipairs(squads) do

		if not squad.is_reserve then

			-- determine color styling
			-- based on whether all units in the squad are selected
			local allSelected = true
			for _, unitID in ipairs(squad) do
				if not selectedUnits[unitID] then
					allSelected = false
					break
				end
			end
			local params = allSelected and HULL_PARAMETERS_FULLY_SELECTED or HULL_PARAMETERS_UNSELECTED

			-- collect unit positions (in world coordinates?)
			local worldPoints = {}
			for _, unitID in ipairs(squad) do
				local x, y, z = unit_hull_reference_position(unitID)
				if x and y and z then
					worldPoints[#worldPoints + 1] = {
						x = x,
						y = z,
					}
				end
			end

			-- determine domains present in the squad
			local air_present = false
			local land_present = false
			local navy_present = false
			for _, unitID in ipairs(squad) do
				local unit_def = get_defid(unitID)
				if unit_def then
					if unit_domain[unit_def] == "naval" then
						navy_present = true
					end
					if unit_domain[unit_def] == "land" then
						land_present = true
					end
					if unit_domain[unit_def] == "air" then
						air_present = true
					end
				end
			end

			-- calculate and draw hull
			if #worldPoints > 0 then

				local radius = config.convexHullPaddingLand
				if navy_present then
					radius = config.convexHullPaddingNavy
				end
				if air_present then
					radius = config.convexHullPaddingAir
				end

				-- calculate the 2d hull
				local paddedHull = get_padded_hull(worldPoints, radius, config.convexHullArcResolution)

				-- calculate the 3d projection of this hull
				local screenHull = {}
				for _, p in ipairs(paddedHull) do
					local h = 0
					if air_present then
						h = airplane_floor_height(p.x, p.y) + config.convexHullAirHeightBoost
					end
					if navy_present then
						h = 0
					end
					if land_present then
						h = spGetGroundHeight(p.x, p.y)
					end
					screenHull[#screenHull + 1] = {
						x = p.x,
						y = h,
						z = p.y,
					}
				end

				-- draw the hull
				glDepthTest(false)
				glColor(params.fillColor)
				glBeginEnd(GL.POLYGON, function()
					for _, p in ipairs(screenHull) do
						glVertex(p.x, p.y, p.z)
					end
				end
)
				glColor(params.borderColor)
				glLineWidth(params.borderThickness)
				glBeginEnd(GL.LINE_LOOP, function()
					for _, p in ipairs(screenHull) do
						glVertex(p.x, p.y, p.z)
					end
				end
)
				glDepthTest(true)
				glColor(1, 1, 1, 1)
				glLineWidth(1)
			end
		end
	end
end

