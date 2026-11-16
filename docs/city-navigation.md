# Walking in cities: what goes wrong, and why

An audit of the walking search, its maps and its drawing, made on 2026-11-16 against `main` at 0fa2f79 (1.38.0)
and against the routing rework in [#900](https://github.com/cjber/shortest-path-forever/pull/900), which this work
is built on. Everything here was measured offline, on the shipped walking maps, with `tools/load_nav.lua` and
`Path.FindSync`. Nothing was checked in the game client: the last section lists what still has to be.

## How a walk is made

1. **Bake** (`tools/baker/`, needs a client install). TrinityCore's extractor and Recast build a navmesh with the
   player's own slope, step and fall limits. `gen_nav.py` rasterizes it into 8 yd cells, one ADT tile (533 yd, 67
   cells a side) to a cluster. A cell holds its base surface and any floors over or under it; a step between two
   cells is open or closed, and one-way where it is a drop or steep ground.
2. **Entrance graph** (`gen_nav.py`, no client needed: `tools/refresh_nav_graph.py` rebuilds it from the shipped
   grids). Where a walk can cross a cluster border there is an entrance; inside a cluster the entrances are
   joined by edges that carry the walk's cost. This is HPA*.
3. **Search** (`Routing/Path.lua`). The two ends snap to a surface (`PathGrid.lua`'s `snap`), A* runs over the
   entrance graph, and each hop is refined into cells by a search inside one cluster.
4. **Drawing** (`PathGrid.lua`'s `smooth`, `UI/Strokes.lua`). The cell path is string-pulled: a segment is kept
   only if every cell it crosses is joined by open steps on the same floor.
5. **Following** (`Journey/`). The player's floor is followed along the map (`Routing/Floor.lua`), a walk strayed
   from is searched again from where they are, and a walk whose search fails is drawn faint and never kept.

A point's height matters throughout. The client gives addons no height for the player, QuestieDB none for an
NPC, and a map click has none; `Data/Heights.lua` supplies an NPC's where the cell has more than one floor.

## The filed issues

| Issue | On `main` (1.38.0) | With #900 | With this work |
|---|---|---|---|
| #897 routes up impassable terrain | open | uphill steps past the client's limit are refused in the search and the bake | unchanged |
| #893 road cells have gaps | reproduces: Elwynn 36 road pieces, Dustwallow 71 | 14 and 27 | unchanged |
| #892 walks leave the road at tile borders | reproduces | an entrance at every road crossing | unchanged |
| #894 straight placeholder lines | reproduces: a failed search kept its line | drawn faint, dropped on failure | the same rule for a goal off the map |
| #891 drawn line cuts across fields | reproduces: 6% of Goldshire to Westfall on road | 51% | unchanged |
| #889 a pier is swum | reproduces: 566 yd, 87 of them wet | 397 yd, dry | guarded by `city_walks_spec` |
| #910 Ironforge loops the Military Ward | reproduces: 603 yd for a 50 yd walk | 131 yd | guarded |
| #890 Stormwind under the city | reproduces | open: the ground under the city is real collision | open, see below |

None of the five named issues is fixed on `main`. #900 fixes four of them and narrows #897; it was 85 commits
ahead of `main` and unmerged when this was written, and its specs pass here.

## What was measured

From each capital's flight master to every NPC there that stands still and has a service or a quest (classic-db
spawns, with the server's heights: 1,403 walks), each walk was compared with plain A* over the same grid with no
entrance graph in between (`tests/nav_flat.lua`). A walk the grid has and the search misses is the search's
fault; a walk the grid lacks is the map's.

| | Stormwind | Ironforge | Undercity | Orgrimmar | Thunder Bluff | Darnassus |
|---|---|---|---|---|---|---|
| Walks | 256 | 268 | 222 | 307 | 181 | 169 |
| Over a quarter longer than the grid's, `main` | 11 | 126 | 5 | 126 | 0 | 1 |
| The same, #900 | 11 | 0 | 0 | 0 | 0 | 0 |
| The same, this work | 0 | 0 | 0 | 0 | 0 | 0 |
| NPC's floor not on the map | 4 | 0 | 27 | 0 | 0 | 0 |

## Causes, largest first

**1. The entrance graph lost walks the grid has (search, fixed).** On `main` nearly half of all walks from
Ironforge's and Orgrimmar's flight masters were a quarter longer than the grid's own. #900 found one cause: a
border kept one entrance for every opening that joined the same parts of two clusters, so a walk through the
other doorway went round a district (#910). The second cause is in this work. An edge between two entrances was
dropped when some third entrance stood within 2% of the way, measured on the grid and not on the edges kept, so
the two hops that excused it could themselves be dropped. In one Stormwind cluster 187 of 4,394 entrance pairs
were over 10% long and the worst 32%; the gryphon master reached the Park in 961 yd where the grid walks 756.
`kept_edges` is now a greedy spanner: every pair stays within 2% of its cost inside its cluster. The graphs of
all three maps were rebuilt from their unchanged grids.

**2. Goals on floors the map does not hold (map, now told apart).** The Undercity's Royal Quarter and the
Apothecarium's lower laboratory are not on the map, nor are the rooms a portal lets into (Stormwind's Wizard's
Sanctum). A goal there snapped to the nearest surface of any height: for Sylvanas a lake ninety yards overhead,
1,833 yd away by the sewers, with a 187 yd straight line drawn down through the rock. Now a goal with a height
is walked to the mapped ground nearest it on its own level (291 yd, to the end of the mapped corridor), and the
stretch past that is drawn faint with a note under the step. The floors themselves need a bake.

**3. NPCs whose height was never recorded (data, fixed).** `Data/Heights.lua` listed a spawn only where its
height matched a surface. An NPC inside a building the map has no floor for matched none, so its journey had no
height and ended on whatever was there. Ironforge's innkeeper is one: the only surface over the Stonefire Tavern
is the mountain, and the walk went 2,152 yd to the peak. 64 such NPCs are now listed with their own height; the
innkeeper's walk is 429 yd to the tavern door.

**4. The cost of a walk along a tile border (search, open).** A walk crosses a border only at an entrance and
never weaves across one. Stormwind's Trade District has a tile border down its main street, so every walk from
the gryphon master is costed about 74 yd long (430 for 356). The line drawn is not: once the string is pulled it
is 377 yd, within 6% of the grid's walk. Only the time and the planner's choice are off, by some ten seconds.
Fifteen of 334 sampled walks are costed more than a tenth over; two are drawn more than a tenth over. Closing it needs denser entrances on busy borders or a
search across the border at walk time; both have a cost in map size or frame time that should be measured first.

**5. The ground under Stormwind (#890, open).** The streets are a model over real terrain that the extractor
reports as walkable and joined to the world at the city's north-west edge. A point with no height can take it.
Whether a player can get down there is a question for the game, not the map; until it is answered the honest
fixes are the ones #900 made (measure the player's floor) and item 3 (know the goal's).

**6. Cell size (map, by design).** A cell is 8 yd, so a drawn line stands up to 4 yd from the middle of a
doorway. The steps between cells are exact, so the line never crosses a wall the map knows, but it can clip a
corner on screen. A finer grid is a rebake and four times the data.

**7. Places the map does not join (map, open).** The Pools of Vision are not joined to Spirit Rise above them.
`tests/city_walks_spec.lua` lists each such place by name with its reason, and fails when one starts to pass, so
the list is taken down as the maps improve.

## What this work adds

- `tools/baker/gen_nav.py`: `kept_edges`, the spanner, with an entrance's edges bounded by the 63 the graph's
  format counts, and the three graphs rebuilt. The graphs keep more edges: `Nav/` goes from 18.3 to 19.7 MB and
  `Data/RoadEdges.lua`, which holds a ratio an edge, from 1.16 to 1.64 MB; `Data/Walks.lua` is rebaked to match.
  `tests/journey_bench.lua` searches 3% longer on its Kalimdor journey (368 ms for 356) and the same on its
  Eastern Kingdoms one.
- `Routing/PathGrid.lua` `snap` and `Routing/Path.lua`: a goal off the map is walked to its own level and the walk
  says so (`points.unmapped`); `UI/Strokes.lua` draws that stretch faint and `Journey/JourneyWalks.lua` notes it.
- `Journey/Journey.lua`, `Journey/JourneySearch.lua`: past the map the floor `Floor.lua` follows is whatever else
  stands there (for the Royal Quarter, the lake), so on that stretch it is not held against the walk or against
  arriving, and nothing is searched again from there until you arrive or come back onto the map
  (`tests/unmapped_goal_spec.lua`).
- `tools/gen_heights.py`, `tools/bake_heights.lua`: heights for service and quest NPCs on unmapped floors.
- `Routing/PathProbe.lua`, `UI/NavDebug.lua`: `/path nav` draws the steps a walk may take around you on the
  world map, and `/path report` says where the map has each end of the walk under way.
- `tests/city_walks_spec.lua`, `tests/nav_flat.lua`, `tests/fixtures/city_places.lua`
  (`tools/gen_city_fixture.py`): 358 city walks against the grid's own, the drawn line against the map's floors,
  and each case above by name. `tests/path_probe_spec.lua` covers the probe and `tests/nav_debug_ui.lua` the
  overlay, against the stubbed client.

## Still to do, in order

1. **Check in game** (below). Nothing here has been seen in a client.
2. **Bake the missing floors**: the Royal Quarter, the lower Apothecarium, the Pools of Vision's path. Each is
   either pruned as unreachable or cut at a doorway; `/path nav` shows which. Needs a client install.
3. **The Wizard's Sanctum and rooms like it**: plan a goal inside to the portal that lets in, as instance
   entrances already are (`ns.Entrances`), from the same AreaTrigger data.
4. **Border weaving** (cause 4): measure denser entrances inside capitals against the journey bench first.
5. **Stormwind's under-city** (cause 5), once someone has tried the drop.

## Checking in game

Use a packaged build. For each, `/path report` after planning gives the two ends as the map has them.

1. Ironforge, at the gryphon master: plan to the innkeeper. The walk ends at the Stonefire Tavern's door.
2. Undercity, at the bat handler: plan to Lady Sylvanas. The walk stays in the city, ends in the Royal Quarter's
   corridor, the last stretch is faint and the tracker says how far is not on the map.
3. Stormwind, at the gryphon master: plan to the Park's druid trainer. The walk goes straight up the canal side.
4. Anywhere a walk looks wrong: `/path nav`, open the world map. A missing line where you can walk is a closed
   step; a line where you cannot is a wall the map lacks. Either belongs in the issue with the report.

## Other projects

Licences as their repositories state them; none of their code or data is used here.

- **Forever GPS** (GPL-3.0-or-later) is a descendant of this addon's own router by way of Polestar. It adds a
  hand-kept list of chokepoints and maps with jumps and drops as explicit edges. The idea worth taking is the
  first: doors, stairs and gates named as forced entrances rather than left to the border rule.
- **Recast/Detour** (zlib) and **TrinityCore's path generator** (GPL-2.0-or-later) smooth inside the corridor of
  polygons with a funnel, which cannot leave it; the string-pull here checks every cell instead, to the same end.
- **Zygor, Dugi, TomTom, Routes, RestedXP, Guidelime**: proprietary, all rights reserved or non-commercial, so
  nothing of theirs can be reused under GPL-3.0-or-later.
- HPA* is Botea, Müller and Schaeffer, "Near Optimal Hierarchical Path-Finding" (2004); its bound holds only
  while the edges kept inside a cluster are exact, which is what cause 1 broke.

## Repeating the measurements

```sh
python3 tools/gen_city_fixture.py     # the city places, from the pinned classic-db
luajit tests/city_walks_spec.lua      # prints the worst cost and drawn length against the grid's walk
luajit tests/path_probe_spec.lua
python3 -m unittest tools.gen_nav_test   # the spanner, and the rule it replaced failing the same case
```
