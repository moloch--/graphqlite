-- ========================================================================
-- Test 52: cypher_capabilities() (GQLITE-T-0100, GitHub #17)
-- ========================================================================
-- PURPOSE: The capability document is valid JSON with the documented keys;
--          flags reflect this build (full EXISTS subquery on, LOAD CSV off).
-- NOTE:    Assertions are hard: _assert has CHECK (ok = 1), so under
--          `sqlite3 -bail` any failed expectation aborts the run.
-- ========================================================================

.load ./build/graphqlite

SELECT '=== Test 52: cypher_capabilities() ===' as test_section;

CREATE TEMP TABLE _assert(name TEXT, ok INTEGER NOT NULL CHECK (ok = 1));

INSERT INTO _assert SELECT 'T-0100 1.1 valid JSON', json_valid(cypher_capabilities()) = 1;
INSERT INTO _assert SELECT 'T-0100 1.2 schema_version 1', json_extract(cypher_capabilities(), '$.schema_version') = 1;
INSERT INTO _assert SELECT 'T-0100 1.3 version present', length(json_extract(cypher_capabilities(), '$.graphqlite_version')) >= 5;
INSERT INTO _assert SELECT 'T-0100 1.4 dialect', json_extract(cypher_capabilities(), '$.cypher_dialect') = 'openCypher 9';
INSERT INTO _assert SELECT 'T-0100 1.5 sqlite version matches library', json_extract(cypher_capabilities(), '$.sqlite.version') = sqlite_version();
INSERT INTO _assert SELECT 'T-0100 1.6 json1', json_extract(cypher_capabilities(), '$.sqlite.json1') = 1;
INSERT INTO _assert SELECT 'T-0100 2.1 full EXISTS flag on', json_extract(cypher_capabilities(), '$.features.existential_subquery_full') = 1;
INSERT INTO _assert SELECT 'T-0100 2.2 load_csv flag on', json_extract(cypher_capabilities(), '$.features.load_csv') = 1;
INSERT INTO _assert SELECT 'T-0100 2.3 deterministic', cypher_capabilities() = cypher_capabilities();
INSERT INTO _assert SELECT 'scoped CALL', json_extract(cypher_capabilities(), '$.features.call_subquery_scoped') = 1;
INSERT INTO _assert SELECT 'projected CALL imports', json_extract(cypher_capabilities(), '$.features.call_import_projections') = 1;
INSERT INTO _assert SELECT 'conditional WHEN', json_extract(cypher_capabilities(), '$.features.conditional_when') = 1;
INSERT INTO _assert SELECT 'dynamic property SET', json_extract(cypher_capabilities(), '$.features.dynamic_property_set') = 1;
INSERT INTO _assert SELECT 'typed SET expression values', json_extract(cypher_capabilities(), '$.features.set_typed_expression_values') = 1;
INSERT INTO _assert SELECT 'string case aliases', json_extract(cypher_capabilities(), '$.features.string_case_aliases') = 1;
INSERT INTO _assert SELECT 'named APOC compatibility subset',
  json_extract(cypher_capabilities(), '$.features.apoc_convert_tojson') = 1 AND
  json_extract(cypher_capabilities(), '$.features.apoc_text_replace_posix_regex') = 1 AND
  json_extract(cypher_capabilities(), '$.features.apoc_text_indexof') = 1 AND
  json_extract(cypher_capabilities(), '$.features.apoc_refactor_mergenodes_subset') = 1 AND
  json_extract(cypher_capabilities(), '$.features.apoc_refactor_mergerelationships_subset') = 1 AND
  json_extract(cypher_capabilities(), '$.features.apoc_merge_relationship') = 1 AND
  json_extract(cypher_capabilities(), '$.features.apoc_periodic_iterate_sequential_atomic') = 1;
INSERT INTO _assert SELECT 'full Neo4j compatibility remains disabled', json_extract(cypher_capabilities(), '$.neo4j_compat') = 0;

SELECT name, ok FROM _assert;
SELECT '=== Test 52 Complete ===' as test_section;
