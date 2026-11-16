#!/usr/bin/env python3
"""Generate Data/Heights.lua, Data/IdleSpawns.lua and Data/People.lua: the height of each NPC or quest object spawn
that stands over or under another walkable surface, so a journey to it ends on its floor (stdlib + luajit), the height
of every spawn an NPC stands still at, so a walk from where the player stands starts on their floor (Routing/Band.lua),
and where people and other creatures stand, so a point with no height stands with them (Routing/PathGrid.lua).

classic-db's creature and gameobject spawns carry a height; QuestieDB's are zone fractions with none. Each spawn on
the walking maps goes through tools/bake_heights.lua, which gives it the surface its height lands on. Data/Heights.lua
keeps those with another surface more than the router's ZTOL away within a cell of them; Data/IdleSpawns.lua keeps
every creature that stands at its spawn (MovementType 0), wherever it is, keyed by creature ID: Routing/Band.lua knows
an NPC by the ID UnitGUID carries.
"""

import argparse
import csv
import gzip
import math
import re
import subprocess
from collections import defaultdict

from gen_routes import CACHE, ROOT
from gen_transit import DB_REV, DB_URL

try:
    from tools.forever_tools.fsio import publish
    from tools.forever_tools.wago import fetch
except ModuleNotFoundError:
    from forever_tools.fsio import publish
    from forever_tools.wago import fetch

MAPS = ("0", "1")
# gameobject_template.type: QUESTGIVER (2), CHEST (3: quest containers, loot, herbs and veins) and GOOBER (10: the
# objects a quest has you use). Doors, chairs, signs and traps are never a journey's goal.
OBJECT_TYPES = {2, 3, 10}
TUPLES = re.compile(r"\(((?:'(?:\\.|[^'\\])*'|[^()'])*)\)")
# Nav clusters are ADT tiles: Routing/PathGrid.lua's TILE.
TILE = 1600 / 3


# creature_template columns: Entry, InhabitType, NpcFlags and UnitFlags. InhabitType 4 flies, and a flyer's spawn
# height is the air it hangs in, never a floor. UNIT_FLAG_NOT_SELECTABLE marks the invisible triggers the server
# stands where no player goes (a World Trigger under Stormwind's streets).
ENTRY, INHABIT, NPC_FLAGS, UNIT_FLAGS = 0, 13, 16, 17
FLIES = 4
NOT_SELECTABLE = 0x02000000


def spawns(refresh=False, offline=False):
    """Creature spawns and the quest kinds of gameobject spawns on the walking maps, as
    (map, creature ID, x, y, z, idle, served, met) strings. MovementType 0 stands still at its spawn; every other
    creature wanders or patrols off it, and no quest object moves. A served spawn is one a journey is planned to and
    whose height is a floor's: it stands still, has an NPC flag (gossip, quests, a vendor, a trainer, ...) and does
    not fly. A met spawn is one a player comes to on a floor: a quest object, or a creature that can be selected and
    does not fly."""
    path = CACHE / f"classicdb-{DB_REV[:8]}.sql.gz"
    fetch(
        DB_URL,
        path,
        user_agent="ShortestPathForever/1.0",
        refresh=refresh,
        offline=offline,
        timeout=60,
        validate=gzip.decompress,
    )
    creatures, objects, types, served, met = [], [], {}, set(), set()
    # creature and gameobject rows hold numbers only; gameobject_template's names are quoted.
    with gzip.open(path, "rt", encoding="utf-8") as stream:
        for line in stream:
            if line.startswith("INSERT INTO `creature` VALUES "):
                for match in TUPLES.finditer(line):
                    row = match[1].split(",")
                    if row[2] in MAPS:
                        creatures.append((row[2], row[1], row[4], row[5], row[6], "1" if row[11] == "0" else "0"))
            elif line.startswith("INSERT INTO `creature_template` VALUES "):
                for match in TUPLES.finditer(line):
                    row = next(csv.reader([match[1]], quotechar="'", escapechar="\\"))
                    if int(row[INHABIT]) & FLIES:
                        continue
                    if int(row[NPC_FLAGS]):
                        served.add(row[ENTRY])
                    if not int(row[UNIT_FLAGS]) & NOT_SELECTABLE:
                        met.add(row[ENTRY])
            elif line.startswith("INSERT INTO `gameobject` VALUES "):
                for match in TUPLES.finditer(line):
                    row = match[1].split(",")
                    if row[2] in MAPS:
                        objects.append((int(row[1]), (row[2], row[4], row[5], row[6])))
            elif line.startswith("INSERT INTO `gameobject_template` VALUES "):
                for match in TUPLES.finditer(line):
                    row = next(csv.reader([match[1]], quotechar="'", escapechar="\\"))
                    types[int(row[0])] = int(row[1])
    if not creatures or not objects or not types:
        raise ValueError("classic-db: missing creature, gameobject or gameobject_template rows")
    still = [spawn for entry, spawn in objects if types.get(entry) in OBJECT_TYPES]
    rows = [
        (*spawn, "1" if spawn[5] == "1" and spawn[1] in served else "0", "1" if spawn[1] in met else "0")
        for spawn in creatures
    ]
    return rows + [(map_id, "0", x, y, z, "0", "0", "1") for map_id, x, y, z in still]


