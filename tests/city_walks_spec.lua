-- Walks inside the six capitals on the shipped walking maps, from each city's flight master to where its NPCs
-- stand (tests/fixtures/city_places.lua: classic-db spawns, with the heights the server stores). A city is where a
-- walk is hardest to get right: floors over floors, doorways a cell wide, tile borders through the middle of a
-- square. Each check here failed on a map or a search that shipped.
local ns = {}
for _, map in ipairs({ 0, 1 }) do
	assert(loadfile("tools/load_nav.lua"))(map)
end
local FILES =
	{ "Data/Heights.lua", "Data/People.lua", "Routing/PathGrid.lua", "Routing/Path.lua", "Routing/PathJobs.lua" }
for _, file in ipairs(FILES) do
	assert(loadfile(file))("ShortestPathForever", ns)
end
local Path, Grid = ns.Path, ns.PathGrid
-- Every cluster of a city is read many times over; nothing here measures the cache.
Path.cacheKB, Path.clusters = math.huge, 4096
local flat = assert(loadfile("tests/nav_flat.lua"))()(Grid)
local cities = assert(loadfile("tests/fixtures/city_places.lua"))()
local floor, abs, sqrt = math.floor, math.abs, math.sqrt

local function point(place)
	return { x = place[2], y = place[3], z = place[4] }
end

local function straight(a, b)
	return sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

