---@class SPFNamespace
local ns = select(2, ...)

if ns.broken then
	return
end

-- What the walking map itself holds at a place, for checking it against the game: where an endpoint stands, and the
-- steps open around a point. Nothing here searches or plans; /path nav (UI/NavDebug.lua) draws what Around returns
-- and /path report prints what Standing says about each walk's two ends. A walk that goes wrong in a city is a
-- wall the map lacks, a doorway it closed, a floor it does not hold or a point that snapped to the wrong one, and
-- none of those can be told apart from the drawn line alone.
---@class SPFPath
local Path = ns.Path
local Grid = ns.PathGrid
local State, grid, locate, snap, neighbour = Grid.State, Grid.grid, Grid.locate, Grid.snap, Grid.neighbour
local nodesOf, adjacent, entrance, cellOf = Grid.nodesOf, Grid.adjacent, Grid.entrance, Grid.cellOf
local floor, abs, sqrt = math.floor, math.abs, math.sqrt

-- The world position of a node's cell centre.
local function centre(st, k, node)
	local C = st.C
	local cell = node < C * C and node or cellOf(st, k, node)
	return st.x0 + (floor(k / st.ny) * C + floor(cell / C) + 0.5) * st.cs,
		st.y0 + ((k % st.ny) * C + cell % C + 0.5) * st.cs
end

-- Where an endpoint stands on the walking map.
---@class SPFStanding
---@field reason? "nodata"|"outside"|"offmesh" -- why the point is on no surface at all
---@field surfaces number[] -- the height of every surface of the point's own cell, the base surface first
---@field water boolean[] -- which of those are water
---@field z? number -- the height of the surface a walk starts or ends on
---@field away? number -- how far that surface's cell centre is from the point, in yards on the map
---@field gap? number -- how far the point's own height is from it, when the point has a height
---@field off? boolean -- the point's floor is not on the map (PathGrid.lua's snap)

