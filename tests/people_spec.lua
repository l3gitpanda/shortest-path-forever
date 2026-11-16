-- A point with no height stands where people are (Routing/PathGrid.lua's people, Data/People.lua). On the shipped
-- Eastern Kingdoms map, at the spot a player reported in game (1.60.1): a street in Stormwind's Canals, with the open
-- terrain under the city forty yards below it as a second surface of the same cell. The walk to the harbor was
-- planned from under the street, and led into the city wall.
local ns = {}
assert(loadfile("tools/load_nav.lua"))(0)
local swimming = false
_G.UnitOnTaxi = function()
	return false
end
_G.InCombatLockdown = function()
	return false
end
_G.IsSwimming = function()
	return swimming
end
_G.IsIndoors = function()
	return false
end
ns.NearestDock = function() end
local FILES = {
	"Data/People.lua",
	"Routing/PathGrid.lua",
	"Routing/Path.lua",
	"Routing/PathJobs.lua",
	"Routing/PathProbe.lua",
	"Routing/Floor.lua",
}
for _, file in ipairs(FILES) do
	assert(loadfile(file))("ShortestPathForever", ns)
end
local Path, Grid, Floor = ns.Path, ns.PathGrid, ns.Floor
Path.cacheKB, Path.clusters = math.huge, 4096
local frames = {}
Path.after = function(fn)
	frames[#frames + 1] = fn
end
local function drain()
	while #frames > 0 do
		table.remove(frames, 1)()
	end
end
-- One sample of the floor tracker, with the clusters it asks for decoded.
local function sample(x, y)
	Floor.Sample(0, x, y)
	drain()
	Floor.Sample(0, x, y)
	return Floor.Height(0, x, y)
end

local CANALS = { x = -8759.1, y = 894.0 } -- Stormwind City 47.7, 65.9
local STREET, UNDER = 102, 60
local DOCK = { x = -8640.8, y = 1333.3, z = 6.0 } -- the Stormwind dock's boarding point (Data/Routes.lua)
local GRYPHON = { x = -8835.8, y = 490.1, z = 109.7 }
local st = assert(Grid.State(0))

-- The cell holds the street and the ground under it, and only the street has people.
local stood = Path.Standing(0, CANALS)
assert(#stood.surfaces == 2 and stood.surfaces[1] == STREET and stood.surfaces[2] == UNDER, "the street and under it")
local k, lc = Grid.locate(st, CANALS.x, CANALS.y)
local under = assert(st.at[k][-(lc + 1)], "the ground under the street is a floor of its cell")
assert(st.z[k][lc + 1] == STREET and st.z[k][under + 1] == UNDER)
local guard = assert(Grid.people(st, k, lc), "people stand on the street")
assert(guard > 40 and guard < 60, "a city guard some fifty yards off: " .. guard)
assert(Grid.people(st, k, under) == nil, "nobody stands under it")
-- Nor anything else a player comes to: the server's invisible triggers down there are not creatures.
assert(not Grid.creatures(st, k, under), "nothing lives under the street")

-- A walk from there with no height starts on the street and goes down the ramp to the harbor: 608 yd from under the
-- street and through the wall, before.
local function levels(points)
	local low, high = math.huge, -math.huge
	for i = 2, #points - 1 do
		low, high = math.min(low, points[i].z), math.max(high, points[i].z)
	end
	return low, high
end
local points, cost = Path.FindSync(0, CANALS, DOCK)
assert(points, cost)
assert(math.abs(points[2].z - STREET) <= 4, ("the walk starts at z %.0f"):format(points[2].z))
assert(cost > 750 and cost < 850, cost)
-- The same walk with the street's height given is the same walk.
local _, known = Path.FindSync(0, { x = CANALS.x, y = CANALS.y, z = STREET }, DOCK)
assert(math.abs(cost - known) < 1e-6, cost .. " " .. known)
-- And a walk there with no height ends on the street: a click on the map means where people walk.
points = assert(Path.FindSync(0, GRYPHON, CANALS))
local low = levels(points)
assert(low > 85, ("the walk to a map click goes down to z %.0f"):format(low))
assert(math.abs(points[#points - 1].z - STREET) <= 4)

-- A point with a height stands where its height says, people or none: the ground under the street can still be
-- walked to by anything that names it.
points = assert(Path.FindSync(0, { x = CANALS.x, y = CANALS.y, z = UNDER }, DOCK))
assert(math.abs(points[2].z - UNDER) <= 4, "a height is believed")

-- So does a measured band (Band.lua): a player the range checks place under the street starts there, and one they
-- place on it starts on it. The band is a measurement; the people are only where players mostly are.
ns.Band = {
	Holds = function(band, z)
		return z >= band.lo and z <= band.hi
	end,
}
points = assert(Path.FindSync(0, { x = CANALS.x, y = CANALS.y, band = { lo = UNDER - 5, hi = UNDER + 5 } }, DOCK))
assert(math.abs(points[2].z - UNDER) <= 4, "a band under the street is believed")
points = assert(Path.FindSync(0, { x = CANALS.x, y = CANALS.y, band = { lo = STREET - 5, hi = STREET + 5 } }, DOCK))
assert(math.abs(points[2].z - STREET) <= 4, "and one on it")
ns.Band = nil

-- The floor tracker's first sample there is the street, not "one of two floors": a guess, and it says so.
Floor.Forget()
assert(sample(CANALS.x, CANALS.y) == STREET, "a first sample takes the floor with people on it")
assert(select(2, Floor.Height(0, CANALS.x, CANALS.y)) == true, "chosen for its people, not walked onto")
assert(Floor.Height(0, CANALS.x, CANALS.y, true) == nil, "and no answer to who asks for a floor walked onto")
-- The guess is carried along the street by the steps taken from it.
local along = sample(CANALS.x, CANALS.y + st.cs)
assert(along and math.abs(along - STREET) <= 6, "a step along the street")
assert(select(2, Floor.Height(0, CANALS.x, CANALS.y + st.cs)) == true, "still a guess")

-- A cell the map holds no street for, only the ground under the city, beside a street with people: the map lacks
-- many a doorway and shop floor. Found by looking, so a rebake that maps the cell fails here rather than pass on
-- nothing.
local hole
for dx = -12, 12 do
	for dy = -12, 12 do
		local x, y = CANALS.x + dx * st.cs, CANALS.y + dy * st.cs
		local found = Path.Standing(0, { x = x, y = y })
		if not hole and #found.surfaces == 1 and math.abs(found.surfaces[1] - UNDER) <= 4 then
			-- a street with people right beside it
			for _, side in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
				local beside = Path.Standing(0, { x = x + side[1] * st.cs, y = y + side[2] * st.cs })
				if beside.surfaces[1] and math.abs(beside.surfaces[1] - STREET) <= 6 then
					hole = { x = x, y = y, bx = x + side[1] * st.cs, by = y + side[2] * st.cs }
				end
			end
		end
	end
end
assert(hole, "no cell near the Canals holds only the ground under the city: take this part out")
-- A first sample there does not say you are under the city.
Floor.Forget()
assert(sample(hole.x, hole.y) == nil, "the only surface is one nobody stands on, beside one with people: unknown")
-- Walking onto it from the street beside it is no forty-yard fall either: the street had no step there, no more.
Floor.Forget()
local beside = sample(hole.bx, hole.by)
assert(beside and math.abs(beside - STREET) <= 6, "on the street beside it")
assert(sample(hole.x, hole.y) == nil, "stepping where the map has no street is not a fall under the city")
-- And back on the street the tracker has it again.
local back = sample(hole.bx, hole.by)
assert(back and math.abs(back - STREET) <= 6, "the street again")
-- A walk from the hole with no height starts on the street beside it.
points = assert(Path.FindSync(0, { x = hole.x, y = hole.y }, DOCK))
assert(points[2].z > 85, ("the walk from an unmapped doorway starts at z %.0f"):format(points[2].z))

-- Ironforge is the same the other way up: the city's floor has the mountain's top over it, three hundred yards up
-- and as open as the ground under Stormwind. From the gryphon master with no height the walk stays in the city.
local GRYTH = { x = -4821.1, y = -1152.4 }
local BANK = { x = -4891.0, y = -992.0 }
points = assert(Path.FindSync(0, GRYTH, BANK))
local _, high = levels(points)
assert(high < 560, ("the walk through Ironforge climbs to z %.0f"):format(high))
Floor.Forget()
local floor = sample(GRYTH.x, GRYTH.y)
assert(floor and math.abs(floor - 502) <= 6, "the gryphon master's floor, not the peak's")

-- A cave under a camp is a place too. Gol'Bolar Quarry's tunnels run under the ledges its dwarves stand on; the
-- troggs in the tunnels have no service, but they stand there (Data/People.lua's Creatures), so their floor stays
-- one a point with no height can be on. By the people alone the walk to a trogg along the tunnel started on the
-- ledge over it, as it did at three in ten of the creatures in such places.
do
	local QUARRY = { x = -5693, y = -1675 }
	local TUNNEL, LEDGE = 361, 392
	local found = Path.Standing(0, QUARRY)
	local tunnel, ledge
	local qk, qc = Grid.locate(st, QUARRY.x, QUARRY.y)
	local node = st.val[qk][qc + 1] ~= 0 and qc or st.at[qk][-(qc + 1)]
	while node and (node == qc or st.at[qk][node + 1] == qc) do
		local z = st.z[qk][node + 1]
		tunnel = math.abs(z - TUNNEL) <= 4 and node or tunnel
		ledge = math.abs(z - LEDGE) <= 4 and node or ledge
		node = node == qc and st.at[qk][-(qc + 1)] or node + 1
	end
	assert(tunnel and ledge, "the quarry's tunnel and the ledge over it: " .. Path.StandingText(found))
	assert(Grid.people(st, qk, ledge), "the dwarves stand on the ledge")
	assert(Grid.people(st, qk, tunnel) == nil, "and none in the tunnel")
	assert(Grid.creatures(st, qk, tunnel), "where the troggs are")
	local walk, yards = Path.FindSync(0, QUARRY, { x = -5737, y = -1678, z = 362 })
	assert(walk, yards)
	assert(math.abs(walk[2].z - TUNNEL) <= 4, ("the walk along the tunnel starts at z %.0f"):format(walk[2].z))
	assert(yards < 60, yards)
	-- The floor tracker's first sample there keeps both: neither is set aside, so neither is taken.
	Floor.Forget()
	assert(sample(QUARRY.x, QUARRY.y) == nil, "the tunnel or the ledge: not known from one sample")
end

-- Where nobody is near, nothing changes: the cheapest surface still decides (a pier is walked, not swum, #889).
points = assert(Path.FindSync(0, { x = -3745.4, y = -609.1 }, { x = -3904.5, y = -601.0, z = 6 }))
assert(points.wet == 0)
-- And where every floor has people, both stay: under the Ruins of Lordaeron a first sample is still one of two.
Floor.Forget()
assert(sample(1588, 237) == nil, "the Undercity under its ruins: people on both, so neither is taken")

print("people_spec: ok")