-- Every surface height of the cell a point is over.
local function surfaces(map, x, y)
	local st = assert(Grid.State(map))
	local k, lc = Grid.locate(st, x, y)
	local out = {}
	if not k or not Grid.grid(st, k) then
		return out
	end
	local val, z, at = st.val[k], st.z[k], st.at[k]
	if val[lc + 1] ~= 0 then
		out[#out + 1] = z[lc + 1]
	end
	local node = at[-(lc + 1)]
	while node and at[node + 1] == lc do
		out[#out + 1] = z[node + 1]
		node = node + 1
	end
	return out
end

-- The drawn line between two of a walk's own vertices stays over ground the map holds at the walk's level: every
-- two yards along it, the cell below has a surface between the two ends' heights, give or take a storey. A line
-- pulled through a wall of Ironforge crosses cells whose only surface is the mountain three hundred yards above.
-- A line between cell centres passes through cell corners, where it touches the two cells beside it at a point
-- and stands in neither: a sample that close to a corner counts the cells either side of it.
local STOREY, CORNER = 12, 0.6
local function grounded(map, a, b)
	local low, high = math.min(a.z, b.z) - STOREY, math.max(a.z, b.z) + STOREY
	local steps = math.max(1, floor(straight(a, b) / 2))
	for i = 0, steps do
		local t = i / steps
		local x, y = a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)
		local on = false
		for _, dx in ipairs({ -CORNER, CORNER }) do
			for _, dy in ipairs({ -CORNER, CORNER }) do
				for _, z in ipairs(surfaces(map, x + dx, y + dy)) do
					on = on or (z >= low and z <= high)
				end
			end
		end
		if not on then
			return false, x, y
		end
	end
	return true
end

-- The height Data/Heights.lua keeps for a spawn, as Journey/JourneyInput.lua's SpawnHeight reads it.
local function spawnHeight(map, x, y)
	local st = assert(Grid.State(map))
	local k = Grid.locate(st, x, y)
	local best, gap
	for sx, sy, sz in ((ns.SpawnHeights[map] or {})[k + 1] or ""):gmatch("(%S+) (%S+) (%S+)") do
		local d = (tonumber(sx) - x) ^ 2 + (tonumber(sy) - y) ^ 2
		if d <= 4 and (not gap or d < gap) then
			best, gap = tonumber(sz), d
		end
	end
	return best
end

-- Places the walking map cannot walk to from the hub, and places whose floor it does not hold, each with why.
-- Anything else that fails is a regression. A place listed here that starts to pass is a map that got better: the
-- spec fails until it is taken off the list, so the list never outlives the hole it records.
local APART = {
	["Thunder Bluff"] = {
		["Morja@-1480,205"] = "the Darkmoon Faire stands on the plain below the bluffs, and the lifts down are transports",
		["Seer Wiserunner@-1509,367"] = "the Pools of Vision: the map does not join the cave to Spirit Rise above it",
	},
}
local UNMAPPED = {
	Undercity = {
		["Defilers Emissary@1265,354"] = "the Royal Quarter's floor is not on the map past its corridor",
		["Kurden Bloodclaw@1263,353"] = "the Royal Quarter",
		["Royal Dreadguard@1303,380"] = "the Royal Quarter's corridor",
		["Royal Dreadguard@1317,415"] = "the Royal Quarter's corridor",
		["Chemist Fuely@1409,418"] = "the Apothecarium's lower laboratory is not on the map",
		["Master Apothecary Faranell@1435,405"] = "the Apothecarium's lower laboratory",
	},
}
-- Several NPCs share a name, so a place is named with where it stands.
local function named(place)
	return ("%s@%.0f,%.0f"):format(place[1], place[2], place[3])
end

-- How far past the grid's own walk a walk may come out. The line the player follows is the refined walk with its
-- string pulled, and it keeps to the grid's walk: within a tenth, and a doorway's width. The cost the planner is
-- given comes from the entrance graph, which keeps every pair of a cluster's entrances within 2% of its cost inside
-- the cluster (tools/baker/gen_nav.py's kept_edges) but crosses a border only where an entrance stands and never
-- weaves across one: a street along a tile border, as Stormwind's Trade District has, costs it up to a fifth more
-- than the grid walks. A quarter over is the entrance graph losing the way, as it did before the edges it kept
-- were a spanner (Stormwind to the Park, 27% over).
local DRAWN, DOORWAY = 1.1, 16
local COST, SLACK = 1.25, 24

local function length(points)
	local yards = 0
	for i = 2, #points do
		yards = yards + straight(points[i - 1], points[i])
	end
	return yards
end

local checked, unmapped = 0, {}
local worstCost, worstDrawn = { ratio = 0 }, { ratio = 0 }
for city, data in pairs(cities) do
	local map, hub = data.map, point(data.hub)
	local apart, holes = APART[city] or {}, UNMAPPED[city] or {}
	local seen = {}
	for _, place in ipairs(data.places) do
		local goal = point(place)
		local label = ("%s: %s to %s"):format(city, data.hub[1], place[1])
		local points, cost = Path.FindSync(map, hub, goal)
		local name = named(place)
		seen[name] = true
		if apart[name] then
			assert(not points, label .. " is walked now: take it off APART (" .. apart[name] .. ")")
		else
			assert(points, label .. " has no walk: " .. tostring(cost))
			checked = checked + 1
			assert(points[1].x == hub.x and points[#points].x == goal.x, label .. " does not join its two ends")
			assert(
				(points.unmapped ~= nil) == (holes[name] ~= nil),
				label .. (points.unmapped and " ends off the map" or " is on the map now: take it off UNMAPPED")
			)
			if points.unmapped then
				unmapped[#unmapped + 1] = { city = city, name = place[1], goal = goal, points = points }
			else
				local best = flat(map, hub, goal, 400000)
				if best then
					local drawn = length(points)
					if cost / best > worstCost.ratio then
						worstCost = { ratio = cost / best, label = label }
					end
					if best > 60 and drawn / best > worstDrawn.ratio then
						worstDrawn = { ratio = drawn / best, label = label }
					end
					assert(
						cost <= best * COST + SLACK,
						("%s costs %.0f yd where the grid walks %.0f"):format(label, cost, best)
					)
					assert(
						drawn <= best * DRAWN + DOORWAY,
						("%s is drawn %.0f yd long where the grid walks %.0f"):format(label, drawn, best)
					)
				end
			end
			-- No pulled segment leaves the floors the map holds. The first and last segments run from the two points
			-- themselves, off the cell centres, and an unmapped last stretch is no walk at all.
			for i = 3, #points - 1 do
				local ok, x, y = grounded(map, points[i - 1], points[i])
				assert(ok, ("%s is drawn off the map's floors at (%.0f, %.0f)"):format(label, x or 0, y or 0))
			end
		end
	end
	for name in pairs(apart) do
		assert(seen[name], city .. ": " .. name .. " is not in the fixture any more")
	end
	for name in pairs(holes) do
		assert(seen[name], city .. ": " .. name .. " is not in the fixture any more")
	end
end
assert(checked >= 340, checked)

-- A goal on a floor the map does not hold is walked to the mapped ground on its own level, and the walk says so.
-- These are holes in the maps, not in the search: the Undercity's Royal Quarter and the lower Apothecarium, and the
-- rooms a portal lets into. The search used to take the nearest surface of any height, which for the Royal Quarter
-- is a lake ninety yards overhead, and draw one straight line down to the goal.
for _, entry in ipairs(unmapped) do
	local points, goal = entry.points, entry.goal
	local tail = points.unmapped
	local reached = points[#points - 1]
	local label = entry.city .. ": " .. entry.name
	assert(tail.yards >= 0 and abs(tail.rise - (goal.z - reached.z)) < 1e-6, label)
	-- Its own cell has no floor at its height, or it would have been walked to.
	for _, z in ipairs(surfaces(cities[entry.city].map, goal.x, goal.y)) do
		assert(abs(z - goal.z) > Grid.ZTOL, label .. " stands on a mapped floor and is called unmapped")
	end
end
local function walk(map, from, to)
	local points, cost = Path.FindSync(map, from, to)
	return assert(points, cost), cost
end
local BAT_HANDLER = point(cities.Undercity.hub)
local SYLVANAS = { x = 1290.0, y = 316.0, z = -57.0 } -- classic-db creature 10181
do
	local points, cost = walk(0, BAT_HANDLER, SYLVANAS)
	local tail = assert(points.unmapped, "the Royal Quarter is on the map now: take it out of this spec")
	assert(cost < 500, cost) -- 1,833 yd out through the sewers and round to the lake, before
	assert(tail.yards < 150 and abs(tail.rise) <= Grid.ZTOL, ("%.0f yd, rise %.0f"):format(tail.yards, tail.rise))
	for i = 2, #points - 1 do
		assert(points[i].z < 0, ("the walk leaves the city at (%.0f, %.0f)"):format(points[i].x, points[i].y))
	end
	-- Without a height the goal is whatever stands there, and the walk must not be called unmapped: nothing says
	-- which floor was meant.
	local blind = walk(0, BAT_HANDLER, { x = SYLVANAS.x, y = SYLVANAS.y })
	assert(blind.unmapped == nil)
	-- Data/Heights.lua names her floor, so a journey planned to her spawn has the height to say so with.
	assert(spawnHeight(0, SYLVANAS.x, SYLVANAS.y) == -57, tostring(spawnHeight(0, SYLVANAS.x, SYLVANAS.y)))
end

-- A goal on the map is never called unmapped, however it snaps: the banker a few cells from the bat handler.
assert(walk(0, BAT_HANDLER, { x = 1600, y = 240, z = -43 }).unmapped == nil)

-- Ironforge's innkeeper stands inside the Stonefire Tavern, whose floor the map does not hold; the only surface
-- over her is the mountain. Her height comes from Data/Heights.lua, and with it the walk ends at the tavern's door
-- rather than on the peak three hundred yards up (2,152 yd, before).
local GRYTH = point(cities.Ironforge.hub)
do
	local INNKEEPER = { x = -4841, y = -857 }
	local z = assert(spawnHeight(0, INNKEEPER.x, INNKEEPER.y), "the innkeeper's height is not in Data/Heights.lua")
	assert(abs(z - 502) <= 2, z)
	local points, cost = walk(0, GRYTH, { x = INNKEEPER.x, y = INNKEEPER.y, z = z })
	assert(cost < 600, cost)
	for i = 2, #points - 1 do
		assert(abs(points[i].z - 502) < 20, ("the walk leaves the city floor at z %.0f"):format(points[i].z))
	end
end

-- The Hall of Explorers to Tinker Town is one corridor, either way (#910): 603 yd round the Military Ward, before.
do
	local HALL = { x = -4739.1, y = -1248.0, z = 502 }
	local TINKER = { x = -4788.7, y = -1249.6, z = 503 }
	local _, there = walk(0, HALL, TINKER)
	local _, back = walk(0, TINKER, HALL)
	assert(there < 200 and back < 200, there .. " " .. back)
end

-- Stormwind's gryphon master to the Park. The entrance graph dropped the edge straight across the tile between
-- them for two hops within 2% of it that were themselves dropped, and the walk came out 961 yd where the grid
-- has 756: along the tile's border to a second doorway and back.
do
	local DUNGAR = point(cities.Stormwind.hub)
	local PARK = { x = -8779, y = 1093, z = 93 } -- classic-db creature 4160, the Park's druid trainer
	local _, cost = walk(0, DUNGAR, PARK)
	local best = assert(flat(0, DUNGAR, PARK, 400000))
	assert(cost <= best * 1.05, ("%.0f yd against the grid's %.0f"):format(cost, best))
end

-- Stormwind's harbor, both ways. The ramp down to it climbs through three map tiles, and the graph held one of
-- its diagonals downhill only: the bake asked the climb limit of the two corner cells a diagonal passes beside,
-- where the search asks it of the diagonal's own ends. A walk up from the dock went under the city and up through
-- the mage tower's foundation, 1,278 yd for 796.
do
	local DOCK = { x = -8640.8, y = 1333.3, z = 6.0 } -- the dock's boarding point (Data/Routes.lua)
	local CANALS = { x = -8759.1, y = 894.0, z = 102 } -- where a player stood: Stormwind City 47.7, 65.9
	local _, down = walk(0, CANALS, DOCK)
	local up, back = walk(0, DOCK, CANALS)
	local best = assert(flat(0, DOCK, CANALS, 400000))
	assert(down <= best * 1.1 and back <= best * 1.1, ("%.0f down, %.0f up, the grid's %.0f"):format(down, back, best))
	for i = 2, #up - 1 do
		assert(up[i].z < 110, ("the walk up from the dock climbs to z %.0f"):format(up[i].z))
	end
end

-- The way back from every place to its hub is held to the grid's walk too: the graph's edges are one-way, and a
-- walk it has only downhill shows on the way up.
do
	local worst = 0
	for _, data in pairs(cities) do
		local hub = point(data.hub)
		for _, place in ipairs(data.places) do
			local goal = point(place)
			local there = Path.FindSync(data.map, hub, goal)
			if there and not there.unmapped then
				local _, home = walk(data.map, goal, hub)
				local best = flat(data.map, goal, hub, 400000)
				if best then
					worst = math.max(worst, home / best)
					assert(
						home <= best * COST + SLACK,
						("%s back to its hub costs %.0f, the grid %.0f"):format(place[1], home, best)
					)
				end
			end
		end
	end
	assert(worst < COST, worst)
end

-- With no height at either end a walk starts and ends where people are (Data/People.lua), not on the open terrain
-- under Stormwind and Orgrimmar or the mountain over Ironforge. Counted against the heights the server stores:
-- from the hub to its sixty places the walk started on the wrong floor 47 times in Stormwind, 39 in Ironforge and
-- 37 in Orgrimmar. The few ends still wrong are places with people on two floors at one spot.
do
	local WRONG = { Stormwind = { 0, 5 }, Ironforge = { 0, 3 }, Orgrimmar = { 3, 15 } }
	for city, most in pairs(WRONG) do
		local data = cities[city]
		local starts, ends = 0, 0
		for _, place in ipairs(data.places) do
			local points = Path.FindSync(data.map, { x = data.hub[2], y = data.hub[3] }, { x = place[2], y = place[3] })
			if points and #points >= 3 then
				starts = starts + (abs(points[2].z - data.hub[4]) > 12 and 1 or 0)
				ends = ends + (abs(points[#points - 1].z - place[4]) > 12 and 1 or 0)
			end
		end
		assert(starts <= most[1], ("%s: %d walks with no height start off the hub's floor"):format(city, starts))
		assert(ends <= most[2], ("%s: %d walks with no height end off the place's floor"):format(city, ends))
	end
end

-- A pier is walked, not swum (#889): Menethil's north pier to its south one, with no height to start from.
do
	local points = walk(0, { x = -3745.4, y = -609.1 }, { x = -3904.5, y = -601.0, z = 6 })
	assert(points.wet == 0, points.wet)
end

print(
	(
		"city walks: %d checked, %d on floors the map does not hold; cost at worst %.2f of the grid's walk (%s), "
		.. "drawn line %.2f (%s)"
	):format(
		checked,
		#unmapped,
		worstCost.ratio,
		tostring(worstCost.label),
		worstDrawn.ratio,
		tostring(worstDrawn.label)
	)
)