-- Asked from the report and the slash command, outside any search: the clusters it reads are decoded whole.
---@param map number
---@param point SPFPoint
---@return SPFStanding
local function standing(map, point)
	local found = { surfaces = {}, water = {} }
	local st = State(map)
	if not st then
		found.reason = "nodata"
		return found
	end
	local k, lc = locate(st, point.x, point.y)
	if not k then
		found.reason = "outside"
		return found
	end
	local val = grid(st, k)
	if val then
		local z, at = st.z[k], st.at[k]
		if val[lc + 1] ~= 0 then
			found.surfaces[1], found.water[1] = z[lc + 1], val[lc + 1] == 2
		end
		local node = at[-(lc + 1)]
		while node and at[node + 1] == lc do
			found.surfaces[#found.surfaces + 1], found.water[#found.water + 1] = z[node + 1], val[node + 1] == 2
			node = node + 1
		end
	end
	local node, off = snap(st, k, lc, point.x, point.y, point.z)
	if not node then
		found.reason = "offmesh"
		return found
	end
	local x, y = centre(st, k, node)
	found.z, found.off = st.z[k][node + 1], off or nil
	found.away = sqrt((x - point.x) ^ 2 + (y - point.y) ^ 2)
	found.gap = point.z and abs(point.z - found.z) or nil
	return found
end

---@param map number
---@param point SPFPoint
---@return SPFStanding
function Path.Standing(map, point)
	return (Grid.Quiet(standing, map, point))
end

-- Standing in one line of plain English, for /path report.
---@param found SPFStanding
---@return string
function Path.StandingText(found)
	if found.reason == "nodata" then
		return "no walking map for this continent"
	elseif found.reason == "outside" then
		return "outside the walking map"
	end
	local heights = {}
	for index, z in ipairs(found.surfaces) do
		heights[index] = ("%.0f%s"):format(z, found.water[index] and " (water)" or "")
	end
	local cell = #heights > 0 and ("cell surfaces z " .. table.concat(heights, ", ")) or "no surface in its cell"
	if found.reason == "offmesh" then
		return cell .. "; nothing to stand on within " .. Grid.SNAP .. " cells"
	end
	local on = ("stands on z %.0f, %.0f yd away"):format(found.z, found.away)
	if found.gap then
		on = on .. (", %.0f yd from its own height"):format(found.gap)
	end
	if found.off then
		on = on .. ": its floor is not on the map"
	end
	return cell .. "; " .. on
end

-- The walking map around a point, as segments to draw: the steps open between cell centres on the floor the point
-- stands on and every floor reached from it, and the entrance graph's nodes and edges among them. A step drawn is a
-- step a walk may take, so a wall is a gap in the lattice and a doorway the one line through it.
---@class SPFNavSegment
---@field kind "ground"|"water"|"oneway"|"edge" -- oneway: taken this way only (a drop, steep ground walked down)
---@field ax number
---@field ay number
---@field bx number
---@field by number
---@class SPFNavAround
---@field map number
---@field x number -- the point's snapped cell centre
---@field y number
---@field z number
---@field segments SPFNavSegment[]
---@field entrances { x: number, y: number, z: number, edges: number }[] -- the entrance graph's nodes reached
---@field nodes number -- surfaces reached
---@field truncated boolean -- the reach, not the map, ended the flood

-- cells is how far the flood runs from the point, in cells either way.
---@param map number
---@param point SPFPoint
---@param cells number
---@return SPFNavAround?
local function around(map, point, cells)
	local st = State(map)
	local k, lc = nil, nil
	if st then
		k, lc = locate(st, point.x, point.y)
	end
	if not st or not k or not grid(st, k) then
		return nil
	end
	local start = snap(st, k, lc, point.x, point.y, point.z)
	if not start then
		return nil
	end
	local C = st.C
	local function cellXY(nk, node)
		local cell = node < C * C and node or cellOf(st, nk, node)
		return floor(nk / st.ny) * C + floor(cell / C), (nk % st.ny) * C + cell % C
	end
	local ox, oy = cellXY(k, start)
	local sx, sy = centre(st, k, start)
	local out = {
		map = map,
		x = sx,
		y = sy,
		z = st.z[k][start + 1],
		segments = {},
		entrances = {},
		nodes = 0,
		truncated = false,
	}
	-- Flood over the open steps, both ways round: a surface only a drop reaches is still part of the picture.
	local seen, queue, head = { [k * 1048576 + start] = true }, { k, start }, 1
	local reached = {}
	while head < #queue do
		local nk, node = queue[head], queue[head + 1]
		head = head + 2
		out.nodes = out.nodes + 1
		reached[#reached + 1], reached[#reached + 2] = nk, node
		local gx, gy = cellXY(nk, node)
		for d = 0, 3 do
			local dx, dy = Grid.DX[d], Grid.DY[d]
			local tk, tn = neighbour(st, nk, node, gx, gy, dx, dy, true)
			if tk and tn then
				local id = tk * 1048576 + tn
				if abs(gx + dx - ox) > cells or abs(gy + dy - oy) > cells then
					out.truncated = true
				elseif not seen[id] then
					seen[id] = true
					queue[#queue + 1], queue[#queue + 2] = tk, tn
				end
			end
		end
	end
	-- One segment per open step towards +x and +y, and per step open towards -x or -y only.
	for i = 1, #reached, 2 do
		local nk, node = reached[i], reached[i + 1]
		local gx, gy = cellXY(nk, node)
		local ax, ay = centre(st, nk, node)
		for d = 0, 3 do
			local dx, dy = Grid.DX[d], Grid.DY[d]
			local tk, tn = neighbour(st, nk, node, gx, gy, dx, dy, true)
			if tk and tn and seen[tk * 1048576 + tn] then
				local tx, ty = cellXY(tk, tn)
				local bk, bn = neighbour(st, tk, tn, tx, ty, -dx, -dy, true)
				local back = bk == nk and bn == node
				-- a step both ways take is drawn once, from its lower end
				if not back or dx > 0 or dy > 0 then
					local bx, by = centre(st, tk, tn)
					local wet = st.val[nk][node + 1] == 2 or st.val[tk][tn + 1] == 2
					out.segments[#out.segments + 1] = {
						kind = not back and "oneway" or wet and "water" or "ground",
						ax = ax,
						ay = ay,
						bx = bx,
						by = by,
					}
				end
			end
		end
	end
	-- The entrance graph over the same surfaces: its nodes, and its edges that stay among them.
	local clusters, at = {}, {}
	for i = 1, #reached, 2 do
		clusters[reached[i]] = true
	end
	for nk in pairs(clusters) do
		for _, id in ipairs(nodesOf(st, nk)) do
			local node = entrance(st, id)
			if node and seen[nk * 1048576 + node] then
				local x, y = centre(st, nk, node)
				at[id] = { x = x, y = y, z = st.z[nk][node + 1], edges = 0 }
				out.entrances[#out.entrances + 1] = at[id]
			end
		end
	end
	for id, from in pairs(at) do
		local edges = adjacent(st, id)
		for e = 1, #edges, 3 do
			local to = at[edges[e]]
			if to then
				from.edges = from.edges + 1
				out.segments[#out.segments + 1] = { kind = "edge", ax = from.x, ay = from.y, bx = to.x, by = to.y }
			end
		end
	end
	return out
end

---@param map number
---@param point SPFPoint
---@param cells? number
---@return SPFNavAround?
function Path.Around(map, point, cells)
	return (Grid.Quiet(around, map, point, cells or 12))
end
