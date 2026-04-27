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
	leftClickSteps = {1, 0.5, "distance_850"}, -- step values + optional distance cap for left-click selection; {1} = whole squad, {"distance_850", 0.5, 1} = 50% then 100% within 850 elmos
	leftClickStepsEnabled = false, -- when true, left-click (replace and append) uses leftClickSteps; when false (default), both use {1} (whole squad, no distance cap). Bind a hotkey via `squad_setting toggle leftClickStepsEnabled` to flip on demand
	leftClickAppendFiltersDomain = true, -- when true, left-click Shift-append only cycles into squads whose domains ⊆ the selection's; when false, append behaves like the plain `append` keyword
	leftClickFilteredRetargets = false, -- when true, Alt+Ctrl-click (replace-mode filtered) acts like the `retarget` keyword: if the closest unit's type isn't in the current selection, treat the click as a fresh selection on that new type instead of using the selection's types as the filter. Append mode is unaffected.
	cyclingToNextSquad = true, -- when full squad/type is selected, exclude it to cycle to next
	rightClickSquadCreate = false, -- right-click creates squads; bind a hotkey via `squad_setting toggle rightClickSquadCreate` to flip on demand
	modifierRightClickCreatesSquad = false, -- Ctrl+right-click creates a squad (click still passes through, so the engine's move-in-formation runs too which can cause issues)
	viewselectionDoubleTapMs = 300, -- second rapid same-place non-append squad-select tap (single-step, or multi-step at the last step) calls viewselection on the just-selected squad (0 disables)
	viewselectionDoubleTapPx = 5, -- max screen-pixel distance between the two taps
	mruSize = 3, -- how many recent squads squad_cycle_recent cycles through
	excludedUnitTypes = "", -- comma-separated unit names to exclude from squad tracking (e.g. "armrectr,cornecro")
	showReserveSquads = false, -- when true, auto per-factory reserves + uncategorized reserve are visualized
	visualizationMode = "convexHull", -- "convexHull" or "coloredLabel"
	convexHullPadding = 60, -- space (in elmos) between the units and the hull boundary
	convexHullArcResolution = 0.4, -- angle that each chord of the arc spans in radians; smaller = smoother but more expensive
	convexHullFillOpacity = 0.1,
	convexHullBorderOpacity = 0.2,
	convexHullBorderThickness = 2,
	debug = false,
}

-- Snapshot of the defaults defined above, used by `squad_setting reload`.
local config_defaults = {}
for k, v in pairs(config) do
	config_defaults[k] = v
end

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
local spSendCommands = Spring.SendCommands
local spGetMiniMapGeometry = Spring.GetMiniMapGeometry
local spIsSphereInView = Spring.IsSphereInView
local spGetTimer = Spring.GetTimer
local spDiffTimers = Spring.DiffTimers

local glColor = gl.Color
local glText = gl.Text
local glDepthTest = gl.DepthTest
local glLineWidth = gl.LineWidth
local glCreateShader = gl.CreateShader
local glDeleteShader = gl.DeleteShader
local glUseShader = gl.UseShader
local glGetUniformLocation = gl.GetUniformLocation
local glUniform = gl.Uniform
local glGetVBO = gl.GetVBO
local glGetVAO = gl.GetVAO

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local squads = {} -- ordered list of squad arrays
local unit_squad = {} -- unitID -> the squad array it belongs to
local unit_slot = {} -- unitID -> index within that squad (for O(1) removal)
local factory_squad = {} -- factoryUnitID -> squad (every factory gets an auto-created squad)
local uncategorized_reserve = {} -- domain -> reserve squad ("land" | "air" | "naval") for units with no factory origin

local mru = {} -- most-recently-used squads, newest at index 1

local squad_sel_count = {} -- squad table -> number of selected units in it
local selection_dirty = true -- forces a full recount on the first draw frame
local squad_idle_state = {} -- squad table -> true when >=50% of the squad is idle
local squad_idle_blend = {} -- squad table -> 0..1 blend between team color and idle color
local squad_hide_idle_air_hull = {} -- squad table -> true when an idle squad is entirely airborne air units
local idle_scan_index = 0 -- round-robin index into squads for incremental idle-state updates

-- Unit classification caches (declared early so utility helpers capture locals,
-- not globals).
local defid_of = {} -- unitID -> defID (false when lookup fails)
local is_combat = {} -- defID -> bool
local is_factory = {} -- defID -> bool (immobile with buildOptions)
local is_strafing_air = {} -- defID -> bool (air units that strafe/fly around while idle)
local unit_domain = {} -- defID -> "land" | "air" | "naval"

local last_squad_select = nil -- { t, x, y, append, squad } of most recent successful do_squad_select; powers two same-mode double-tap gestures (replace→replace fires viewselection, append→append upgrades plain append to append_domain) and gates the reserve-merge branch of create_squad_from_selection on `squad`

-------------------------------------------------------------------------------
-- Debug
-------------------------------------------------------------------------------

-- Varargs so call sites pay no concatenation cost when debug is off.
local function log(...)
	if not config.debug then
		return
	end
	local n = select("#", ...)
	if n == 1 then
		spEcho("[Squad] " .. tostring((...)))
		return
	end
	local parts = {...}
	for i = 1, n do
		parts[i] = tostring(parts[i])
	end
	spEcho("[Squad] " .. table.concat(parts))
end


