-- JSON types must survive SQLite scalar-subquery and aggregation boundaries.
-- Test the actual result shape; do not decode JSON-looking strings twice.
.load ./build/graphqlite
CREATE TEMP TABLE _assert(name TEXT, ok INTEGER NOT NULL CHECK (ok = 1));

SELECT cypher('CREATE (a:Types71 {id: 1, flag: true, values: [1, 2], raw: "[1,2]", word: "true", dates: [date("2020-01-02")]})-[:LINK71 {flag: false, values: [3, 4], raw: "[3,4]"}]->(:Types71 {id: 2})') AS setup;
INSERT INTO _assert
SELECT 'unsorted node properties keep their stored types',
  json_type(result, '$[0].flag') = 'true' AND
  json_type(result, '$[0].values') = 'array' AND
  json_type(result, '$[0].raw') = 'text' AND
  json_type(result, '$[0].word') = 'text' AND
  json_type(result, '$[0].dates') = 'array' AND
  json_extract(result, '$[0].dates[0]') = '2020-01-02'
FROM (SELECT cypher('MATCH (n:Types71 {id: 1}) RETURN n.flag AS flag, n.values AS values, n.raw AS raw, n.word AS word, n.dates AS dates') AS result);

INSERT INTO _assert
SELECT 'unsorted relationship properties keep their stored types',
  json_type(result, '$[0].flag') = 'false' AND
  json_type(result, '$[0].values') = 'array' AND
  json_type(result, '$[0].raw') = 'text'
FROM (SELECT cypher('MATCH ()-[r:LINK71]->() RETURN r.flag AS flag, r.values AS values, r.raw AS raw') AS result);

INSERT INTO _assert
SELECT 'property boolean remains a native SQL boolean through cypher_rows',
  c0 = 1 AND typeof(c0) = 'integer' AND json_type(row, '$.flag') = 'true'
FROM cypher_rows('MATCH (n:Types71 {id: 1}) RETURN n.flag AS flag');

INSERT INTO _assert SELECT 'property values keep types when nested in a list',
  json(cypher('MATCH (n:Types71 {id: 1}) RETURN [n.flag, n.values, n.raw, n.word] AS values')) =
  json('[{"values":[true,[1,2],"[1,2]","true"]}]');
INSERT INTO _assert SELECT 'stored booleans differ from numbers and strings',
  json(cypher('MATCH (n:Types71 {id: 1}) RETURN [n.flag = 1, n.flag IN [1], n.flag = true, n.flag IN [true], n.word = true, n.raw = [1,2]] AS values')) =
  json('[{"values":[false,false,true,true,false,false]}]');
INSERT INTO _assert SELECT 'relationship boolean comparisons keep types',
  json(cypher('MATCH ()-[r:LINK71]->() RETURN [r.flag = 0, r.flag IN [0], r.flag = false, r.flag IN [false]] AS values')) =
  json('[{"values":[false,false,true,true]}]');

INSERT INTO _assert SELECT 'JSON-looking text is distinct from containers and null',
  json(cypher('MATCH (n:Types71 {id: 1}) RETURN [n.raw <> [1,2], [1,2] = n.raw, n.values = [1,2], n.raw = [null], "null" = [], "{}" = {}, n.missing = []] AS values')) =
  json('[{"values":[true,false,true,false,false,false,null]}]');

-- Repeated typed predicates exceed the WITH translator's initial buffer.
-- A growing buffer must retain ownership through the WHERE capture.
INSERT INTO _assert SELECT 'WITH preserves a growing typed predicate buffer',
  json(cypher('MATCH (n:Types71 {id: 1}) WITH n WHERE n.flag = $flag AND n.values = $values AND n.raw = $raw AND n.word = $word RETURN n.id AS id', '{"flag":true,"values":[1,2],"raw":"[1,2]","word":"true"}')) =
  json('[{"id":1}]');

INSERT INTO _assert
SELECT 'collect nodes retains nested arrays and node objects',
  json_type(result, '$[0].paths') = 'array' AND
  json_type(result, '$[0].paths[0]') = 'array' AND
  json_type(result, '$[0].paths[0][0]') = 'object' AND
  json_extract(result, '$[0].paths[0][0].properties.id') = 1 AND
  json_extract(result, '$[0].paths[0][1].properties.id') = 2
FROM (SELECT cypher('MATCH p = (a:Types71)-[:LINK71*]->(b:Types71) RETURN collect(nodes(p)) AS paths') AS result);

INSERT INTO _assert
SELECT 'collect relationships retains nested arrays and edge objects',
  json_type(result, '$[0].paths[0]') = 'array' AND
  json_type(result, '$[0].paths[0][0]') = 'object' AND
  json_extract(result, '$[0].paths[0][0].type') = 'LINK71'
FROM (SELECT cypher('MATCH p = (a:Types71)-[:LINK71*]->(b:Types71) RETURN collect(relationships(p)) AS paths') AS result);

INSERT INTO _assert
SELECT 'forwarded path members retain nested arrays',
  json_type(result, '$[0].paths[0]') = 'array' AND
  json_type(result, '$[0].paths[0][0]') = 'object'
FROM (SELECT cypher('MATCH p = (a:Types71)-[:LINK71]->(b:Types71) WITH p RETURN collect(nodes(p)) AS paths') AS result);

INSERT INTO _assert
SELECT 'MERGE path has array-valued nodes and relationships',
  json_type(result, '$[0].p.nodes') = 'array' AND
  json_type(result, '$[0].p.nodes[0]') = 'object' AND
  json_type(result, '$[0].p.rels') = 'array'
FROM (SELECT cypher('MERGE p = (n:Merged71 {id: 1}) RETURN p') AS result);

SELECT name, ok FROM _assert;
