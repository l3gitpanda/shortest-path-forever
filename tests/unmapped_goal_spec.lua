-- A journey to a goal on a floor the walking map does not hold (the Undercity's Royal Quarter). Its walk ends on
-- the mapped ground nearest the goal and says the rest is unmapped (Path.lua's points.unmapped). Past the map the
-- floor Floor.lua follows is whatever else stands there, a lake ninety yards overhead, so the journey must not be
-- judged by it: the walk holds, nothing is searched from there, and standing at the goal arrives.
local driver = assert(loadfile("tests/journey_driver.lua"))()
local ns, walking = driver.ns, driver.path

local START = { map = 1, x = 0, y = 0 }
local REACHED = { map = 1, x = 400, y = 0, z = -60 } -- the end of the mapped corridor
local GOAL = { map = 1, x = 500, y = 0, z = -60 }
local LAKE = 30 -- the only surface the map has over the goal

-- The walking search answers every walk to the goal as the real one does: to the mapped ground, then the goal.
local unmapped = true
walking.draw = function(a, b)
	local points =
		{ { map = a.map, x = a.x, y = a.y }, { map = b.map, x = REACHED.x, y = REACHED.y, z = REACHED.z }, b }
	points.wet = 0
	if unmapped then
		points.unmapped = { yards = 100, rise = 0 }
	end
	return points
end
-- The floor tracker follows the map's own surfaces: on the corridor it has the corridor, past it the lake.
local floor
ns.Floor = {
	Height = function()
		return floor
	end,
	Sample = function() end,
}

-- A journey to a goal with a height, as a quest giver's is from Data/Heights.lua: a map click has none.
local function begin()
	driver.move(START)
	ns.StartJourney({ map = GOAL.map, x = GOAL.x, y = GOAL.y, z = GOAL.z })
	walking.settle()
end
local function searches()
	return #walking.finds + #walking.batches + #walking.probes
end
local function note()
	local _, rows = ns.JourneyInfo()
	for _, row in ipairs(rows or {}) do
		if row.grey and row.text:find("not on the walking map", 1, true) then
			return row.text
		end
	end
end

floor = -60
begin()
local shown = assert(driver.shown(), "the journey is planned")
local leg = shown.legs[#shown.legs]
assert(leg.mode == "walk" and leg.measured and leg.walkPoints.unmapped, "the walk says its last stretch is unmapped")
assert(note() == "The last 100 yd are not on the walking map", tostring(note()))

-- Along the mapped walk nothing changes.
driver.move({ map = 1, x = 200, y = 0 })
driver.update(1)
assert(ns.HasJourney() and driver.shown().legs[1].walkPoints.unmapped, "the walk ahead keeps its unmapped stretch")

-- Past the map, forty yards off the straight line and with the tracker on the lake: still on the walk. The stretch
-- is as wide as it is long, and no floor is held against it.
floor = LAKE
local before = searches()
driver.move({ map = 1, x = 440, y = 40 })
driver.update(5)
assert(ns.HasJourney(), "the journey goes on")
assert(searches() == before, "nothing is searched from past the map")
local ahead = driver.shown().legs[1].walkPoints
assert(ahead.unmapped and #ahead == 2 and ahead[1].x == 440 and ahead[2].x == GOAL.x, "drawn from here to the goal")
assert(note(), "and still said to be off the walking map")

-- A minute on, the timed refresh has nothing to search from either.
driver.update(70)
assert(ns.HasJourney() and searches() == before, "the timed refresh waits while you are past the map")

-- At the goal: arrived, though the tracker has you ninety yards overhead.
driver.move({ map = 1, x = 495, y = 5 })
driver.update(1)
assert(not ns.HasJourney(), "standing at the goal arrives")

-- A goal on the map keeps both rules: off the walk is searched again, and another floor is not arrival.
unmapped = false
floor = -60
begin()
assert(not driver.shown().legs[1].walkPoints.unmapped and not note())
driver.move({ map = 1, x = 200, y = 0 })
driver.update(1)
before = searches()
driver.move({ map = 1, x = 440, y = 40 })
driver.update(5)
assert(searches() > before, "strayed from a mapped walk: searched again from here")
walking.settle()
floor = LAKE
driver.move({ map = 1, x = 495, y = 5 })
driver.update(1)
assert(ns.HasJourney(), "the goal on another floor of the map is not reached")
floor = -60
driver.update(1)
assert(not ns.HasJourney(), "on its own floor it is")

print("unmapped_goal_spec: ok")