local function log_squads()
	if not config.debug then
		return
	end
	log("  ", #squads, " squad(s):")
	for _, squad in ipairs(squads) do
		local label = squad.letter or "?"
		if squad.uncat_domain then
			label = label .. ":uncat-" .. squad.uncat_domain
		elseif squad.from_factory then
			label = label .. ":fac"
		end
		log("    [", label, "] ", #squad, " units")
	end
end


-------------------------------------------------------------------------------
-- Utility
-------------------------------------------------------------------------------

-- more readable way to limit a value at two ends
local function constrain(x, min, max)
	return math.max(min, math.min(max, x))
end


-- Recompute whether a squad is "idle" (>=50% units with no commands).
local function refresh_squad_idle_state(sq)
	local size = #sq
	if size == 0 then
		squad_idle_state[sq] = false
		squad_hide_idle_air_hull[sq] = false
		return false
	end

	local threshold = math.ceil(size * 0.5)
	local idle = 0
	local idle_reached = false
	for i = 1, size do
		if spGetUnitCommands(sq[i], 0) == 0 then
			idle = idle + 1
			if idle >= threshold then
				idle_reached = true
				break
			end
		end
		if idle + (size - i) < threshold then
			break
		end
	end

	if not idle_reached then
		squad_idle_state[sq] = false
		squad_hide_idle_air_hull[sq] = false
		return false
	end

	squad_idle_state[sq] = true

	-- Hide hull only when the whole squad is strafing-air and currently flying.
	local hide_hull = true
	for i = 1, size do
		local u = sq[i]
		local def_id = defid_of[u]
		if not (def_id and is_strafing_air[def_id]) then
			hide_hull = false
			break
		end
		local x, y, z = spGetUnitPosition(u)
		if not x then
			hide_hull = false
			break
		end
		if y <= spGetGroundHeight(x, z) + 50 then
			hide_hull = false
			break
		end
	end
	squad_hide_idle_air_hull[sq] = hide_hull
	return true
end


local function sweep_idle_state()
	local present = {}
	for i = 1, #squads do
		present[squads[i]] = true
	end
	for sq, _ in pairs(squad_idle_state) do
		if not present[sq] then
			squad_idle_state[sq] = nil
			squad_idle_blend[sq] = nil
			squad_hide_idle_air_hull[sq] = nil
		end
	end
end


-------------------------------------------------------------------------------
-- Squad appearance
--
-- Each squad gets a color and a letter, assigned on
-- creation.  These are stored directly on the squad table as string-keyed
-- fields (squad.color, squad.letter) which don't interfere with the integer-
-- keyed unit list or #squad.
-------------------------------------------------------------------------------

local SQUAD_COLORS = { -- should be removed, use hue rotation instead with one sat/val combo
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

local function assign_squad_tag(squad)
	next_squad_tag = next_squad_tag + 1
	local ci = (next_squad_tag - 1) % #SQUAD_COLORS + 1
	local li = (next_squad_tag - 1) % #SQUAD_LETTERS + 1
	squad.color = SQUAD_COLORS[ci]
	squad.letter = SQUAD_LETTERS:sub(li, li)
end


-- Unit classification
--
-- is_combat[defID] — true if the unit type is squad-eligible.
-------------------------------------------------------------------------------

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


--- Pre-compute is_combat for every defID in one pass.
local function classify_unitdefs()
	for defID, def in pairs(UnitDefs) do
		-- Squad eligibility, speed is needed because of mines
		if def.canMove and def.speed and def.speed > 0 and not (def.buildOptions and #def.buildOptions > 0) then
			is_combat[defID] = true
		else
			is_combat[defID] = false
		end

		if def.isFactory then
			is_factory[defID] = true
		end

		is_strafing_air[defID] = def.isStrafingAirUnit and true or false

		if def.canFly then
			unit_domain[defID] = "air"
		elseif def.minWaterDepth and def.minWaterDepth > 0 then
			unit_domain[defID] = "naval"
		else
			unit_domain[defID] = "land"
		end
	end

	-- Apply user exclusions.
	if config.excludedUnitTypes and config.excludedUnitTypes ~= "" then
		for name in config.excludedUnitTypes:gmatch("[^,]+") do
			name = name:match("^%s*(.-)%s*$") -- trim whitespace
			for defID, def in pairs(UnitDefs) do
				if def.name == name then
					is_combat[defID] = false
					break
				end
			end
		end
	end
end

local function reserve_domain_for_def(def_id)
	return unit_domain[def_id] or "land"
end

local function get_uncategorized_reserve_for_def(def_id)
	local d = reserve_domain_for_def(def_id)
	return uncategorized_reserve[d] or uncategorized_reserve.land
end


-------------------------------------------------------------------------------
-- Squad operations
-------------------------------------------------------------------------------

local function add_to_squad(unit_id, squad)
	local slot = #squad + 1
	squad[slot] = unit_id
	unit_squad[unit_id] = squad
	unit_slot[unit_id] = slot
	squad_idle_state[squad] = false
	squad_hide_idle_air_hull[squad] = false
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
	squad_idle_state[squad] = false
	squad_hide_idle_air_hull[squad] = false
end


-------------------------------------------------------------------------------
-- MRU (most-recently-used squads)
--
-- Push points are both inside create_squad_from_selection: successful squad
-- creation, and right-click on a selection that already matches an existing squad. 
-- Plain selection changes and command issuance do NOT push.
-- Players who disable rightClickSquadCreate still populate the MRU via the
-- squad_create action, which routes through the same function.
-------------------------------------------------------------------------------

local function push_to_mru(sq)
	if not sq then
		return
	end
	for i = 1, #mru do
		if mru[i] == sq then
			table.remove(mru, i)
			break
		end
	end
	table.insert(mru, 1, sq)
	while #mru > config.mruSize do
		mru[#mru] = nil
	end
end


local function sweep_mru()
	local present = {}
	for _, sq in ipairs(squads) do
		present[sq] = true
	end
	for i = #mru, 1, -1 do
		if not present[mru[i]] then
			table.remove(mru, i)
		end
	end
end


local function recall_mru(i)
	local sq = mru[i]
	if not sq then
		return
	end
	local units = {}
	for j = 1, #sq do
		units[j] = sq[j]
	end
	spSelectUnitArray(units)
	spSendCommands("viewselection")
end


-- A squad is prunable when empty, except:
--   - the uncategorized reserve is permanent
--   - factory reserves are kept while any factory still references them
local function is_prunable(sq)
	if #sq ~= 0 then
		return false
	end
	if sq.uncat_domain then
		return false
	end
	if sq.from_factory then
		for _, fsq in pairs(factory_squad) do
			if fsq == sq then
				return false
			end
		end
		return true
	end
	return not sq.is_reserve
end


local function prune_empty_squads()
	for i = #squads, 1, -1 do
		local sq = squads[i]
		if is_prunable(sq) then
			log("Squad [", sq.letter or "?", "] emptied and removed")
			squad_sel_count[sq] = nil
			table.remove(squads, i)
		end
	end
	sweep_mru()
	sweep_idle_state()
end


-------------------------------------------------------------------------------
-- Squad creation from selection
-------------------------------------------------------------------------------

-- Returns true if `unit_id`'s command queue contains a CMD_WAIT anywhere.
-- Used by the uncategorized-reserve path in UnitCreated to skip the selection
-- auto-extend for a freshly resurrected unit (rez bots leave units in
-- CMD_WAIT until fully healed).
local function unit_queue_has_wait(unit_id)
	local cmds = spGetUnitCommands(unit_id, -1)
	if not cmds then
		return false
	end
	for i = 1, #cmds do
		if cmds[i].id == CMD.WAIT then
			return true
		end
	end
	return false
end


-- Returns true if the factory's command queue ends with CMD_WAIT or
-- CMD_PATROL — i.e. the rally's last waypoint is a "stay busy here" signal
-- rather than a move-and-forget. Used to opt the reserve out of the
-- selection auto-extend in UnitCreated.
local function factory_rally_ends_with_wait_or_patrol(factory_id)
	local cmds = spGetUnitCommands(factory_id, -1)
	if not cmds or #cmds == 0 then
		return false
	end
	local last_id = cmds[#cmds].id
	return last_id == CMD.WAIT or last_id == CMD.PATROL
end


-- Returns true if every unit in `sq` is present in `selected_set`.
-- Empty squads return false to avoid vacuous matches.
local function squad_fully_selected(sq, selected_set)
	if #sq == 0 then
		return false
	end
	for i = 1, #sq do
		if not selected_set[sq[i]] then
			return false
		end
	end
	return true
end


-- Returns the squad if the selection's combat units exactly match one squad
-- (including reserves), nil otherwise.
local function selection_is_existing_squad(selected)
	local squad = nil
	local combat_count = 0
	for i = 1, #selected do
		local u = selected[i]
		local def_id = get_defid(u)
		if def_id and is_combat[def_id] then
			combat_count = combat_count + 1
			local s = unit_squad[u]
			if squad == nil then
				squad = s
			elseif s ~= squad then
				return nil
			end
		end
	end
	if squad == nil or #squad ~= combat_count then
		return nil
	end
	return squad
end


--- Create a new hidden reserve squad and register it in `squads`.
-- Used for per-factory auto-squads and the uncategorized reserve.
local function make_reserve_squad(from_factory)
	local sq = {}
	assign_squad_tag(sq)
	sq.color = {1, 1, 1}
	sq.is_reserve = true
	sq.from_factory = from_factory or false
	-- Stripe phase shift in periods. Golden-ratio step over the squad tag spreads
	-- consecutive squads ~0.618 of a period apart, so adjacent reserves can't align.
	-- Multiplied by the period at draw time.
	sq.stripe_offset = next_squad_tag * 0.6180339887
	squads[#squads + 1] = sq
	return sq
end


--- Auto-create a reserve squad for a newly built/received factory.
local function create_factory_squad(factory_id)
	local sq = make_reserve_squad(true)
	factory_squad[factory_id] = sq
	log("Factory ", factory_id, " → auto squad [", sq.letter, "]")
	return sq
end


--- "This selection becomes one squad" — merges or splits depending on state.
--  - If the selection already exactly occupies one squad (no other factories
--    reference it) → no-op.
--  - Otherwise → reassign all selected factories to a fresh shared squad.
--    Units already built stay in their old squads
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

	-- Detect the "already exactly one squad" case.
	local selection_set = {}
	for i = 1, #factories do
		selection_set[factories[i]] = true
	end
	local shared = factory_squad[factories[1]]
	local all_share = shared ~= nil
	for i = 2, #factories do
		if factory_squad[factories[i]] ~= shared then
			all_share = false
			break
		end
	end
	if all_share then
		local extra = false
		for fid, sq in pairs(factory_squad) do
			if sq == shared and not selection_set[fid] then
				extra = true
				break
			end
		end
		if not extra then
			return
		end
	end

	-- Reassign all selected factories to a fresh shared squad.
	local new_squad = make_reserve_squad(true)
	for i = 1, #factories do
		factory_squad[factories[i]] = new_squad
	end

	prune_empty_squads()

	log("Factory squad [", new_squad.letter, "] assigned to ", #factories, " factory(s)")
	log_squads()
end


local function create_squad_from_selection()
	local selected = spGetSelectedUnits()
	if #selected == 0 then
		return
	end

	local existing = selection_is_existing_squad(selected)
	if existing and not existing.is_reserve then
		push_to_mru(existing)
		return
	end

	-- `existing` being nil here means the selection spans more than one squad
	-- (or partial squads). If it fully contains a reserve squad in that mix
	-- AND the player's last widget squad-select targeted that same reserve,
	-- merge the rest of the selection INTO that reserve instead of creating a
	-- new manual squad. First match wins. When the selection is exactly one
	-- reserve (`existing` set + is_reserve), we skip this branch and fall
	-- through to new-squad creation — extracting the reserve into a manual
	-- squad is the intended action in that case.
	--
	-- The `last_squad_select.squad == sq` gate captures player intent: merging
	-- only happens when the player explicitly squad-selected the reserve via
	-- the widget. Manual selections that happen to include all of a (possibly
	-- one-unit) reserve don't trigger merges — common case is selecting a
	-- fresh factory output to reinforce a manual squad, where the new unit's
	-- reserve being trivially "fully selected" used to swallow the manual
	-- squad on squad_create.
	local target_reserve = last_squad_select and last_squad_select.squad
	if not existing and target_reserve and target_reserve.is_reserve then
		local selected_set = {}
		for i = 1, #selected do
			selected_set[selected[i]] = true
		end
		for _, sq in ipairs(squads) do
			if sq == target_reserve and squad_fully_selected(sq, selected_set) then
				local moved = 0
				for i = 1, #selected do
					local u = selected[i]
					local def_id = get_defid(u)
					if def_id and is_combat[def_id] and unit_squad[u] ~= sq then
						remove_from_squad(u)
						add_to_squad(u, sq)
						moved = moved + 1
					end
				end
				prune_empty_squads()
				selection_dirty = true
				push_to_mru(sq)

				local units = {}
				for i = 1, #sq do
					units[i] = sq[i]
				end
				spSelectUnitArray(units)

				log("Merged ", moved, " unit(s) → reserve squad [", sq.letter or "?", "]")
				log_squads()
				return
			end
		end
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

	-- A non-reserve source squad fully consumed by the selection is now
	-- empty; inherit its identity so the player's "real" squad carries on
	-- under the same color/letter instead of getting a fresh one.
	local donor
	for _, sq in ipairs(squads) do
		if #sq == 0 and not sq.is_reserve then
			donor = sq
			break
		end
	end

	if donor then
		new_squad.color, new_squad.letter = donor.color, donor.letter
	else
		assign_squad_tag(new_squad)
	end
	squads[#squads + 1] = new_squad
	prune_empty_squads()
	-- Selection itself didn't change, but selected units moved between squads.
	-- Force DrawWorldPreUnit to rebuild per-squad selected counts.
	selection_dirty = true
	push_to_mru(new_squad)

	log("New squad [", new_squad.letter, "]: ", #new_squad, " units")
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

	-- PIP minimap: when active, the engine minimap is hidden/minimized so
	-- spGetMiniMapGeometry() returns stale data. Use the WG API instead.
	local wg_minimap = WG and WG['minimap']
	local wg_pip0 = WG and WG['pip0']
	local pip_minimized = wg_pip0 and wg_pip0.IsMinimized and wg_pip0.IsMinimized()
	if wg_minimap and wg_minimap.isPipMinimapActive and wg_minimap.isPipMinimapActive() and not pip_minimized then
		local getBounds = wg_minimap.getScreenBounds
		if getBounds then
			local l, b, r, t = getBounds()
			if l and r > l and t > b and mx >= l and mx <= r and my >= b and my <= t then
				local rx = (mx - l) / (r - l)
				local ry = (my - b) / (t - b)
				local wx = Game.mapSizeX * rx
				local wz = Game.mapSizeZ - Game.mapSizeZ * ry
				return wx, wz
			end
		end
	end

	-- Standard minimap (engine geometry).
	local mmX, mmY, mmW, mmH, minimized, maximized = spGetMiniMapGeometry()
	if mmX and mmW > 0 and mmH > 0 and not minimized and not maximized then
		local rx = (mx - mmX) / mmW
		local ry = (my - mmY) / mmH
		if rx >= 0 and rx <= 1 and ry >= 0 and ry <= 1 then
			local wx = Game.mapSizeX * rx
			local wz = Game.mapSizeZ - Game.mapSizeZ * ry
			return wx, wz
		end
	end

	-- Normal path: trace screen ray into the 3D world.
	local _, coords = spTraceScreenRay(mx, my, true)
	if not coords then
		return nil
	end
	return coords[1], coords[3] -- world x, world z
end


-- Returns the squad containing the unit closest to (wx, wz), or nil if none.
-- Optional filter_defs (defID set), group_set (unitID set), and exclude
-- (unitID set) narrow the search. A unit is a candidate only if it passes all
-- three filters.
-- domain_filter (set of allowed domain strings) rejects entire squads whose
-- units include any domain not in the set — so e.g. a pure-land filter skips
-- mixed land+air squads, not just their air units.
local function find_closest_squad(filter_defs, group_set, exclude, wx, wz, domain_filter)
	local best_unit = nil
	local best_dist_sq = math.huge

	for _, squad in ipairs(squads) do
		local squad_ok = true
		if domain_filter then
			for j = 1, #squad do
				local d = unit_domain[defid_of[squad[j]]]
				if d and not domain_filter[d] then
					squad_ok = false
					break
				end
			end
		end
		if squad_ok then
			for j = 1, #squad do
				local u = squad[j]
				if not (exclude and exclude[u]) and not (group_set and not group_set[u]) then
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
	end

	return best_unit and unit_squad[best_unit] or nil, best_unit
end


-------------------------------------------------------------------------------
-- Selection analysis
-------------------------------------------------------------------------------

--- Inspect the current selection and return a summary used by squad-select actions.
--
-- Returns a table with:
--   selected_set        — set (unitID → true) for O(1) membership tests
--   selected_type_set   — set of defIDs present in the selection (only from
--                          tracked squad units). Used to filter squads by unit
--                          type, e.g. "select all Grunts in the closest squad".
--   selected_domain_set — set of domains ("land"/"air"/"naval") in the
--                          selection. Used by append_domain to constrain
--                          cycling to compatible squads.
--   has_tracked_units   — true when at least one selected unit is a tracked
--                          squad unit with a known type. When false, callers
--                          fall back to type-agnostic behavior.
local function analyze_selection()
	local selected = spGetSelectedUnits()
	local selected_set = {}
	local selected_type_set = {}
	local selected_domain_set = {}
	local has_tracked_units = false

	for i = 1, #selected do
		local u = selected[i]
		selected_set[u] = true
		if unit_squad[u] then
			local def_id = defid_of[u]
			if def_id then
				selected_type_set[def_id] = true
				local d = unit_domain[def_id]
				if d then
					selected_domain_set[d] = true
				end
				has_tracked_units = true
			end
		end
	end

	return {
		selected_set = selected_set,
		selected_type_set = selected_type_set,
		selected_domain_set = selected_domain_set,
		has_tracked_units = has_tracked_units,
	}
end


-------------------------------------------------------------------------------
-- Selection primitives
--
-- All six selection actions share one core, do_squad_select. The per-action
-- wrappers only differ in which opts they pass:
--
--   whole-squad / filtered / group    → steps={1}, cycle_when_full=true
--   portion / portion-filtered /group → steps=<parsed>, cycle_when_full=false
--
-- Filtering by unit type and by control group is expressed uniformly via the
-- filter_defs / group_set options.
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


--- Parse portion action args: optional "append"/"append_domain" keyword,
-- optional "distance_<N>" modifier that caps selection to units within N
-- world-distance of the cursor, plus step numbers. "append_domain" implies
-- append and additionally restricts squad cycling to domains present in the
-- current selection.
local function parse_portion_args(args)
	if not args then
		return false, false, {}, nil, false
	end
	local append = false
	local use_domain_filter = false
	local retarget = false
	local steps = {}
	local max_distance
	for i = 1, #args do
		local arg = args[i]
		if arg == "append" then
			append = true
		elseif arg == "append_domain" then
			append = true
			use_domain_filter = true
		elseif arg == "retarget" then
			retarget = true
		elseif type(arg) == "string" and arg:sub(1, 9) == "distance_" then
			local d = tonumber(arg:sub(10))
			if d and d > 0 then
				max_distance = d
			end
		else
			local n = tonumber(arg)
			if n then
				steps[#steps + 1] = n
			end
		end
	end
	return append, use_domain_filter, steps, max_distance, retarget
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


--- Build a squad's pool(s): units matching the optional filters.
-- Returns (pool, step_pool). step_pool is the filter-only pool used for step
-- progression; pool is step_pool additionally capped to units within
-- max_distance_sq of (wx, wz). When max_distance_sq is nil the two are the
-- same array.
local function build_pools(squad, filter_defs, group_set, max_distance_sq, wx, wz)
	local step_pool = {}
	local pool = max_distance_sq and {} or step_pool
	for j = 1, #squad do
		local u = squad[j]
		if (not group_set or group_set[u]) and (not filter_defs or (defid_of[u] and filter_defs[defid_of[u]])) then
			step_pool[#step_pool + 1] = u
			if max_distance_sq then
				local ux, _, uz = spGetUnitPosition(u)
				if ux then
					local dx = ux - wx
					local dz = uz - wz
					if dx * dx + dz * dz <= max_distance_sq then
						pool[#pool + 1] = u
					end
				end
			end
		end
	end
	return pool, step_pool
end


--- Count how many pool units are already selected.
local function count_selected_in(pool, selected_set)
	local n = 0
	for i = 1, #pool do
		if selected_set[pool[i]] then
			n = n + 1
		end
	end
	return n
end


--- True when every unit in pool is in selected_set. 
local function pool_fully_selected(pool, selected_set)
	for i = 1, #pool do
		if not selected_set[pool[i]] then
			return false
		end
	end
	return true
end


--- Walk the step progression: return the first resolved count greater than
-- `current_in_pool`, or the last step's count once we're past the end
-- (no-op repeat).
local function resolve_target_count(steps, pool_size, current_in_pool)
	for i = 1, #steps do
		local c = step_to_count(steps[i], pool_size)
		if c > current_in_pool then
			return c
		end
	end
	return step_to_count(steps[#steps], pool_size)
end


--- Given a distance-sorted pool, pick which units go to SelectUnitArray.
-- Replace mode: first `target_count` pool units.
-- Append mode: up to `target_count` closest pool units that aren't already
-- selected (so repeated presses accumulate).
local function pick_units(pool, target_count, selected_set, append)
	local to_select = {}
	if append then
		for i = 1, #pool do
			if not selected_set[pool[i]] then
				to_select[#to_select + 1] = pool[i]
				if #to_select >= target_count then
					break
				end
			end
		end
	else
		for i = 1, target_count do
			to_select[i] = pool[i]
		end
	end
	return to_select
end


--- Determine the defID set for filtered actions. Uses the selection's types
-- if any tracked units are selected; otherwise falls back to the closest
-- unit's type. Returns nil when nothing suitable is found (caller bails).
local function resolve_filter_defs(sel, wx, wz)
	if sel.has_tracked_units then
		return sel.selected_type_set
	end
	local _, closest = find_closest_squad(nil, nil, nil, wx, wz)
	if not closest then
		return nil
	end
	local def_id = defid_of[closest]
	if not def_id then
		return nil
	end
	return {
		[def_id] = true,
	}
end


--- Retarget variant: in replace mode, always peek the closest unit. If its
-- type is in the current selection's types, behave like resolve_filter_defs
-- (use the selection). If not, treat the click as a fresh selection on that
-- single new type — letting the player swing the filter to a different unit
-- type without first deselecting.
local function resolve_retarget_filter_defs(sel, wx, wz)
	local _, closest = find_closest_squad(nil, nil, nil, wx, wz)
	if not closest then
		return resolve_filter_defs(sel, wx, wz)
	end
	local def_id = defid_of[closest]
	if not def_id then
		return resolve_filter_defs(sel, wx, wz)
	end
	if sel.has_tracked_units and sel.selected_type_set[def_id] then
		return sel.selected_type_set
	end
	return {
		[def_id] = true,
	}
end


--- Build a set of unitIDs belonging to a control group.
-- Tries GetGroupUnits first, falls back to iterating tracked units. (I copied this from another widget, I'm not sure how necessary it is)
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


-------------------------------------------------------------------------------
-- Unified squad selection core
--
-- opts = {
--   append             bool,
--   steps              array of step values; nil → {1} (whole pool),
--   filter_defs        nil or defID set (narrow pool to matching types),
--   group_set          nil or unitID set (narrow pool to group members),
--   max_distance       nil or number — cap pool to units within that world
--                      distance from the cursor,
--   cycle_when_full    bool — when the closest squad's pool is already fully
--                      selected, re-pick a squad with those units excluded,
--   use_domain_filter  bool — restrict squad cycling to domains
--                      ("land"/"air"/"naval") present in the selection.
--                      Ignored when no tracked units are selected.
-- }
-------------------------------------------------------------------------------

local function do_squad_select(opts)
	local steps = opts.steps or {1}
	if #steps == 0 then
		return
	end

	local wx, wz = get_mouse_world_pos()
	if not wx then
		return
	end

	local mx, my = spGetMouseState()

	-- Compute the double-tap window match against the *previous* tap, then
	-- snapshot its append flag before we overwrite last_squad_select below.
	local in_double_tap_window = false
	local prev_append = false
	if last_squad_select and config.viewselectionDoubleTapMs > 0 then
		local dt_ms = spDiffTimers(spGetTimer(), last_squad_select.t, true)
		local dx = mx - last_squad_select.x
		local dy = my - last_squad_select.y
		local px = config.viewselectionDoubleTapPx
		in_double_tap_window = dt_ms < config.viewselectionDoubleTapMs and (dx * dx + dy * dy) < (px * px)
		prev_append = last_squad_select.append
	end

	-- Arm now (not at the end) so subsequent taps detect this one even when the selection ends up a no-op.
	-- `squad` is filled in below once the final target is known; staying nil on no-ops is the correct
	-- signal for create_squad_from_selection's reserve-merge gate (no widget selection happened).
	last_squad_select = {
		t = spGetTimer(),
		x = mx,
		y = my,
		append = opts.append,
		squad = nil,
	}

	-- Single-step same-mode double-tap dispatch. Replace→replace fires
	-- viewselection. Append→append flips the domain
	-- filter — `append` upgrades to `append_domain`, `append_domain`
	-- downgrades to `append`. Same flip happens regardless of how the action
	-- was invoked (hotkey or left-click)
	if in_double_tap_window and #steps == 1 and prev_append == opts.append then
		if opts.append then
			opts.use_domain_filter = not opts.use_domain_filter
		else
			spSendCommands("viewselection")
			last_squad_select = nil
			return
		end
	end

	local sel = analyze_selection()
	local filter_defs = opts.filter_defs
	local group_set = opts.group_set
	local max_distance_sq = opts.max_distance and opts.max_distance * opts.max_distance or nil
	local domain_filter = opts.use_domain_filter and sel.has_tracked_units and sel.selected_domain_set or nil

	local target_squad = find_closest_squad(filter_defs, group_set, nil, wx, wz, domain_filter)
	if not target_squad then
		return
	end
	local pool, step_pool = build_pools(target_squad, filter_defs, group_set, max_distance_sq, wx, wz)

	if #step_pool == 0 then
		return
	end

	-- Multi-step calls need current_in_step_pool to advance through the step
	-- progression; single-step ones only need fully_selected, which is a pure
	-- function of pool size and selection.
	local current_in_step_pool
	if #steps > 1 then
		current_in_step_pool = count_selected_in(step_pool, sel.selected_set)
	end
	local fully_selected = #pool > 0 and pool_fully_selected(pool, sel.selected_set)

	-- Double-tap viewselection (late): multi-step replace fires only when the
	-- player has already reached the last step (no progression left), so
	-- intermediate taps still advance through steps as normal. Same same-mode
	-- gating as the early check — only replace→replace triggers.
	if in_double_tap_window and #steps > 1 and not opts.append and not prev_append and #pool > 0 and current_in_step_pool >= step_to_count(steps[#steps], #step_pool) then
		spSendCommands("viewselection")
		last_squad_select = nil
		return
	end

	if opts.cycle_when_full and fully_selected then
		-- If cycling finds no other squad (e.g. the player previously appended
		-- their way through every squad so nothing is unselected), keep the
		-- original target so a replace tap still replaces with the closest
		-- squad instead of silently doing nothing. For append, the empty
		-- pick_units result later short-circuits to a no-op.
		local cycled_target = find_closest_squad(filter_defs, group_set, sel.selected_set, wx, wz, domain_filter)
		if cycled_target then
			target_squad = cycled_target
			pool, step_pool = build_pools(target_squad, filter_defs, group_set, max_distance_sq, wx, wz)
			if #steps > 1 then
				current_in_step_pool = count_selected_in(step_pool, sel.selected_set)
			end
		end
	end

	if #pool == 0 then
		return
	end

	local target_count
	if #steps == 1 then
		target_count = step_to_count(steps[1], #step_pool)
	else
		target_count = resolve_target_count(steps, #step_pool, current_in_step_pool)
	end

	if target_count < #pool then
		sort_units_by_distance(pool, wx, wz)
	end
	local to_select = pick_units(pool, target_count, sel.selected_set, opts.append)
	if #to_select == 0 then
		return
	end
	spSelectUnitArray(to_select, opts.append)
	push_to_mru(target_squad)
	last_squad_select.squad = target_squad

	log("Squad select [", target_squad.letter or "?", "]: ", #to_select, "/", #pool, opts.append and " +append" or "")
end


-------------------------------------------------------------------------------
-- Action handlers (thin wrappers over do_squad_select)
-------------------------------------------------------------------------------

local function squad_select(_, _, args)
	local arg = args and args[1]
	local append = arg == "append" or arg == "append_domain"
	local use_domain_filter = arg == "append_domain"
	do_squad_select({
		append = append,
		use_domain_filter = use_domain_filter,
		cycle_when_full = append or config.cyclingToNextSquad,
	})
	return true
end


local function squad_create()
	assign_factory_squad()
	create_squad_from_selection()
	return true
end


local function squad_cycle_recent()
	if #mru == 0 then
		spEcho("[Squad] MRU is empty")
		return true
	end
	local current_squad = selection_is_existing_squad(spGetSelectedUnits())
	local current_index = 0
	for k = 1, #mru do
		if mru[k] == current_squad then
			current_index = k
			break
		end
	end
	recall_mru((current_index % #mru) + 1)
	return true
end


local function squad_cycle_idle()
	if #squads == 0 then
		return true
	end

	local current_squad = selection_is_existing_squad(spGetSelectedUnits())
	local start_index = 0
	if current_squad then
		for i = 1, #squads do
			if squads[i] == current_squad then
				start_index = i
				break
			end
		end
	end

	local n = #squads
	for offset = 1, n do
		local sq = squads[((start_index - 1 + offset) % n) + 1]
		local size = #sq
		if size > 0 and squad_idle_state[sq] then
			local units = {}
			for j = 1, size do
				units[j] = sq[j]
			end
			spSelectUnitArray(units)
			spSendCommands("viewselection")
			log("Idle squad [", sq.letter or "?", "]")
			return true
		end
	end

	spEcho("[Squad] No idle squads found")
	return true
end


local function squad_select_filtered(_, _, args)
	local wx, wz = get_mouse_world_pos()
	if not wx then
		return true
	end
	local arg = args and args[1]
	local append = arg == "append" or arg == "append_domain"
	local use_domain_filter = arg == "append_domain"
	local retarget = arg == "retarget"
	local sel = analyze_selection()
	local filter_defs = (retarget and not append) and resolve_retarget_filter_defs(sel, wx, wz) or resolve_filter_defs(sel, wx, wz)
	if not filter_defs then
		return true
	end
	do_squad_select({
		append = append,
		use_domain_filter = use_domain_filter,
		filter_defs = filter_defs,
		cycle_when_full = append or config.cyclingToNextSquad,
	})
	return true
end


local function squad_select_group(_, _, args)
	if not args or not args[1] then
		return true
	end
	local group_num = tonumber(args[1])
	if not group_num then
		return true
	end
	local arg = args[2]
	local append = arg == "append" or arg == "append_domain"
	local use_domain_filter = arg == "append_domain"
	do_squad_select({
		append = append,
		use_domain_filter = use_domain_filter,
		group_set = build_group_set(group_num),
		cycle_when_full = append or config.cyclingToNextSquad,
	})
	return true
end


local function squad_select_portion(_, _, args)
	local append, use_domain_filter, steps, max_distance = parse_portion_args(args)
	do_squad_select({
		append = append,
		use_domain_filter = use_domain_filter,
		steps = steps,
		max_distance = max_distance,
		cycle_when_full = append,
	})
	return true
end


local function squad_select_portion_filtered(_, _, args)
	local append, use_domain_filter, steps, max_distance, retarget = parse_portion_args(args)
	local wx, wz = get_mouse_world_pos()
	if not wx then
		return true
	end
	local sel = analyze_selection()
	local filter_defs = (retarget and not append) and resolve_retarget_filter_defs(sel, wx, wz) or resolve_filter_defs(sel, wx, wz)
	if not filter_defs then
		return true
	end
	do_squad_select({
		append = append,
		use_domain_filter = use_domain_filter,
		steps = steps,
		filter_defs = filter_defs,
		max_distance = max_distance,
		cycle_when_full = append,
	})
	return true
end


local function squad_select_portion_group(_, _, args)
	if not args or not args[1] then
		return true
	end
	local group_num = tonumber(args[1])
	if not group_num then
		return true
	end
	local remaining = {}
	for i = 2, #args do
		remaining[#remaining + 1] = args[i]
	end
	local append, use_domain_filter, steps, max_distance = parse_portion_args(remaining)
	do_squad_select({
		append = append,
		use_domain_filter = use_domain_filter,
		steps = steps,
		group_set = build_group_set(group_num),
		max_distance = max_distance,
		cycle_when_full = append,
	})
	return true
end


-------------------------------------------------------------------------------
-- GL4 hull rendering
--
-- One shared VBO (2D world x,z + ground-sampled y) is re-uploaded per squad
-- per frame, then drawn as TRIANGLE_FAN (fill) and LINE_LOOP (border).
-- The 2D hull geometry is convex, so a fan starting from vertex 0 covers it.
-------------------------------------------------------------------------------

local HULL_MAX_VERTICES = 512 -- per squad; padded hull rarely approaches this
local hull_shader = nil
local hull_color_loc = nil
local hull_stripe_loc = nil
local hull_vbo = nil
local hull_vao = nil
local hull_ready = false
local hull_init_failed = false -- so we don't spam retries after a failure

-- Diagonal-stripe pattern for reserve squad fills. Period in world elmos;
-- alphaMul is the opacity of the dim band relative to the bright band.
local RESERVE_STRIPE_PERIOD = 64
local RESERVE_STRIPE_ALPHA_MUL = 0.2

local hull_vs_src = [[
#version 330 compatibility

layout(location = 0) in vec3 position;

out vec3 worldPos;

void main() {
	worldPos = position;
	gl_Position = gl_ModelViewProjectionMatrix * vec4(position, 1.0);
}
]]

local hull_fs_src = [[
#version 330 compatibility

uniform vec4 color;
// stripe.x = period in world units (0 disables stripes)
// stripe.y = alpha multiplier for the dim band
// stripe.z = phase offset in world units (per-squad, so overlapping hulls don't align)
uniform vec3 stripe;

in vec3 worldPos;

out vec4 fragColor;

void main() {
	float a = color.a;
	if (stripe.x > 0.0) {
		float band = step(0.5, fract((worldPos.x + worldPos.z + stripe.z) / stripe.x));
		a *= mix(stripe.y, 1.0, band);
	}
	fragColor = vec4(color.rgb, a);
}
]]

local function init_gl_hull()
	if hull_ready or hull_init_failed then
		return hull_ready
	end
	if not glCreateShader or not glGetVBO or not glGetVAO then
		log("GL4 unavailable — convex hull drawing disabled")
		hull_init_failed = true
		return false
	end

	hull_shader = glCreateShader({
		vertex = hull_vs_src,
		fragment = hull_fs_src,
	})
	if not hull_shader then
		local shaderLog = gl.GetShaderLog and gl.GetShaderLog() or "(no log)"
		log("Failed to compile hull shader: ", shaderLog)
		hull_init_failed = true
		return false
	end
	hull_color_loc = glGetUniformLocation(hull_shader, "color")
	hull_stripe_loc = glGetUniformLocation(hull_shader, "stripe")

	hull_vbo = glGetVBO(GL.ARRAY_BUFFER, false)
	if not hull_vbo then
		glDeleteShader(hull_shader)
		hull_shader = nil
		log("Failed to create hull VBO")
		hull_init_failed = true
		return false
	end
	hull_vbo:Define(HULL_MAX_VERTICES, {
		{
			id = 0,
			name = 'position',
			size = 3,
		}})

	hull_vao = glGetVAO()
	if not hull_vao then
		hull_vbo:Delete()
		hull_vbo = nil
		glDeleteShader(hull_shader)
		hull_shader = nil
		log("Failed to create hull VAO")
		hull_init_failed = true
		return false
	end
	hull_vao:AttachVertexBuffer(hull_vbo)

	hull_ready = true
	return true
end


local function cleanup_gl_hull()
	if hull_vao then
		hull_vao:Delete()
	end
	if hull_vbo then
		hull_vbo:Delete()
	end
	if hull_shader then
		glDeleteShader(hull_shader)
	end
	hull_vao = nil
	hull_vbo = nil
	hull_shader = nil
	hull_color_loc = nil
	hull_stripe_loc = nil
	hull_ready = false
	hull_init_failed = false
end


-------------------------------------------------------------------------------
-- Settings action — toggle/set config values from chat
-- Usage:
--   /luaui squad_setting toggle rightClickSquadCreate
--   /luaui squad_setting toggle modifierRightClickCreatesSquad
--   /luaui squad_setting toggle cyclingToNextSquad
--   /luaui squad_setting set visualizationMode convexHull
--   /luaui squad_setting set visualizationMode coloredLabel
--   /luaui squad_setting get cyclingToNextSquad
--   /luaui squad_setting reload
-------------------------------------------------------------------------------

local function squad_setting(_, _, args)
	if not args or not args[1] then
		spEcho("[Squad] Usage: squad_setting toggle|set|get|reload <key> [value]")
		return
	end
	local action = args[1]

	if action == "reload" then
		for k, v in pairs(config_defaults) do
			config[k] = v
		end
		spEcho("[Squad] Config reset to defaults from squad-selection.lua")
		return
	end

	local key = args[2]
	if not key or config[key] == nil then
		spEcho("[Squad] Unknown config key: " .. tostring(key))
		return
	end

	local function format_value(v)
		if type(v) == "table" then
			return "[" .. table.concat(v, ", ") .. "]"
		end
		return tostring(v)
	end


	if action == "toggle" then
		if type(config[key]) ~= "boolean" then
			spEcho("[Squad] Cannot toggle non-boolean key: " .. key)
			return
		end
		config[key] = not config[key]
		spEcho("[Squad] " .. key .. " = " .. tostring(config[key]))
	elseif action == "set" then
		-- excludedUnitTypes collects all remaining args joined with commas.
		if key == "excludedUnitTypes" then
			local parts = {}
			for i = 3, #args do
				parts[#parts + 1] = args[i]
			end
			config[key] = table.concat(parts, ",")
			spEcho("[Squad] excludedUnitTypes = \"" .. config[key] .. "\" (takes effect on next widget load)")
			return
		end
		-- Table-typed keys collect all remaining args as a list of numbers and
		-- distance_<N> tokens. Passing no values clears the list.
		if type(config[key]) == "table" then
			local list = {}
			for i = 3, #args do
				local tok = args[i]
				local n = tonumber(tok)
				if n then
					list[#list + 1] = n
				elseif tok:match("^distance_%d+%.?%d*$") then
					list[#list + 1] = tok
				end
			end
			config[key] = list
			spEcho("[Squad] " .. key .. " = " .. format_value(list))
			return
		end
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
		config[key] = value
		spEcho("[Squad] " .. key .. " = " .. tostring(config[key]))
	elseif action == "get" then
		spEcho("[Squad] " .. key .. " = " .. format_value(config[key]))
	else
		spEcho("[Squad] Unknown action: " .. action .. " (use toggle, set, get, or reload)")
	end
end


-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

-- Team color for unselected-squad hulls. Populated in widget:Initialize. 
local team_color = {1, 1, 1}
local idle_color = {1, 1, 1}

function widget:Initialize()
	if spGetSpectatingState() or spIsReplay() then
		log("Spectating or replay mode detected, not initializing")
		widgetHandler:RemoveWidget()
		return
	end

	squads = {}
	factory_squad = {}
	unit_squad = {}
	unit_slot = {}
	squad_idle_state = {}
	squad_idle_blend = {}
	squad_hide_idle_air_hull = {}
	idle_scan_index = 0
	next_squad_tag = 0

	local tr, tg, tb = spGetTeamColor(spGetMyTeamID())
	team_color[1], team_color[2], team_color[3] = tr or 1, tg or 1, tb or 1
	-- Derive idle tint from team color by rotating channels: R<-B, G<-R, B<-G and making it darker.
	idle_color[1], idle_color[2], idle_color[3] = team_color[2] * 0.3, team_color[3] * 0.3, team_color[1] * 0.3

	classify_unitdefs()

	uncategorized_reserve = {}
	for _, d in ipairs({"land", "air", "naval"}) do
		local sq = make_reserve_squad(false)
		sq.uncat_domain = d
		uncategorized_reserve[d] = sq
	end

	local team_id = spGetMyTeamID()
	local all = spGetTeamUnits(team_id)
	local count = 0

	-- Factories first, so their auto-squads exist before we route anything.
	for i = 1, #all do
		local u = all[i]
		local def_id = get_defid(u)
		if def_id and is_factory[def_id] then
			create_factory_squad(u)
		end
	end

	-- Combat units: at init we have no builder info, so everything goes to
	-- domain-specific uncategorized reserves. Future builds will route via UnitCreated.
	for i = 1, #all do
		local u = all[i]
		local def_id = get_defid(u)
		if def_id and is_combat[def_id] then
			add_to_squad(u, get_uncategorized_reserve_for_def(def_id))
			count = count + 1
		end
	end

	widgetHandler:AddAction("squad_select", squad_select, nil, "pt")
	widgetHandler:AddAction("squad_select_filtered", squad_select_filtered, nil, "pt")
	widgetHandler:AddAction("squad_create", squad_create, nil, "pt")
	widgetHandler:AddAction("squad_select_group", squad_select_group, nil, "pt")
	widgetHandler:AddAction("squad_select_portion", squad_select_portion, nil, "pt")
	widgetHandler:AddAction("squad_select_portion_filtered", squad_select_portion_filtered, nil, "pt")
	widgetHandler:AddAction("squad_select_portion_group", squad_select_portion_group, nil, "pt")
	widgetHandler:AddAction("squad_setting", squad_setting, nil, "t")
	widgetHandler:AddAction("squad_cycle_recent", squad_cycle_recent, nil, "pt")
	widgetHandler:AddAction("squad_cycle_idle", squad_cycle_idle, nil, "pt")

	-- WG interface for gui_options.lua integration. Auto-generates
	-- get<Key>/set<Key> pairs for every exposed config key.
	local exposed_settings = {"leftClickSelectsSquad", "leftClickSteps", "leftClickStepsEnabled", "leftClickAppendFiltersDomain", "leftClickFilteredRetargets", "cyclingToNextSquad", "rightClickSquadCreate", "modifierRightClickCreatesSquad", "viewselectionDoubleTapMs", "viewselectionDoubleTapPx", "mruSize", "excludedUnitTypes", "showReserveSquads", "visualizationMode", "convexHullPadding", "convexHullArcResolution", "convexHullFillOpacity", "convexHullBorderOpacity", "convexHullBorderThickness"}
	WG['squadselection'] = {}
	for _, key in ipairs(exposed_settings) do
		local cap = key:sub(1, 1):upper() .. key:sub(2)
		WG['squadselection']["get" .. cap] = function()
			return config[key]
		end


		WG['squadselection']["set" .. cap] = function(v)
			config[key] = v
		end


	end

	log("Initialized — ", count, " combat units in domain uncategorized reserves")
	log_squads()
end


function widget:Update(dt)
	if #squads == 0 then
		idle_scan_index = 0
		return
	end

	if idle_scan_index >= #squads then
		idle_scan_index = 0
	end
	idle_scan_index = idle_scan_index + 1

	local sq = squads[idle_scan_index]
	if sq then
		refresh_squad_idle_state(sq)
	end

	-- Animate color blend for all squads (cheap: no per-unit calls).
	local step = constrain(dt * 2, 0, 1)
	for i = 1, #squads do
		local s = squads[i]
		local target = squad_idle_state[s] and 1 or 0
		local current = squad_idle_blend[s] or 0
		if current < target then
			current = math.min(current + step, target)
		elseif current > target then
			current = math.max(current - step, target)
		end
		squad_idle_blend[s] = current
	end
end


function widget:Shutdown()
	WG['squadselection'] = nil
	widgetHandler:RemoveAction("squad_select")
	widgetHandler:RemoveAction("squad_select_filtered")
	widgetHandler:RemoveAction("squad_create")
	widgetHandler:RemoveAction("squad_select_group")
	widgetHandler:RemoveAction("squad_select_portion")
	widgetHandler:RemoveAction("squad_select_portion_filtered")
	widgetHandler:RemoveAction("squad_select_portion_group")
	widgetHandler:RemoveAction("squad_setting")
	widgetHandler:RemoveAction("squad_cycle_recent")
	widgetHandler:RemoveAction("squad_cycle_idle")
	cleanup_gl_hull()
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

	if unit_def_id and is_factory[unit_def_id] then
		create_factory_squad(unit_id)
	end

	if unit_def_id and is_combat[unit_def_id] then
		local sq = (builder_id and factory_squad[builder_id]) or get_uncategorized_reserve_for_def(unit_def_id)
		local extend_selection = false
		if sq.is_reserve then
			local sel_set = {}
			for _, u in ipairs(spGetSelectedUnits()) do
				sel_set[u] = true
			end
			extend_selection = squad_fully_selected(sq, sel_set)
		end
		-- Opt-out for the selection auto-extend, split by reserve kind:
		--   Factory reserve → the rally's trailing CMD_WAIT or CMD_PATROL is
		--     the signal — suppress the extend when set.
		--   Uncategorized reserve → no rally to inspect; fall back to the
		--     unit's own queue. Covers resurrection bots, which wake with
		--     CMD_WAIT until fully healed.
		if sq.from_factory and builder_id then
			if factory_rally_ends_with_wait_or_patrol(builder_id) then
				extend_selection = false
			end
		elseif extend_selection and unit_queue_has_wait(unit_id) then
			extend_selection = false
		end
		add_to_squad(unit_id, sq)
		if extend_selection then
			spSelectUnitArray({unit_id}, true)
		end
		log("Unit ", unit_id, " created → squad [", sq.letter or "?", "] (", #sq, " units)")
	end
end


--- Remove a unit's tracking state (combat unit AND/OR factory).
-- Returns true if anything was cleared.
local function stop_tracking(unit_id)
	local tracked = unit_squad[unit_id] ~= nil
	local was_factory = factory_squad[unit_id] ~= nil

	remove_from_squad(unit_id)
	defid_of[unit_id] = nil
	factory_squad[unit_id] = nil

	if tracked or was_factory then
		prune_empty_squads()
		return true
	end
	return false
end


function widget:UnitDestroyed(unit_id, unit_def_id, unit_team, _)
	if stop_tracking(unit_id) then
		log("Unit ", unit_id, " destroyed — ", #squads, " squad(s) remain")
	end
end


function widget:UnitTaken(unit_id, unit_def_id, unit_team, new_team)
	if unit_team ~= spGetMyTeamID() then
		return
	end
	if stop_tracking(unit_id) then
		log("Unit ", unit_id, " taken by team ", new_team)
	end
end


function widget:UnitGiven(unit_id, unit_def_id, unit_team, old_team)
	if unit_team ~= spGetMyTeamID() then
		return
	end
	defid_of[unit_id] = unit_def_id or false

	if unit_def_id and is_factory[unit_def_id] then
		create_factory_squad(unit_id)
	end

	if unit_def_id and is_combat[unit_def_id] then
		local sq = get_uncategorized_reserve_for_def(unit_def_id)
		add_to_squad(unit_id, sq)
		log("Unit ", unit_id, " given to us → uncategorized-", (sq.uncat_domain or "?"), " reserve (", #sq, " units)")
	end
end


-------------------------------------------------------------------------------
-- Selection-change tracking (for cached allSelected per squad)
-------------------------------------------------------------------------------

function widget:SelectionChanged(sel)
	-- Reset all counts
	for sq, _ in pairs(squad_sel_count) do
		squad_sel_count[sq] = 0
	end
	-- Tally from the new selection
	for i = 1, #sel do
		local sq = unit_squad[sel[i]]
		if sq then
			squad_sel_count[sq] = (squad_sel_count[sq] or 0) + 1
		end
	end
	selection_dirty = false
end


-------------------------------------------------------------------------------
-- Input
-------------------------------------------------------------------------------
function widget:MousePress(x, y, button)
	local alt, ctrl, meta, shift = spGetModKeyState()
	local cursor = spGetMouseCursor()
	if button == 3 then
		local plain = not (alt or ctrl or meta or shift)
		local mod_combo = ctrl and not alt and not meta and not shift
		local will_create = (config.rightClickSquadCreate and plain) or (config.modifierRightClickCreatesSquad and mod_combo)
		if (will_create and cursor ~= "cursornormal") then
			squad_create()
		end
	elseif button == 1 and config.leftClickSelectsSquad then
		-- A modifier is required to trigger; plain/Shift/Alt alone are not enough because then the ground click deselects the units.
		-- Ctrl → replace, Ctrl+Shift → append, +Alt → filtered. Alt+Shift also triggers (filtered append) since Ctrl is redundant there.
		if not (ctrl or (alt and shift)) then
			return
		end

		-- Skip when an active command is pending (fight, patrol, build, etc.). This may be unnecessary or should be configurable.
		local _, cmdID = spGetActiveCommand()
		if cmdID then
			return
		end
		-- Skip clicks that land directly on a unit — engine select takes over.
		if spTraceScreenRay(x, y) == "unit" then
			return
		end
		-- Skip when something is already selected and the cursor isn't the move
		-- cursor (hack: implies we're over a UI element, not open ground).
		if spGetSelectedUnits()[1] ~= nil and cursor ~= "Move" then
			return
		end

		local steps_config = config.leftClickStepsEnabled and config.leftClickSteps or {1}
		local _, _, steps, max_distance = parse_portion_args(steps_config)
		if #steps == 0 then
			steps = {1}
		end
		-- Whole-squad mode = the config is just {1} (or was empty and fell back
		-- to {1}). Anything else (including {0.5} or {5}) is portion mode.
		local whole_squad = #steps == 1 and steps[1] == 1
		local append = shift

		-- Append always cycles across squads (grow-the-selection semantics).
		-- Whole-squad replace cycles per user config. Portion replace never
		-- cycles — step progression takes the place of cycling.
		-- Left-click append uses domain filtering by default — the typical
		-- frontline-merge use case wants land squads to stay land-only when
		-- you Shift-click together a wedge of nearby units. Toggle off via
		-- `config.leftClickAppendFiltersDomain` for plain append behavior.
		local opts = {
			append = append,
			use_domain_filter = append and config.leftClickAppendFiltersDomain,
			steps = steps,
			max_distance = max_distance,
			cycle_when_full = append or (whole_squad and config.cyclingToNextSquad),
		}

		if alt then
			local wx, wz = get_mouse_world_pos()
			if not wx then
				return
			end
			local sel = analyze_selection()
			opts.filter_defs = (config.leftClickFilteredRetargets and not append) and resolve_retarget_filter_defs(sel, wx, wz) or resolve_filter_defs(sel, wx, wz)
			if not opts.filter_defs then
				return
			end
		end

		do_squad_select(opts)
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
	-- Migrate existing users from the previous default {1} to the new {1, 0.5, "distance_850"}.
	-- Anyone who deliberately customized leftClickSteps already has something other than {1}.
	if type(config.leftClickSteps) == "table" and #config.leftClickSteps == 1 and config.leftClickSteps[1] == 1 then
		config.leftClickSteps = {1, 0.5, "distance_850"}
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

	local show_reserves = config.showReserveSquads

	for _, squad in ipairs(squads) do
		if #squad > 0 and squad.color and squad.letter and (not squad.is_reserve or show_reserves) then
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

	-- Draw labels on factory buildings (all factories are reserves now).
	if show_reserves then
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
	end

	glColor(1, 1, 1, 1)
end


-------------------------------------------------------------------------------
-- Convex hull
-------------------------------------------------------------------------------

-- Persistent scratch buffers. Tables inside (scratch_world / scratch_padded
-- entries) are reused across frames. scratch_hull / scratch_upper hold refs
-- *into* scratch_world, not independent tables.
local scratch_world = {} -- {x=world_x, y=world_z} per unit
local scratch_hull = {} -- refs into scratch_world
local scratch_upper = {} -- internal to convex_hull
local scratch_padded = {} -- {x, y} per padded-hull vertex
local scratch_flat = {} -- flat {x, y, z, x, y, z, ...} for VBO upload

local function compare_points(a, b)
	return a.x < b.x or (a.x == b.x and a.y < b.y)
end


local function cross(o, a, b)
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
end


local function truncate(buf, new_len)
	for i = #buf, new_len + 1, -1 do
		buf[i] = nil
	end
end


-- Writes refs-into-world into out. Sorts `world` in place. Expects #world == n.
local function convex_hull(world, n, out, upper)
	table.sort(world, compare_points)

	local h = 0
	for i = 1, n do
		local p = world[i]
		while h >= 2 and cross(out[h - 1], out[h], p) <= 0 do
			out[h] = nil
			h = h - 1
		end
		h = h + 1
		out[h] = p
	end

	local u = 0
	for i = n, 1, -1 do
		local p = world[i]
		while u >= 2 and cross(upper[u - 1], upper[u], p) <= 0 do
			upper[u] = nil
			u = u - 1
		end
		u = u + 1
		upper[u] = p
	end

	for i = 2, u - 1 do
		h = h + 1
		out[h] = upper[i]
	end

	truncate(upper, 0)
	truncate(out, h)
	return h
end


-- circle for squads with only one unit. Writes into out, reuses its tables.
local function padded_circle(cx, cy, radius, arc_segments_angle, out)
	local segments = math.max(math.ceil(2 * math.pi / arc_segments_angle), 3)
	for i = 0, segments - 1 do
		local angle = 2 * math.pi * i / segments
		local p = out[i + 1]
		if not p then
			p = {}
			out[i + 1] = p
		end
		p.x = cx + radius * math.cos(angle)
		p.y = cy + radius * math.sin(angle)
	end
	truncate(out, segments)
	return segments
end


-- rounded padded convex hull for 2+ units. Writes into out, reuses its tables.
local function padded_more_than_one_unit(hull, n_hull, radius, arc_segments_angle, out)
	local n = 0
	for i = 1, n_hull do
		local prev = hull[i == 1 and n_hull or i - 1]
		local curr = hull[i]
		local nxt = hull[i == n_hull and 1 or i + 1]

		local dx_prev = curr.x - prev.x
		local dy_prev = curr.y - prev.y
		local dx_next = nxt.x - curr.x
		local dy_next = nxt.y - curr.y

		-- right normals (outward for CCW): (dy, -dx)
		local angle_prev = math.atan2(-dx_prev, dy_prev)
		local angle_next = math.atan2(-dx_next, dy_next)
		local angle_diff = angle_next - angle_prev
		while angle_diff < 0 do
			angle_diff = angle_diff + 2 * math.pi
		end
		local arc_segments = math.max(math.ceil(angle_diff / arc_segments_angle), 1)
		for j = 0, arc_segments do
			local t = j / arc_segments
			local theta = angle_prev + t * angle_diff
			n = n + 1
			local p = out[n]
			if not p then
				p = {}
				out[n] = p
			end
			p.x = curr.x + radius * math.cos(theta)
			p.y = curr.y + radius * math.sin(theta)
		end
	end
	truncate(out, n)
	return n
end


-- Fill scratch_padded from scratch_world[1..n_world]. Returns padded count.
local function get_padded_hull(n_world, radius, arc_segments_angle)
	if n_world == 1 then
		local p = scratch_world[1]
		return padded_circle(p.x, p.y, radius, arc_segments_angle, scratch_padded)
	elseif n_world >= 2 then
		local n_hull = convex_hull(scratch_world, n_world, scratch_hull, scratch_upper)
		return padded_more_than_one_unit(scratch_hull, n_hull, radius, arc_segments_angle, scratch_padded)
	else
		truncate(scratch_padded, 0)
		return 0
	end
end


function widget:DrawWorldPreUnit()
	if spIsGUIHidden() or config.visualizationMode ~= "convexHull" then
		return
	end
	if not squads or #squads == 0 then
		return
	end
	if not hull_ready and not init_gl_hull() then
		return
	end

	-- Lazy recount if SelectionChanged hasn't fired yet (e.g. first frame)
	if selection_dirty then
		local sel = spGetSelectedUnits()
		for sq, _ in pairs(squad_sel_count) do
			squad_sel_count[sq] = 0
		end
		for i = 1, #sel do
			local sq = unit_squad[sel[i]]
			if sq then
				squad_sel_count[sq] = (squad_sel_count[sq] or 0) + 1
			end
		end
		selection_dirty = false
	end

	-- re-read styling each frame so squad_setting changes take effect live
	local fill_opacity = config.convexHullFillOpacity
	local border_opacity = config.convexHullBorderOpacity
	local border_thickness = config.convexHullBorderThickness
	local padding = config.convexHullPadding
	local arc_res = config.convexHullArcResolution
	local show_reserves = config.showReserveSquads

	glDepthTest(false)
	glUseShader(hull_shader)
	glLineWidth(border_thickness)

	for _, squad in ipairs(squads) do
		if not squad.is_reserve or show_reserves then
			local size = #squad
			if size > 0 then
				local idle_blend = squad_idle_blend[squad] or 0
				local alpha_scale = 1
				if squad_hide_idle_air_hull[squad] then
					alpha_scale = 1 - idle_blend
				end

				if alpha_scale <= 0.001 then
					-- Fully hidden for idle flying-air squads.
				else
					local cr, cg, cb
					if (squad_sel_count[squad] or 0) >= size then
						cr, cg, cb = 1, 1, 1
					else
						cr = team_color[1] + (idle_color[1] - team_color[1]) * idle_blend
						cg = team_color[2] + (idle_color[2] - team_color[2]) * idle_blend
						cb = team_color[3] + (idle_color[3] - team_color[3]) * idle_blend
					end
					if squad.is_reserve then
						alpha_scale = alpha_scale * 0.6
						cr, cg, cb = cr * 1.5, cg * 1.5, cb * 1.5
					end

					-- fill scratch_world in place (reuse {x,y} tables) and track
					-- the bbox in the same pass, so we can frustum-cull without a
					-- second iteration.
					local n_world = 0
					local min_x, max_x, min_z, max_z = math.huge, -math.huge, math.huge, -math.huge
					for i = 1, size do
						local x, _, z = spGetUnitPosition(squad[i])
						if x and z then
							n_world = n_world + 1
							local p = scratch_world[n_world]
							if not p then
								p = {}
								scratch_world[n_world] = p
							end
							p.x = x
							p.y = z
							if x < min_x then
								min_x = x
							end
							if x > max_x then
								max_x = x
							end
							if z < min_z then
								min_z = z
							end
							if z > max_z then
								max_z = z
							end
						end
					end
					truncate(scratch_world, n_world)

					if n_world > 0 then
						-- Frustum cull: enclose the squad + padding in one sphere
						-- around the bbox centre. Vertical slop (256) covers
						-- terrain variation under the ground-projected hull.
						local cx = (min_x + max_x) * 0.5
						local cz = (min_z + max_z) * 0.5
						local hx = (max_x - min_x) * 0.5
						local hz = (max_z - min_z) * 0.5
						local cy = spGetGroundHeight(cx, cz)
						local radius = math.sqrt(hx * hx + hz * hz) + padding + 256
						local visible = (not spIsSphereInView) or spIsSphereInView(cx, cy, cz, radius)

						if visible then
							local n = get_padded_hull(n_world, padding, arc_res)
							if n >= 3 and n <= HULL_MAX_VERTICES then
								local fi = 0
								for i = 1, n do
									local p = scratch_padded[i]
									scratch_flat[fi + 1] = p.x
									scratch_flat[fi + 2] = spGetGroundHeight(p.x, p.y)
									scratch_flat[fi + 3] = p.y
									fi = fi + 3
								end

								hull_vbo:Upload(scratch_flat, nil, nil, 1, fi)
								if squad.is_reserve then
									glUniform(hull_stripe_loc, RESERVE_STRIPE_PERIOD, RESERVE_STRIPE_ALPHA_MUL, (squad.stripe_offset or 0) * RESERVE_STRIPE_PERIOD)
								else
									glUniform(hull_stripe_loc, 0, 1, 0)
								end
								glUniform(hull_color_loc, cr, cg, cb, fill_opacity * alpha_scale)
								hull_vao:DrawArrays(GL.TRIANGLE_FAN, n)
								if squad.is_reserve then
									glUniform(hull_stripe_loc, 0, 1, 0)
								end
								glUniform(hull_color_loc, cr, cg, cb, border_opacity * alpha_scale)
								hull_vao:DrawArrays(GL.LINE_LOOP, n)
							end
						end
					end
				end
			end
		end
	end

	glUseShader(0)
	glLineWidth(1)
	glDepthTest(true)
	glColor(1, 1, 1, 1)
end