def bake(rows):
    """tools/bake_heights.lua over rows: (map, x, y, z) integers for the spawns Data/Heights.lua keeps,
    (map, creature ID, x, y, z) for the ones Data/IdleSpawns.lua keeps, and (map, x, y, z) for each met spawn that
    stands where floors stack."""
    result = subprocess.run(
        ["luajit", "tools/bake_heights.lua"],
        cwd=ROOT,
        input="".join("\t".join(row) + "\n" for row in rows),
        capture_output=True,
        text=True,
        check=True,
    )
    found = {"H": [], "I": [], "C": []}
    for line in result.stdout.splitlines():
        kind, rest = line.split("\t", 1)
        found[kind].append(tuple(map(int, rest.split("\t"))))
    return found["H"], found["I"], found["C"]


def cluster(x, y, nav):
    """Routing/PathGrid.lua's locate, down to the cluster, computed as it is: through the global cell, so a spawn on a
    tile's edge is filed under the cluster the addon looks it up in."""
    cx0, cy0, ny, cells = nav
    size = TILE / cells
    gx, gy = math.floor((x - cx0 * TILE) / size), math.floor((y - cy0 * TILE) / size)
    return (gx // cells) * ny + gy // cells


def nav_origin(map_id):
    """The walking map's first tile, tile row length and cells per tile side, from its Nav<map>.lua header."""
    text = (ROOT / "Nav" / f"Nav{map_id}.lua").read_text(encoding="utf-8")
    values = {}
    for key in ("cx0", "cy0", "ny", "cells"):
        match = re.search(rf"\b{key} = (-?\d+)", text)
        if match is None:
            raise ValueError(f"Nav{map_id}.lua has no {key} header")
        values[key] = int(match[1])
    return values["cx0"], values["cy0"], values["ny"], values["cells"]


def by_cluster(rows):
    """(map, x, y, z) rows as {map: {cluster: ["x y z", ...]}}, filed under the cluster the addon looks them up in."""
    by_map = defaultdict(lambda: defaultdict(list))
    origins = {}
    for map_id, x, y, z in sorted(rows):
        origins.setdefault(map_id, nav_origin(map_id))
        by_map[map_id][cluster(x, y, origins[map_id])].append(f"{x} {y} {z}")
    return by_map


def render(kept):
    by_map = by_cluster(kept)
    lines = [
        "-- Generated by tools/gen_heights.py - do not edit.",
        "-- Source: classic-db creature spawns and QUESTGIVER, CHEST and GOOBER gameobject spawns, matched to the",
        "-- walking maps' surfaces by tools/bake_heights.lua.",
        f"-- DB: https://github.com/cmangos/classic-db/tree/{DB_REV}",
        "-- SpawnHeights[map][k + 1]: the spawns in Nav cluster k standing within a cell of another surface more",
        "-- than ZTOL away, as space-separated world x, y and the height of the surface they stand on, in whole yards.",
        "-- An NPC with a service or a quest that stands still on a floor the walking map does not hold (no surface",
        "-- within ZTOL of it in the cells around it) is listed with its own height, so a journey to it is walked to",
        "-- the mapped ground on its level and the rest is told apart (Routing/PathGrid.lua's snap).",
        "local ns = select(2, ...)",
        "",
        "-- stylua: ignore",
        "ns.SpawnHeights = {",
    ]
    for map_id in sorted(by_map):
        lines.append(f"\t[{map_id}] = {{")
        for k in sorted(by_map[map_id]):
            lines.append(f'\t\t[{k + 1}] = "{" ".join(by_map[map_id][k])}",')
        lines.append("\t},")
    lines.append("}")
    return "\n".join(lines) + "\n"


def render_idle(idle):
    """IdleSpawns[map][creature ID] as the "x y z" triples of that creature's idle spawns on the map, looked up by the
    creature ID UnitGUID names. A creature with more than one is kept whole: Routing/Band.lua measures only one."""
    by_map = defaultdict(lambda: defaultdict(list))
    for map_id, npc, x, y, z in sorted(idle):
        by_map[map_id][npc].append(f"{x} {y} {z}")
    lines = [
        "-- Generated by tools/gen_heights.py - do not edit.",
        "-- Source: classic-db creature spawns that stand at their spawn (MovementType 0), matched to the walking",
        "-- maps' surfaces by tools/bake_heights.lua.",
        f"-- DB: https://github.com/cmangos/classic-db/tree/{DB_REV}",
        "-- IdleSpawns[map][creature ID]: the spawns in that map a creature of that ID stands still at, as",
        "-- space-separated world x, y and the height of the surface it stands on, in whole yards, one triple per",
        "-- spawn. Routing/Band.lua bounds the player's height from the client's range checks to a unit whose",
        "-- UnitGUID carries the ID, and only where the ID has one spawn on the map.",
        "local ns = select(2, ...)",
        "",
        "-- stylua: ignore",
        "ns.IdleSpawns = {",
    ]
    for map_id in sorted(by_map):
        lines.append(f"\t[{map_id}] = {{")
        for npc in sorted(by_map[map_id]):
            lines.append(f'\t\t[{npc}] = "{" ".join(by_map[map_id][npc])}",')
        lines.append("\t},")
    lines.append("}")
    return "\n".join(lines) + "\n"


# One spawn a square this many yards wide and a storey this many high says people stand there.
PEOPLE_SQUARE, PEOPLE_STOREY = 16, 8
# How far from people another creature can matter: Routing/PathGrid.lua's FAR + CLOSE. A surface is weighed against
# one with people within FAR of it, and creatures within CLOSE of it speak for it.
PEOPLE_REACH = 120 + 48


def square(map_id, x, y, z):
    return (map_id, math.floor(x / PEOPLE_SQUARE), math.floor(y / PEOPLE_SQUARE), math.floor(z / PEOPLE_STOREY))


def people(rows):
    """(map, x, y, z) in whole yards for the served spawns (an NPC with a service or a quest that stands still and does
    not fly), one a PEOPLE_SQUARE square and PEOPLE_STOREY storey, at the height the server stores."""
    seen, kept = set(), []
    served = [(int(row[0]), float(row[2]), float(row[3]), float(row[4])) for row in rows if row[6] == "1"]
    for map_id, x, y, z in sorted(served):
        key = square(map_id, x, y, z)
        if key not in seen:
            seen.add(key)
            kept.append((map_id, round(x), round(y), round(z)))
    return kept


def creatures(stacked, crowd):
    """(map, x, y, z) for the other things a player comes to where floors stack (stacked: tools/bake_heights.lua's
    met spawns with another floor over or under them) within PEOPLE_REACH yards of the people in crowd, one a square
    and storey, leaving out the squares people hold. They speak for the floor they are on: a cave under a camp is a
    place, the ground under Stormwind's streets is not."""
    near, seen, kept = defaultdict(list), set(), []
    for map_id, x, y, z in crowd:
        near[(map_id, x // PEOPLE_REACH, y // PEOPLE_REACH)].append((x, y))
        seen.add(square(map_id, x, y, z))
    for map_id, x, y, z in sorted(stacked):
        key = square(map_id, x, y, z)
        if key in seen:
            continue
        bx, by = x // PEOPLE_REACH, y // PEOPLE_REACH
        if any(
            (px - x) ** 2 + (py - y) ** 2 <= PEOPLE_REACH**2
            for dx in (-1, 0, 1)
            for dy in (-1, 0, 1)
            for px, py in near.get((map_id, bx + dx, by + dy), ())
        ):
            seen.add(key)
            kept.append((map_id, x, y, z))
    return kept


def render_people(crowd, others):
    lines = [
        "-- Generated by tools/gen_heights.py - do not edit.",
        "-- Source: classic-db creature spawns. People stand at their spawn (MovementType 0), have an NPC flag",
        "-- (gossip, quests, a vendor, a trainer, ...) and do not fly. Creatures are the other spawns a player comes",
        "-- to (a quest object, or a creature that can be selected and does not fly) on a floor with another over or",
        f"-- under it (tools/bake_heights.lua), within {PEOPLE_REACH} yd of people.",
        f"-- DB: https://github.com/cmangos/classic-db/tree/{DB_REV}",
        "-- People[map][k + 1], Creatures[map][k + 1]: where they stand in Nav cluster k, as space-separated world",
        f"-- x, y and height in whole yards, one a {PEOPLE_SQUARE} yd square and {PEOPLE_STOREY} yd storey. A point",
        "-- with no height is taken to stand on the surface at its spot whose people are nearest, or on one creatures",
        "-- stand on (Routing/PathGrid.lua).",
        "local ns = select(2, ...)",
    ]
    for name, rows in (("People", crowd), ("Creatures", others)):
        by_map = by_cluster(rows)
        lines += ["", "-- stylua: ignore", f"ns.{name} = {{"]
        for map_id in sorted(by_map):
            lines.append(f"\t[{map_id}] = {{")
            for k in sorted(by_map[map_id]):
                lines.append(f'\t\t[{k + 1}] = "{" ".join(by_map[map_id][k])}",')
            lines.append("\t},")
        lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--refresh", action="store_true", help="redownload pinned sources")
    mode.add_argument("--offline", action="store_true", help="use cached sources only")
    args = parser.parse_args()
    rows = spawns(args.refresh, args.offline)
    kept, idle, stacked = bake(rows)
    crowd = people(rows)
    publish(
        {
            ROOT / "Data" / "Heights.lua": render(kept),
            ROOT / "Data" / "IdleSpawns.lua": render_idle(idle),
            ROOT / "Data" / "People.lua": render_people(crowd, creatures(stacked, crowd)),
        }
    )


if __name__ == "__main__":
    main()
