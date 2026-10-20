-- Correlated CALL must preserve both the graph identity and the parent row.
-- Assertions reject NULL as well as false: success statistics alone cannot
-- detect missing properties, wrong relationship endpoints, or dropped rows.
.load ./build/graphqlite
CREATE TEMP TABLE _assert(name TEXT, ok INTEGER NOT NULL CHECK (ok = 1));
INSERT INTO _assert SELECT 'standalone CALL exposes returned columns',
    json(cypher('CALL { RETURN 7 AS value }')) = json('[{"value":7}]');
INSERT INTO _assert SELECT 'UNION deduplicates inside each CALL branch',
    json(cypher('CALL { UNWIND [1,1] AS x RETURN x UNION RETURN 2 AS x } RETURN x ORDER BY x')) = json('[{"x":1},{"x":2}]');
INSERT INTO _assert SELECT 'RETURN star after CALL expands the complete row',
    json(cypher('WITH 3 AS x CALL (x) { RETURN x + 1 AS y } RETURN *')) = json('[{"x":3,"y":4}]');


SELECT cypher('CREATE (:Person67 {id: "a"}), (:Person67 {id: "b"})');
SELECT cypher('MATCH (p:Person67) CALL { WITH p MERGE (g:Team67 {id: "g"}) MERGE (p)-[:IN_TEAM67]->(g) }');
INSERT INTO _assert SELECT 'legacy CALL MERGE carries newly bound endpoints',
    json(cypher('MATCH (p:Person67)-[:IN_TEAM67]->(g:Team67) RETURN p.id AS person, g.id AS team ORDER BY person'))
    = json('[{"person":"a","team":"g"},{"person":"b","team":"g"}]');
SELECT cypher('MATCH (p:Person67) CALL { WITH p MERGE (g:Team67 {id: "g"}) MERGE (p)-[:IN_TEAM67]->(g) }');
INSERT INTO _assert SELECT 'correlated relationship MERGE remains idempotent',
    json_extract(cypher('MATCH ()-[r:IN_TEAM67]->() RETURN count(r) AS c'), '$[0].c') = 2;

-- Original synthetic fixture: users with multiple memberships, one manager,
-- and an empty-list user. The last SET must run even when an inner query has
-- zero rows. Entity IDs and JSON map IDs are deliberately distinct concepts.
CREATE TEMP TABLE _ingest(query TEXT, params TEXT);
INSERT INTO _ingest VALUES (
'UNWIND $batch AS row
 MERGE (person:Identity67 {id: toLower(row.id)})
 SET person:User67
 SET person += {name: row.name, enabled: row.enabled}
 WITH person, row
 CALL (person, row) {
   UNWIND coalesce(row.groups, []) AS groupId
   MERGE (group:Identity67 {id: toLower(groupId)})
   MERGE (person)-[:MEMBER67]->(group)
 }
 CALL (person, row) {
   WITH person, row WHERE row.manager IS NOT NULL
   MERGE (manager:Identity67 {id: toLower(row.manager)})
   MERGE (manager)-[:MANAGES67]->(person)
 }
 SET person.complete = true',
'{"batch":[{"id":"U1","name":"Ada","enabled":true,"groups":["G1","G2"],"manager":"U2"},{"id":"U2","name":"Bea","enabled":false,"groups":["G2"]},{"id":"U3","name":"Cam","enabled":true,"groups":[]}]}');
SELECT cypher(query, params) FROM _ingest;
INSERT INTO _assert SELECT 'batch preserves all user properties and empty inner rows',
    json(cypher('MATCH (p:User67) RETURN p.id AS id, p.name AS name, p.enabled AS enabled, p.complete AS complete ORDER BY id'))
    = json('[{"id":"u1","name":"Ada","enabled":true,"complete":true},{"id":"u2","name":"Bea","enabled":false,"complete":true},{"id":"u3","name":"Cam","enabled":true,"complete":true}]');
INSERT INTO _assert SELECT 'membership endpoints match every input item',
    json(cypher('MATCH (a)-[:MEMBER67]->(b) RETURN a.id AS source, b.id AS target ORDER BY source, target'))
    = json('[{"source":"u1","target":"g1"},{"source":"u1","target":"g2"},{"source":"u2","target":"g2"}]');
INSERT INTO _assert SELECT 'manager direction and identity are correct',
    json(cypher('MATCH (a)-[:MANAGES67]->(b) RETURN a.id AS source, b.id AS target'))
    = json('[{"source":"u2","target":"u1"}]');
SELECT cypher(query, params) FROM _ingest;
INSERT INTO _assert SELECT 'repeat batch does not create duplicate nodes',
    json_extract(cypher('MATCH (n:Identity67) RETURN count(n) AS c'), '$[0].c') = 5;
