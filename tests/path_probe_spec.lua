-- What the walking map holds at a place (Routing/PathProbe.lua), on the shipped Eastern Kingdoms map: where an
-- endpoint stands for /path report, and the open steps around a point that /path nav draws (UI/NavDebug.lua).
local ns = { L = setmetatable({}, {
	__index = function(_, phrase)
		return phrase
	end,
}) }
assert(loadfile("tools/load_nav.lua"))(0)
local FILES = { "Routing/PathGrid.lua", "Routing/Path.lua", "Routing/PathJobs.lua", "Routing/PathProbe.lua" }
for _, file in ipairs(FILES) do
	assert(loadfile(file))("ShortestPathForever", ns)
end
local Path, Grid = ns.Path, ns.PathGrid

local BAT_HANDLER = { x = 1567.1, y = 266.4, z = -43.0 } -- the Undercity's flight master
local SYLVANAS = { x = 1290.0, y = 316.0, z = -57.0 } -- in the Royal Quarter, whose floor the map does not hold
local DUNGAR = { x = -8835.8, y = 490.1, z = 109.7 } -- Stormwind's gryphon master, on his roost over the streets

-- A point on the map stands on its own floor, a cell or so from where it is.
local stood = Path.Standing(0, BAT_HANDLER)
assert(stood.reason == nil and not stood.off)
assert(math.abs(stood.z - BAT_HANDLER.z) <= Grid.ZTOL and stood.gap <= Grid.ZTOL and stood.away < 16, stood.z)
assert(#stood.surfaces == 2, "the bat handler's ring and the canal ring under it: " .. #stood.surfaces)
assert(Path.StandingText(stood):find("^cell surfaces z %-42, %-59; stands on z %-42"), Path.StandingText(stood))

-- A point whose floor the map lacks says so, and names the ground a walk to it ends on.
stood = Path.Standing(0, SYLVANAS)
assert(stood.off == true and stood.reason == nil)
assert(stood.surfaces[1] > 0 and stood.water[1], "the only surface over the Royal Quarter is the lake above it")
assert(math.abs(stood.z - SYLVANAS.z) <= Grid.ZTOL and stood.away > 48, "the nearest ground on her own level")
assert(Path.StandingText(stood):find("its floor is not on the map$"), Path.StandingText(stood))

-- With no height the point is on whatever its spot holds, and nothing is said about a height it does not have.
stood = Path.Standing(0, { x = DUNGAR.x, y = DUNGAR.y })
assert(stood.gap == nil and not stood.off and #stood.surfaces == 2)

-- Off the map's tiles, and on a continent with no map.
assert(Path.Standing(0, { x = 99999, y = 0 }).reason == "outside")
assert(Path.StandingText(Path.Standing(0, { x = 99999, y = 0 })) == "outside the walking map")
assert(Path.Standing(7, DUNGAR).reason == "nodata")
assert(Path.StandingText(Path.Standing(7, DUNGAR)) == "no walking map for this continent")

-- Around the gryphon master: the roost's floor and the ramp down from it, never the streets' own floor thirty
-- yards below through the planks.
local around = assert(Path.Around(0, DUNGAR, 10))
assert(math.abs(around.z - DUNGAR.z) <= Grid.ZTOL and around.nodes > 10, around.nodes)
local kinds = {}
for _, segment in ipairs(around.segments) do
	kinds[segment.kind] = (kinds[segment.kind] or 0) + 1
	local length = math.sqrt((segment.bx - segment.ax) ^ 2 + (segment.by - segment.ay) ^ 2)
	if segment.kind ~= "edge" then
		-- a step is one cell along x or y
		assert(math.abs(length - 1600 / 3 / 67) < 1e-6, length)
		assert(segment.ax == segment.bx or segment.ay == segment.by)
	end
	assert(math.abs(segment.ax - around.x) <= 11 * 8 and math.abs(segment.ay - around.y) <= 11 * 8, "inside the reach")
end
assert((kinds.ground or 0) > 20, "the steps the roost and its ramp allow")
assert((kinds.water or 0) == 0, "no water up there")
assert(
	#around.entrances > 0 and (kinds.edge or 0) > 0,
	"the tile border beside the roost has its doors and their links"
)
assert(around.truncated, "the city goes on past ten cells")
for _, node in ipairs(around.entrances) do
	assert(node.edges >= 0 and node.z > 60)
end

-- The flood follows open steps only: every step drawn joins two surfaces a walk can take, so walking the segments
-- from the start reaches every one of them.
local reach, grew = { [around.x .. ":" .. around.y] = true }, true
while grew do
	grew = false
	for _, segment in ipairs(around.segments) do
		if segment.kind ~= "edge" then
			local a, b = segment.ax .. ":" .. segment.ay, segment.bx .. ":" .. segment.by
			if reach[a] ~= reach[b] then
				reach[a], reach[b], grew = true, true, true
			end
		end
	end
end
for _, segment in ipairs(around.segments) do
	if segment.kind ~= "edge" then
		assert(reach[segment.ax .. ":" .. segment.ay], "a step drawn apart from where the flood began")
	end
end

-- A smaller reach is a smaller picture of the same place.
local near = assert(Path.Around(0, DUNGAR, 3))
assert(near.nodes < around.nodes and #near.segments < #around.segments)

-- Nothing to draw where there is nothing to stand on, or no map.
assert(Path.Around(0, { x = 99999, y = 0 }) == nil)
assert(Path.Around(7, DUNGAR) == nil)

print("path_probe_spec: ok")
