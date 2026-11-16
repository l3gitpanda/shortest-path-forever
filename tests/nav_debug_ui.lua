-- /path nav against the client fixture (UI/NavDebug.lua): the walking map around the player is one pin of the
-- addon's own on the map canvas, painted by the route's painter, drawn when asked for and when the map opens, and
-- gone when it is turned off. What is drawn is tests/path_probe_spec.lua's.
local dir = arg[0]:match("^(.*)/") or "tests"
local source = ""
for _, part in ipairs({ "ui_client.lua", "ui_map.lua" }) do
	local file = assert(io.open(dir .. "/" .. part))
	source = source .. file:read("*a")
	file:close()
end
assert(loadstring(source .. [[
setMapShown(true)
posX, posY, posMap, facing = 0, 0, 1, 0
mapID, zoom = 1414, 1
refreshMap()
local POOL = "ShortestPathForeverNavDebug"
local said = {}
ns.Print = function(message) said[#said + 1] = message end
local asked, has = {}, true
ns.Path.HasData = function() return has end
ns.Path.Standing = function() return { surfaces = { 10 }, water = { false }, z = 10, away = 2 } end
ns.Path.StandingText = function() return "cell surfaces z 10; stands on z 10, 2 yd away" end
ns.Path.Around = function(map, point, cells)
 asked[#asked + 1] = { map = map, x = point.x, y = point.y, cells = cells }
 return { map = map, x = point.x, y = point.y, z = 10, nodes = 4, truncated = false, entrances = {}, segments = {
  { kind = "ground", ax = 0, ay = 0, bx = 80, by = 0 },
  { kind = "water", ax = 80, ay = 0, bx = 80, by = 80 },
  { kind = "oneway", ax = 80, ay = 80, bx = 160, by = 80 },
  { kind = "edge", ax = 0, ay = 0, bx = 160, by = 80 },
 } }
end
local function shown()
 local pool = ns.Canvas.Pools(WorldMapFrame)[POOL]
 return pool and pool.active or {}
end

assert(not ns.NavDebug.Shown() and #shown() == 0, "nothing is drawn until it is asked for")
SlashCmdList.SHORTESTPATHFOREVER("nav")
assert(ns.NavDebug.Shown(), "/path nav turns the overlay on")
assert(#asked == 1 and asked[1].map == 1 and asked[1].x == 0 and asked[1].y == 0, "asked around where the player is")
assert(#said == 3 and said[3] == "You: cell surfaces z 10; stands on z 10, 2 yd away", said[#said])
local pin = assert(shown()[1], "the overlay is one pin of the addon's own on the canvas")
assert(#shown() == 1 and #pin.paths == 4, "a path a step")
assert(pin.used == 4 and not pin.strokeLayer, "one solid line a step, without the journey's pulse")
local colors = {}
for index, path in ipairs(pin.paths) do
 assert(path.mode == "lift" and #path.points == 2 and path.points[1].map == 1, "a plain two-point line")
 colors[path.color] = true
 assert(pin.lines[index].alpha == 1, "drawn at full strength")
end
local kinds = 0
for _ in pairs(colors) do kinds = kinds + 1 end
assert(kinds == 4, "ground, water, one-way steps and graph links each have their own colour")

-- The map closed and opened again somewhere else: drawn afresh, around where the player now is.
posX, posY = 400, 240
refreshMap()
assert(#asked >= 2 and asked[#asked].x == 400 and asked[#asked].y == 240, "redrawn when the map opens")
assert(#shown() == 1, "still one pin")

-- In combat nothing is drawn: the map's own refresh waits for it to end.
local draws = #asked
combat = true
ns.NavDebug.Refresh()
assert(#shown() == 0 and #asked == draws, "no drawing in combat")
combat = false
ns.NavDebug.Refresh()
assert(#shown() == 1 and #asked == draws + 1, "drawn again after it")

-- Off again: the pin goes back to its pool, and the map opening draws nothing.
SlashCmdList.SHORTESTPATHFOREVER("nav")
assert(not ns.NavDebug.Shown() and #shown() == 0, "/path nav again turns it off")
draws = #asked
refreshMap()
assert(#asked == draws and #shown() == 0, "nothing is drawn while it is off")

-- Where there is no walking map the overlay stays off and says so.
has = false
said = {}
SlashCmdList.SHORTESTPATHFOREVER("nav")
assert(not ns.NavDebug.Shown() and #said == 1 and #shown() == 0, "no walking map here")

assert(#errors == 0, table.concat(errors, "\n"))
print("nav_debug_ui: the walking map overlay draws, redraws, waits out combat and turns off ok")
]]))()