INSERT INTO _assert SELECT 'repeat batch does not create duplicate relationships',
    json_extract(cypher('MATCH ()-[r:MEMBER67]->() RETURN count(r) AS c'), '$[0].c') = 3
    AND json_extract(cypher('MATCH ()-[r:MANAGES67]->() RETURN count(r) AS c'), '$[0].c') = 1;

INSERT INTO _assert SELECT 'nested calls use their own imported parameter values',
    json(cypher('UNWIND [1,2] AS x CALL (x) { WITH x + 10 AS y CALL (y) { RETURN y AS z } RETURN z } RETURN x, z ORDER BY x'))
    = json('[{"x":1,"z":11},{"x":2,"z":12}]');
INSERT INTO _assert SELECT 'scoped import survives an inner WITH',
    json(cypher('WITH 9 AS x CALL (x) { WITH 4 AS y RETURN x + y AS z } RETURN z')) = json('[{"z":13}]');
INSERT INTO _assert SELECT 'empty unit CALL preserves the outer row',
    json(cypher('UNWIND [1,2] AS x CALL (x) { WITH * WHERE false CREATE (:Absent67) } RETURN x ORDER BY x'))
    = json('[{"x":1},{"x":2}]');
INSERT INTO _assert SELECT 'empty returning CALL drops the outer row',
    json(cypher('UNWIND [1,2] AS x CALL (x) { WITH * WHERE false RETURN x AS y } RETURN x')) = json('[]');
INSERT INTO _assert SELECT 'unit CALL with an empty MATCH preserves the row',
    json(cypher('WITH 7 AS x CALL (x) { MATCH (:Absent67) CREATE (:AlsoAbsent67) } RETURN x')) = json('[{"x":7}]');
INSERT INTO _assert SELECT 'false unit CALL performs no writes',
    json_extract(cypher('MATCH (n:Absent67) RETURN count(n) AS c'), '$[0].c') = 0;

SELECT cypher('MATCH (p:User67) FOREACH (key IN ["tag", "stamp"] | SET p[key] = key)');
INSERT INTO _assert SELECT 'dynamic SET in FOREACH uses the current key',
    json_extract(cypher('MATCH (p:User67) WHERE p.tag = "tag" AND p.stamp = "stamp" RETURN count(p) AS c'), '$[0].c') = 3;

-- Raw provider objects may have a field named properties; that does not make
-- them graph entities, and their other fields must remain at the top level.
INSERT INTO _assert SELECT 'provider map is not mistaken for a graph entity',
    json(cypher('WITH {id: "source", parent: "parent", properties: {url: "value"}} AS row CALL (row) { RETURN row.parent AS parent, row.properties.url AS url, keys(row) AS fields } RETURN parent, url, fields'))
    = json('[{"parent":"parent","url":"value","fields":["id","parent","properties"]}]');
SELECT cypher('UNWIND $batch AS row MERGE (n:Resource67 {id: toLower(row.id)}) MERGE (p:Resource67 {id: toLower(row.parent)}) MERGE (p)-[:PARENT67]->(n)',
    '{"batch":[{"id":"child","parent":"parent","properties":{}}]}');
INSERT INTO _assert SELECT 'map properties member cannot change MERGE endpoints',
    json(cypher('MATCH (p)-[:PARENT67]->(n) RETURN p.id AS parent, n.id AS child')) = json('[{"parent":"parent","child":"child"}]');
SELECT cypher('CREATE (:Subject67)-[:ROLE67 {roleId:"ROLE"}]->(:Scope67), (:Role67 {id:"role", name:"Reader"})');
SELECT cypher('MATCH (:Subject67)-[r:ROLE67]->(:Scope67) MATCH (role:Role67 {id:toLower(r.roleId)}) SET r.name = role.name');
INSERT INTO _assert SELECT 'multiple MATCH clauses preserve relationship scope for SET',
    json(cypher('MATCH ()-[r:ROLE67]->() RETURN r.name AS name')) = json('[{"name":"Reader"}]');

-- Entity-shaped strings are user values even when their id exists in graph.
CREATE TEMP TABLE _entity_string67(value TEXT);
INSERT INTO _entity_string67 VALUES ('{"id":1,"labels":["Person67"],"properties":{}}');
INSERT INTO _assert SELECT 'entity-shaped string remains a string through CALL imports',
    json_extract(cypher('WITH $text AS text CALL (text) { RETURN text AS out } RETURN out',
        json_object('text',value)), '$[0].out') = value
    FROM _entity_string67;
INSERT INTO _assert SELECT 'entity-shaped string remains a string through CALL results',
    json_extract(cypher('CALL () { RETURN $text AS out } RETURN out',
        json_object('text',value)), '$[0].out') = value
    FROM _entity_string67;

SELECT name, ok FROM _assert;
