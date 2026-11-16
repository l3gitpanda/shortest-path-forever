"""Where people and other creatures stand (Data/People.lua), from tiny spawn rows."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_heights import PEOPLE_REACH, PEOPLE_SQUARE, PEOPLE_STOREY, creatures, people


def row(x, y, z, served="1", map_id="0", npc="1"):
    """A spawn as gen_heights.spawns gives it: (map, creature ID, x, y, z, idle, served, met) strings."""
    return (map_id, npc, str(x), str(y), str(z), "1", served, "1")


class PeopleTest(unittest.TestCase):
    def test_only_served_spawns_are_people(self):
        # An invisible trigger under Stormwind stands still too; it has no NPC flag, and nobody stands with it.
        kept = people([row(-8765.0, 834.6, 59.5, served="0"), row(-8759.1, 894.0, 102.3)])
        self.assertEqual(kept, [(0, -8759, 894, 102)])

    def test_one_a_square_and_storey(self):
        near = [row(10.0, 10.0, 100.0), row(12.0, 13.0, 101.0), row(14.9, 2.0, 103.9)]
        self.assertEqual(len(people(near)), 1, "three in one square on one storey are one")
        apart = [row(10.0, 10.0, 100.0), row(10.0 + PEOPLE_SQUARE, 10.0, 100.0), row(10.0, 10.0, 100.0 + PEOPLE_STOREY)]
        self.assertEqual(len(people(apart)), 3, "the next square and the next storey are their own")

    def test_each_map_keeps_its_own(self):
        kept = people([row(5.0, 5.0, 5.0, map_id="1"), row(5.0, 5.0, 5.0)])
        self.assertEqual(kept, [(0, 5, 5, 5), (1, 5, 5, 5)])

    def test_the_order_does_not_depend_on_the_rows(self):
        rows = [row(40.0, 2.0, 9.0), row(-3.0, 7.0, 1.0), row(40.0, -90.0, 9.0)]
        self.assertEqual(people(rows), people(list(reversed(rows))))


class CreaturesTest(unittest.TestCase):
    """creatures takes the baker's stacked spawns, (map, x, y, z) in whole yards, and the people."""

    CROWD = [(0, -5650, -1640, 392)]  # a dwarf on a ledge of Gol'Bolar Quarry

    def test_a_creature_near_people_speaks_for_its_floor(self):
        trogg = (0, -5693, -1675, 361)  # in the tunnel under the ledge
        self.assertEqual(creatures([trogg], self.CROWD), [trogg])

    def test_far_from_people_it_cannot_matter(self):
        edge = (0, -5650 + PEOPLE_REACH, -1640, 361)
        past = (0, -5650 + PEOPLE_REACH + 1, -1640, 361)
        self.assertEqual(creatures([edge, past], self.CROWD), [edge])
        self.assertEqual(creatures([edge], [(1, -5650, -1640, 392)]), [], "people on another map are not near")

    def test_one_a_square_and_storey_and_none_where_people_stand(self):
        two = [(0, -5693, -1675, 361), (0, -5692, -1674, 362)]
        self.assertEqual(len(creatures(two, self.CROWD)), 1)
        beside = (0, -5649, -1639, 393)  # in the dwarf's own square and storey
        self.assertEqual(creatures([beside], self.CROWD), [])

    def test_the_order_does_not_depend_on_the_rows(self):
        stacked = [(0, -5693, -1675, 361), (0, -5737, -1678, 362), (0, -5600, -1700, 380)]
        self.assertEqual(creatures(stacked, self.CROWD), creatures(list(reversed(stacked)), self.CROWD))


if __name__ == "__main__":
    unittest.main()
