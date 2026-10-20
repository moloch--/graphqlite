#!/usr/bin/env python3
"""Failure/transaction regressions for the native APOC compatibility subset.

Run after building the extension:
  python tests/cirro/apoc_failures.py --extension build/graphqlite.dylib
No Cirro checkout or third-party Python packages are required.
"""
import argparse
import json
from pathlib import Path
import sqlite3
import unittest


EXTENSION = None


class ApocFailureTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:', isolation_level=None)
        self.db.enable_load_extension(True)
        self.db.load_extension(str(EXTENSION))
        self.db.enable_load_extension(False)

    def tearDown(self):
        self.db.close()

    def query(self, text):
        raw = self.db.execute('SELECT cypher(?)', (text,)).fetchone()[0]
        return json.loads(raw)

    def test_different_endpoints_are_rejected_without_mutation(self):
        self.query('CREATE (a:A), (b:B), (c:C), '
                   '(a)-[:R {v:1}]->(b), (a)-[:S {v:2}]->(c)')
        before = self.db.execute('SELECT * FROM edges ORDER BY id').fetchall()
        with self.assertRaisesRegex(sqlite3.Error, 'identical start and end nodes'):
            self.query('MATCH ()-[r]->() WITH collect(r) AS rs '
                       'CALL apoc.refactor.mergeRelationships(rs,{properties:"overwrite"}) '
                       'YIELD rel RETURN rel')
        self.assertEqual(before, self.db.execute('SELECT * FROM edges ORDER BY id').fetchall())
        self.assertEqual(2, self.db.execute('SELECT count(*) FROM edge_props_int').fetchone()[0])
        self.assertEqual([], self.db.execute('PRAGMA foreign_key_check').fetchall())

    def fail_later_action(self):
        self.query('CREATE (:A {id:1,policy:"overwrite"}), (:A {id:2,policy:"bad"})')
        with self.assertRaisesRegex(sqlite3.Error, 'Unsupported APOC properties policy'):
            self.query('CALL apoc.periodic.iterate('
                       '"MATCH (n:A) RETURN n ORDER BY n.id", '
                       '"WITH n SET n.fresh=42 WITH n '
                       'CALL apoc.refactor.mergeNodes([n],{properties:n.policy}) '
                       'YIELD node RETURN node", {batchSize:1})')
        self.assertEqual(0, self.db.execute(
            "SELECT count(*) FROM property_keys WHERE key='fresh'").fetchone()[0])
        self.assertEqual(2, self.db.execute('SELECT count(*) FROM nodes').fetchone()[0])

    def test_later_action_rolls_back_all_rows_and_property_key_cache(self):
        self.fail_later_action()
        self.query('MATCH (n:A) SET n.afterRollback=7')
        self.assertEqual(2, self.db.execute(
            "SELECT count(*) FROM node_props_int p JOIN property_keys k ON k.id=p.key_id "
            "WHERE k.key='afterRollback' AND value=7").fetchone()[0])
        self.assertEqual([], self.db.execute('PRAGMA foreign_key_check').fetchall())

    def test_failure_preserves_callers_transaction(self):
        self.db.execute('BEGIN')
        self.fail_later_action()
        self.assertTrue(self.db.in_transaction)
        self.db.execute('ROLLBACK')
        self.assertEqual(0, self.db.execute('SELECT count(*) FROM nodes').fetchone()[0])

    def test_unsupported_config_is_rejected_before_refactoring(self):
        self.query('CREATE (:A {id:1}), (:A {id:2})')
        with self.assertRaisesRegex(sqlite3.Error, 'Unsupported APOC configuration option'):
            self.query('MATCH (n:A) WITH collect(n) AS ns '
                       'CALL apoc.refactor.mergeNodes(ns,{unknown:true}) YIELD node RETURN node')
        self.assertEqual(2, self.db.execute('SELECT count(*) FROM nodes').fetchone()[0])
        with self.assertRaisesRegex(sqlite3.Error, 'configuration value type'):
            self.query('CALL apoc.periodic.iterate("MATCH (n:A) RETURN n",'
                       '"WITH n DETACH DELETE n",{batchSize:"ten"})')
        self.assertEqual(2, self.db.execute('SELECT count(*) FROM nodes').fetchone()[0])

    def test_overwrite_adds_globally_known_property_missing_on_survivor(self):
        self.query('CREATE (a:A), (b:B), '
                   '(a)-[:R {first:1}]->(b), (a)-[:R {last:true}]->(b)')
        self.query('MATCH ()-[r:R]->() WITH collect(r) AS rs '
                   'CALL apoc.refactor.mergeRelationships(rs,{properties:"overwrite"}) '
                   'YIELD rel RETURN rel')
        props = self.query('MATCH ()-[r:R]->() RETURN properties(r) AS p')
        self.assertEqual([{'p': {'first': 1, 'last': True}}], props)
        self.assertEqual(1, self.db.execute('SELECT count(*) FROM edges').fetchone()[0])

    def test_failed_import_projection_cannot_write_with_a_null_binding(self):
        with self.assertRaisesRegex(sqlite3.Error, 'evaluate CALL import expression'):
            self.query('WITH 1 AS x '
                       'CALL (apoc.text.replace("x","[","") AS bad) '
                       '{ CREATE (:ProjectionFailure {value:bad}) } RETURN x')
        self.assertEqual(0, self.db.execute('SELECT count(*) FROM nodes').fetchone()[0])
        self.assertEqual([{'value': None}], self.query(
            'WITH null AS x CALL (x) { RETURN x AS value } RETURN value'))

    def test_later_scoped_call_failure_rolls_back_prior_outer_rows(self):
        self.query('CREATE (:Keep {id:1})')
        with self.assertRaisesRegex(sqlite3.Error, 'dynamic SET property key must be a string'):
            self.query('UNWIND [1,2] AS x CREATE (n:Failed {id:x}) '
                       'CALL (n,x) { WITH n, '
                       'CASE WHEN x=1 THEN "ok" ELSE 1 END AS key '
                       'SET n[key]=true }')
        self.assertEqual(1, self.db.execute('SELECT count(*) FROM nodes').fetchone()[0])
        self.assertEqual([{'id': 1}], self.query('MATCH (n:Keep) RETURN n.id AS id'))
        self.assertEqual([], self.db.execute('PRAGMA foreign_key_check').fetchall())

    def test_null_relationship_identity_is_rejected_without_mutation(self):
        self.query('CREATE (:A), (:B)')
        with self.assertRaisesRegex(sqlite3.Error, 'identity properties cannot be null'):
            self.query('MATCH (a:A),(b:B) '
                       'CALL apoc.merge.relationship(a,"R",{identity:null},{value:1},b) '
                       'YIELD rel RETURN rel')
        self.assertEqual(0, self.db.execute('SELECT count(*) FROM edges').fetchone()[0])
        self.assertEqual(0, self.db.execute(
            "SELECT count(*) FROM property_keys WHERE key IN ('identity','value')").fetchone()[0])

    def test_node_only_options_are_rejected_for_relationship_refactor(self):
        self.query('CREATE (a:A),(b:B),(a)-[:R]->(b),(a)-[:R]->(b)')
        with self.assertRaisesRegex(sqlite3.Error, 'Unsupported APOC configuration option: mergeRels'):
            self.query('MATCH ()-[r:R]->() WITH collect(r) AS rs '
                       'CALL apoc.refactor.mergeRelationships(rs,{mergeRels:true}) '
                       'YIELD rel RETURN rel')
        self.assertEqual(2, self.db.execute('SELECT count(*) FROM edges').fetchone()[0])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--extension', required=True, type=Path)
    args = parser.parse_args()
    EXTENSION = args.extension.resolve()
    unittest.main(argv=['apoc_failures.py'], verbosity=2)
