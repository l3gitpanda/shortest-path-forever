---@class SPFNamespace
local ns = select(2, ...)

if ns.broken then
	return
end

-- /path nav: the walking map around you, drawn on the world map, for checking it against the game where a walk goes
-- wrong. Every line is a step a walk may take between two cell centres, on the floor you stand on and the floors
-- reached from it, so a wall is a gap in the lattice and a doorway the line through it. Green is ground, blue water,
-- orange a step taken one way only (a ledge dropped off, steep ground walked down) and purple the links between the
-- doors on a map tile's borders, which a long walk is planned along before it is walked cell by cell.
-- Route.lua's painter draws it, as it draws the boat routes: a canvas pin of its own, nothing written into the map.
-- It is drawn once when asked for and again when the map opens or changes, never on a timer.
local L = ns.L
local POOL = "ShortestPathForeverNavDebug"
local REACH = 14 -- cells drawn either way from where you stand
local COLORS = {
	ground = CreateColor(0.25, 0.9, 0.35),
	water = CreateColor(0.35, 0.65, 1),
	oneway = CreateColor(1, 0.6, 0.1),
	edge = CreateColor(0.85, 0.35, 0.95),
}
---@type SPFCanvasPool?
local pins
local shown = false

---@class SPFNavDebug
local NavDebug = {}
ns.NavDebug = NavDebug

---@class SPFNavPin : SPFRoutePin
local NavPin = CreateFromMixins(ns.RoutePinMixin)

function NavPin:OnLoad()
	ns.RoutePinMixin.OnLoad(self)
	self:UseFrameLevelType("PIN_FRAME_LEVEL_FOG_OF_WAR")
	-- Its own strokes: the journey's buffer is the journey's.
	self.strokes = ns.Strokes.New()
end

-- Every stroke is drawn as it was made; nothing here hovers.
function NavPin.UpdateAlpha() end

function NavPin.OnReleased() end

-- The player's point, with the floor Floor.lua follows them on where it knows one.
---@return SPFPoint?
local function Here()
	local x, y, _, map = ns.JourneyPosition()
	if not (x and y and map) then
		return nil
	end
	return { map = map, x = x, y = y, z = ns.Floor and ns.Floor.Height(map, x, y) or nil }
end

-- What Path.Around found as paths the route painter draws: a solid two-point line a step.
---@param around SPFNavAround
---@return SPFDrawPath[]
function NavDebug.Paths(around)
	local paths = {}
	for index, segment in ipairs(around.segments) do
		paths[index] = {
			-- a lift's line is plain and solid; a walk's would be breadcrumbs
			mode = "lift",
			color = COLORS[segment.kind],
			points = {
				{ map = around.map, x = segment.ax, y = segment.ay },
				{ map = around.map, x = segment.bx, y = segment.by },
			},
		}
	end
	return paths
end

local function Refresh()
	if not pins then
		return
	end
	pins:ReleaseAll()
	if not shown or not WorldMapFrame:IsVisible() then
		return
	end
	if InCombatLockdown() then
		ns.QueueMapRefresh()
		return
	end
	local here = Here()
	local around = here and ns.Path.HasData(here.map) and ns.Path.Around(here.map, here, REACH)
	if around then
		pins:Acquire(NavDebug.Paths(around))
	end
end
NavDebug.Refresh = Refresh

-- /path nav: turn the overlay on or off, and say in chat where the map has you standing.
function NavDebug.Toggle()
	shown = not shown
	if not shown then
		Refresh()
		ns.Print(L["Walking map overlay off."])
		return
	end
	local here = Here()
	if not (here and ns.Path.HasData(here.map)) then
		shown = false
		ns.Print(L["There is no walking map here."])
		return
	end
	ns.Print(L["Walking map overlay on: open the world map to see the steps a walk can take around you."])
	ns.Print(L["Green is ground, blue water, orange one way only, purple the links between doorways."])
	-- Plain English, as /path report is: this line is for a bug report.
	ns.Print("You: " .. ns.Path.StandingText(ns.Path.Standing(here.map, here)))
	Refresh()
end

---@return boolean
function NavDebug.Shown()
	return shown
end

ns.Init(function()
	pins = ns.Canvas.Pool(WorldMapFrame, POOL, NavPin)
	ns.Canvas.Watch(WorldMapFrame, function(_, what)
		if shown and (what == "show" or what == "map") then
			Refresh()
		end
	end)
end)
