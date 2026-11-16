-- A reference walk for specs: plain A* over the walking grid itself, cell to cell across cluster borders, with no
-- entrance graph in between. It takes the steps a drawn line may take (PathGrid's neighbour: the base grid's eight
-- directions and the floor links, a water cell at the map's swim cost) and none of the baked ledge drops longer than
-- a cell, so its cost is what the grid allows on foot and an upper bound on the best walk. A search through the
-- entrance graph that comes out much longer than this has lost the way in the graph, not in the terrain.
---@param Grid SPFPathGrid
---@return fun(map: number, from: SPFPoint, to: SPFPoint, cap: number?): number|false|nil, number
return function(Grid)
	local floor, abs = math.floor, math.abs
	local SQRT2 = math.sqrt(2)

	-- The walk's cost in running yards, false when the grid does not join the two points, nil past cap expansions;
	-- then the expansions it took.
	return function(map, from, to, cap)
		local st = assert(Grid.State(map))
		local sk, sc = Grid.locate(st, from.x, from.y)
		local gk, gc = Grid.locate(st, to.x, to.y)
		if not sk or not gk then
			return false, 0
		end
		sc, gc = Grid.snap(st, sk, sc, from.x, from.y, from.z), Grid.snap(st, gk, gc, to.x, to.y, to.z)
		if not sc or not gc then
			return false, 0
		end
		local C = st.C
		local function cell(k, node)
			local lc = node < C * C and node or Grid.cellOf(st, k, node)
			return floor(k / st.ny) * C + floor(lc / C), (k % st.ny) * C + lc % C
		end
		local tx, ty = cell(gk, gc)
		local function ahead(k, node)
			local x, y = cell(k, node)
			local dx, dy = abs(x - tx), abs(y - ty)
			return (dx > dy and dx + (SQRT2 - 1) * dy or dy + (SQRT2 - 1) * dx) * st.cs
		end
		local cost, closed = {}, {}
		local keys, ks, ns_, size = {}, {}, {}, 0
		local function push(key, k, node)
			size = size + 1
			local i = size
			while i > 1 do
				local p = floor(i / 2)
				if keys[p] <= key then
					break
				end
				keys[i], ks[i], ns_[i] = keys[p], ks[p], ns_[p]
				i = p
			end
			keys[i], ks[i], ns_[i] = key, k, node
		end
		local function pop()
			local k, node = ks[1], ns_[1]
			local key, lk, ln = keys[size], ks[size], ns_[size]
			size = size - 1
			local i = 1
			while true do
				local c = i * 2
				if c > size then
					break
				end
				if c < size and keys[c + 1] < keys[c] then
					c = c + 1
				end
				if keys[c] >= key then
					break
				end
				keys[i], ks[i], ns_[i] = keys[c], ks[c], ns_[c]
				i = c
			end
			keys[i], ks[i], ns_[i] = key, lk, ln
			return k, node
		end
		cost[sk * 1048576 + sc] = 0
		push(ahead(sk, sc), sk, sc)
		local expanded = 0
		while size > 0 do
			local k, node = pop()
			local id = k * 1048576 + node
			if not closed[id] then
				closed[id] = true
				if k == gk and node == gc then
					return cost[id], expanded
				end
				expanded = expanded + 1
				if cap and expanded > cap then
					return nil, expanded
				end
				local x, y = cell(k, node)
				for d = 0, 7 do
					local nk, nn = Grid.neighbour(st, k, node, x, y, Grid.DX[d], Grid.DY[d], true)
					if nk and nn then
						local nid = nk * 1048576 + nn
						if not closed[nid] then
							local step = (d >= 4 and SQRT2 or 1) * st.cs * (st.val[nk][nn + 1] == 2 and st.swim or 1)
							local reached = cost[id] + step
							if not cost[nid] or reached < cost[nid] then
								cost[nid] = reached
								push(reached + ahead(nk, nn), nk, nn)
							end
						end
					end
				end
			end
		end
		return false, expanded
	end
end
