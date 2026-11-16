# Walking in cities: what goes wrong, and why

An audit of the walking search, its maps and its drawing, made on 2026-11-16 against `main` at 0fa2f79 (1.38.0)
and against the routing rework in [#900](https://github.com/cjber/shortest-path-forever/pull/900), which this work
is built on. Everything here was measured offline, on the shipped walking maps, with `tools/load_nav.lua` and
`Path.FindSync`. One report has come back from the game since (1.60.1, Stormwind's Canals to the harbor): causes
1 and 2 below are what it showed, and both were reproduced offline to the yard before being changed. Nothing
else has been seen in a client: the last section lists what still has to be.

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
| #890 Stormwind under the city | reproduces | open: the ground under the city is real collision | a point with no height stands where people are (cause 1) |

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

The same walks with no height given at either end, as a player's position and a map click have none: from each
hub to sixty of its places, how many started or ended more than 12 yd off the floor the server stores.

| Start / end on the wrong floor | Stormwind | Ironforge | Undercity | Orgrimmar | Thunder Bluff | Darnassus |
|---|---|---|---|---|---|---|
| #900 | 47 / 45 | 39 / 39 | 48 / 21 | 37 / 42 | 25 / 2 | 19 / 10 |
| This work | 0 / 4 | 0 / 2 | 48 / 21 | 2 / 14 | 25 / 2 | 19 / 9 |

## Causes, largest first

**1. A point with no height took the open ground under or over the city (search, fixed for Stormwind,
Ironforge and Orgrimmar).** Stormwind's streets are a model over real terrain; Ironforge has the mountain's top
over it. Both are surfaces of the same cells as the city's floors, and they have no walls, so a walk on them is
shorter than any street. A point with no height started from every surface at its spot and kept the cheapest:
in the report from the game the player stood on a street in the Canals (z 102) and the walk to the harbor was
planned from the ground 42 yd under it (z 60), 607 yd through the city wall. The map cannot say which surface a
player can reach, but the server's spawns say where people are: `Data/People.lua` holds the places where NPCs
with a service or a quest stand still, and a point with no height now stands on the surface whose people are
nearest (within 120 yd and 12 yd of its height; surfaces whose people are within 48 yd, or 24 yd of the
nearest, all stay). The floor follower (`Floor.lua`) narrows its first sample the same way, marks it a guess,
and does not take up a surface nobody stands near while one beside it has people. A height that is known still
decides: an NPC's, a measured band (`Band.lua`), a floor walked onto. Nothing is added to the map or removed
from it. Where two floors both have people at one spot (the Undercity under its ruins, Thunder Bluff's rises,
Darnassus's terraces) nothing changes, and the follower and the band are what tell them apart in game.

People alone are not enough outside the cities. A cave under a camp has none, and players go there: of the
11,174 other creatures and quest objects the server stands where floors stack, the rule acted at 1,469 and set
the creature's own floor aside at 439 of them (the troggs in the tunnels under Gol'Bolar Quarry's ledges, Skull
Rock by Orgrimmar's gate). So the same file lists those spawns too, where they stand within 168 yd of people,
and a surface one of them stands within 48 yd of is kept whatever its people. That leaves 12, five of them the
server's invisible triggers under Stormwind, which are no creature a player meets and are left out.

**2. The harbor ramp was one-way in the graph (bake, fixed).** With the start corrected the walk down was right,
but the way back up from the dock went 1,278 yd under the city and up through the mage tower's foundation, where
the grid walks the ramp in 796. A diagonal step is open when the two orthogonal detours round it are; the bake
also asked the climb limit of each detour's corner cell, where the search asks it only of the diagonal's own two
ends. On a stair that turns as it climbs the corner stands a flight higher, so the graph lost a diagonal the
grid has, at the top of the ramp, in the uphill direction only. #900 introduced the climb limit and so the
difference; `bit_step` now matches the decoder. Dock to the Canals is 796 yd both ways, dock to the gryphon
master 1,247 (1,665 before).

**3. The entrance graph lost walks the grid has (search, fixed).** On `main` nearly half of all walks from
Ironforge's and Orgrimmar's flight masters were a quarter longer than the grid's own. #900 found one cause: a
border kept one entrance for every opening that joined the same parts of two clusters, so a walk through the
other doorway went round a district (#910). The second cause is in this work. An edge between two entrances was
dropped when some third entrance stood within 2% of the way, measured on the grid and not on the edges kept, so
the two hops that excused it could themselves be dropped. In one Stormwind cluster 187 of 4,394 entrance pairs
were over 10% long and the worst 32%; the gryphon master reached the Park in 961 yd where the grid walks 756.
`kept_edges` is now a greedy spanner: every pair stays within 2% of its cost inside its cluster. The graphs of
all three maps were rebuilt from their unchanged grids.

**4. Goals on floors the map does not hold (map, now told apart).** The Undercity's Royal Quarter and the
Apothecarium's lower laboratory are not on the map, nor are the rooms a portal lets into (Stormwind's Wizard's
Sanctum). A goal there snapped to the nearest surface of any height: for Sylvanas a lake ninety yards overhead,
1,833 yd away by the sewers, with a 187 yd straight line drawn down through the rock. Now a goal with a height
is walked to the mapped ground nearest it on its own level (291 yd, to the end of the mapped corridor), and the
stretch past that is drawn faint with a note under the step. The floors themselves need a bake.

**5. NPCs whose height was never recorded (data, fixed).** `Data/Heights.lua` listed a spawn only where its
height matched a surface. An NPC inside a building the map has no floor for matched none, so its journey had no
height and ended on whatever was there. Ironforge's innkeeper is one: the only surface over the Stonefire Tavern
is the mountain, and the walk went 2,152 yd to the peak. 64 such NPCs are now listed with their own height; the
innkeeper's walk is 429 yd to the tavern door.

**6. The cost of a walk along a tile border (search, open).** A walk crosses a border only at an entrance and
never weaves across one. Stormwind's Trade District has a tile border down its main street, so every walk from
the gryphon master is costed about 74 yd long (430 for 356). The line drawn is not: once the string is pulled it
is 377 yd, within 6% of the grid's walk. Only the time and the planner's choice are off, by some ten seconds.
Fifteen of 334 sampled walks are costed more than a tenth over; two are drawn more than a tenth over. Closing it needs denser entrances on busy borders or a
search across the border at walk time; both have a cost in map size or frame time that should be measured first.

**7. The ground under Stormwind is still on the map (#890, open).** The extractor reports it as walkable and
joined to the world at the city's north-west edge, and a walk between two points up in the city never uses it
now that both ends stand on the streets. A walk that ends on it, because its goal names that height, is still
planned there. Whether a player can get down is a question for the game; taking the ground out of the map needs
that answer and a bake.

**8. Cell size (map, by design).** A cell is 8 yd, so a drawn line stands up to 4 yd from the middle of a
doorway. The steps between cells are exact, so the line never crosses a wall the map knows, but it can clip a
corner on screen. A finer grid is a rebake and four times the data.

**9. Places the map does not join (map, open).** The Pools of Vision are not joined to Spirit Rise above them.
`tests/city_walks_spec.lua` lists each such place by name with its reason, and fails when one starts to pass, so
the list is taken down as the maps improve.

## What this work adds

- `Data/People.lua` (`tools/gen_heights.py`, `tools/bake_heights.lua`, 113 KB): where service and quest NPCs
  stand still, and where other creatures and quest objects stand on stacked floors near them, one point to a
  16 yd square and 8 yd storey. `Routing/PathGrid.lua` `people`, `creatures` and `peopled` read it;
  `Routing/Path.lua` asks them of a point with no height after its band, and `Routing/Floor.lua` of a sample it
  has no step to.
  `Journey/JourneySearch.lua` lets a band overrule a floor that was only guessed, and `Journey/Journey.lua` does
  not hold a guessed floor against arriving.
- `tools/baker/gen_nav.py` `bit_step`: a diagonal is judged by its own ends, as the decoder judges it.
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
  and each case above by name: the harbor both ways, every place back to its hub, and a ceiling on walks with
  no height that start or end off their floor. `tests/people_spec.lua` holds the reported spot in the Canals
  and the quarry's tunnel.
  `tests/path_probe_spec.lua` covers the probe and `tests/nav_debug_ui.lua` the overlay, against the stubbed
  client.

## Still to do, in order

1. **Check in game** (below). Only the first report has been seen in a client.
2. **Bake the missing floors**: the Royal Quarter, the lower Apothecarium, the Pools of Vision's path. Each is
   either pruned as unreachable or cut at a doorway; `/path nav` shows which. Needs a client install.
3. **The Wizard's Sanctum and rooms like it**: plan a goal inside to the portal that lets in, as instance
   entrances already are (`ns.Entrances`), from the same AreaTrigger data.
4. **Border weaving** (cause 6): measure denser entrances inside capitals against the journey bench first.
5. **Stormwind's under-city** (cause 7), once someone has tried the drop.
6. **Floors that both have people** (cause 1): the Undercity, Thunder Bluff and Darnassus start a walk with no
   height on the wrong floor as often as before. In game the floor follower and the band answer it; a report
   from each city would say how often they do.

## Checking in game

Use a packaged build. For each, `/path report` after planning gives the two ends as the map has them.

1. Ironforge, at the gryphon master: plan to the innkeeper. The walk ends at the Stonefire Tavern's door.
2. Undercity, at the bat handler: plan to Lady Sylvanas. The walk stays in the city, ends in the Royal Quarter's
   corridor, the last stretch is faint and the tracker says how far is not on the map.
3. Stormwind, at the gryphon master: plan to the Park's druid trainer. The walk goes straight up the canal side.
4. Stormwind, on a street in the Canals: plan to the Darkshore boat. The walk follows the street north and goes
   down the ramp to the harbor, about 800 yd, and `/path report` says `stands on z 102` for its start.
5. Stormwind, off the boat at the dock: plan to the gryphon master. The walk goes up the same ramp, 1,250 yd.
6. Ironforge, anywhere in the Commons: plan to the bank. The walk stays on the city's floor.
7. Anywhere a walk looks wrong: `/path nav`, open the world map. A missing line where you can walk is a closed
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
luajit tests/people_spec.lua          # the reported spot in the Canals, with and without a height; a cave
python3 -m unittest tools.gen_nav_test      # the spanner and the diagonal rule, each failing under the rule it replaced
python3 -m unittest tools.gen_heights_test  # which spawns count as people, and which as creatures near them
```
