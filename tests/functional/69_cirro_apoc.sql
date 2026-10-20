-- Fresh fixtures for the supported APOC subset: typed property conflicts,
-- endpoint preservation, dynamic relationship identity and imported actions.
.load ./build/graphqlite
CREATE TEMP TABLE _assert(name TEXT, ok INTEGER NOT NULL CHECK(ok=1));

INSERT INTO _assert SELECT 'JSON serialization preserves string result',
  json_extract(cypher('RETURN apoc.convert.toJson({n:1, flags:[true,false], s:"quoted"}) AS j'), '$[0].j') = '{"n":1,"flags":[true,false],"s":"quoted"}';
INSERT INTO _assert SELECT 'JSON string remains quoted',
  json_extract(cypher('RETURN apoc.convert.toJson("[1]") AS j'), '$[0].j') = '"[1]"';
SELECT cypher('UNWIND [{a:1,yes:true}] AS row MERGE (n:JSONText69 {id:1}) SET n += {serialized:apoc.convert.toJson(row),literal:replace("[1]","1","2")} RETURN n');
INSERT INTO _assert SELECT 'function strings stored as text',
 (SELECT count(*) FROM node_props_text p JOIN node_labels l ON l.node_id=p.node_id JOIN property_keys k ON k.id=p.key_id WHERE l.label='JSONText69' AND k.key IN ('serialized','literal'))=2 AND
 (SELECT count(*) FROM node_props_json p JOIN node_labels l ON l.node_id=p.node_id WHERE l.label='JSONText69')=0;
INSERT INTO _assert SELECT 'regex suffix replacement',
  json_extract(cypher('RETURN apoc.text.replace("https://vault/secrets/key/version", "/[^/]+$", "") AS p'), '$[0].p') = 'https://vault/secrets/key';
INSERT INTO _assert SELECT 'substring index',
  json_extract(cypher('RETURN apoc.text.indexOf("https://vault/secrets/key", "secrets/") AS i'), '$[0].i') = 14;

SELECT cypher('CREATE (a:Keep69 {key:"keep", tags:[1,2], mixed:true}), (b:Drop69 {key:"drop", tags:[2,3], mixed:1}), (c:Outside69 {key:"outside"}), (a)-[:LINK69 {score:1, typed:true}]->(c), (b)-[:LINK69 {score:2, typed:1}]->(c), (c)-[:LINK69 {reverse:1}]->(b), (b)-[:OTHER69 {name:"other"}]->(c), (a)-[:LOOP69 {v:1}]->(a), (a)-[:LOOP69 {v:2}]->(a), (b)-[:LOOP69 {v:3}]->(b), (a)-[:INNER69 {v:2}]->(b)');
CREATE TEMP TABLE kept AS SELECT node_id id FROM node_labels WHERE label='Keep69';
SELECT cypher('MATCH (a:Keep69), (b:Drop69) CALL apoc.refactor.mergeNodes([a,b], {properties:"combine",mergeRels:true}) YIELD node RETURN id(node) AS id');
INSERT INTO _assert SELECT 'first node retained', (SELECT count(*) FROM nodes WHERE id=(SELECT id FROM kept))=1;
INSERT INTO _assert SELECT 'labels united', (SELECT count(*) FROM node_labels WHERE node_id=(SELECT id FROM kept) AND label IN ('Keep69','Drop69'))=2;
INSERT INTO _assert SELECT 'array conflicts combine in order', (SELECT value FROM node_props_json p JOIN property_keys k ON k.id=p.key_id WHERE node_id=(SELECT id FROM kept) AND k.key='tags')='[1,2,3]';
INSERT INTO _assert SELECT 'boolean and integer remain distinct', (SELECT value FROM node_props_json p JOIN property_keys k ON k.id=p.key_id WHERE node_id=(SELECT id FROM kept) AND k.key='mixed')='[true,1]';
INSERT INTO _assert SELECT 'incident direction preserved',
 (SELECT count(*) FROM edges WHERE type='LINK69' AND source_id=(SELECT id FROM kept))=1 AND
 (SELECT count(*) FROM edges WHERE type='LINK69' AND target_id=(SELECT id FROM kept))=1;
INSERT INTO _assert SELECT 'edge typed conflicts combine',
 (SELECT value FROM edge_props_json p JOIN property_keys k ON k.id=p.key_id JOIN edges e ON e.id=p.edge_id WHERE e.type='LINK69' AND e.source_id=(SELECT id FROM kept) AND k.key='typed')='[true,1]';
INSERT INTO _assert SELECT 'other types and self relationships preserved',
 (SELECT count(*) FROM edges WHERE type='OTHER69')=1 AND
 (SELECT count(*) FROM edges WHERE type IN ('LOOP69','INNER69') AND source_id=target_id)=4;

SELECT cypher('MATCH (a:Keep69), (b:Outside69) CALL apoc.merge.relationship(a,"DYNAMIC69",{identity:"one"},{created:7},b) YIELD rel SET rel.note="first" RETURN rel');
SELECT cypher('MATCH (a:Keep69), (b:Outside69) CALL apoc.merge.relationship(a,"DYNAMIC69",{identity:"one"},{created:99},b,{matched:true}) YIELD rel RETURN rel');
INSERT INTO _assert SELECT 'dynamic merge is idempotent', (SELECT count(*) FROM edges WHERE type='DYNAMIC69')=1;
INSERT INTO _assert SELECT 'create properties retained on match', (SELECT value FROM edge_props_int p JOIN edges e ON e.id=p.edge_id JOIN property_keys k ON k.id=p.key_id WHERE e.type='DYNAMIC69' AND k.key='created')=7;
INSERT INTO _assert SELECT 'match properties applied', (SELECT value FROM edge_props_bool p JOIN edges e ON e.id=p.edge_id JOIN property_keys k ON k.id=p.key_id WHERE e.type='DYNAMIC69' AND k.key='matched')=1;

SELECT cypher('MATCH (a:Keep69), (b:Outside69) CREATE (a)-[:DUP69 {x:true, onlyFirst:"a"}]->(b), (a)-[:DUP69 {x:9, onlyLast:"b"}]->(b)');
SELECT cypher('MATCH ()-[r:DUP69]->() WITH collect(r) AS rs CALL apoc.refactor.mergeRelationships(rs,{properties:"overwrite"}) YIELD rel RETURN rel');
INSERT INTO _assert SELECT 'relationship overwrite removes old type',
 (SELECT count(*) FROM edges WHERE type='DUP69')=1 AND
 (SELECT count(*) FROM edge_props_bool p JOIN edges e ON e.id=p.edge_id JOIN property_keys k ON k.id=p.key_id WHERE e.type='DUP69' AND k.key='x')=0 AND
 (SELECT value FROM edge_props_int p JOIN edges e ON e.id=p.edge_id JOIN property_keys k ON k.id=p.key_id WHERE e.type='DUP69' AND k.key='x')=9;

SELECT cypher('CREATE (:Iter69 {name:"FIRST"}), (:Iter69 {name:"SECOND"})');
-- Procedures open an atomic savepoint, so invoke them from a standalone
-- SELECT. SQLite cannot open a savepoint inside an active INSERT statement.
SELECT CASE WHEN json_extract(cypher('CALL apoc.periodic.iterate("MATCH (n:Iter69) RETURN n", "WITH n SET n.name=toLower(n.name) RETURN 1", {batchSize:1,parallel:true}) YIELD total,batches RETURN total,batches'), '$[0].total')=2
 THEN 'periodic imported entities and output counts: ok'
 ELSE json('periodic count assertion failed') END;
INSERT INTO _assert SELECT 'periodic changes actual producer nodes',
 (SELECT count(*) FROM node_props_text p JOIN property_keys k ON k.id=p.key_id JOIN node_labels l ON l.node_id=p.node_id WHERE l.label='Iter69' AND k.key='name' AND value IN ('first','second'))=2;
SELECT CASE WHEN json_extract(cypher('CALL apoc.periodic.iterate("MATCH (n:Absent69) RETURN n", "WITH n SET n.name=toLower(n.name)", {batchSize:1}) YIELD total RETURN total'), '$[0].total')=0
 THEN 'empty periodic producer succeeds: ok'
 ELSE json('empty periodic producer assertion failed') END;
SELECT cypher('CREATE (s:Singleton69), (t:SingleTarget69), (s)-[:SINGLE69]->(t), (s)-[:SINGLE69]->(t)');
SELECT cypher('MATCH (s:Singleton69) CALL apoc.refactor.mergeNodes([s],{mergeRels:true}) YIELD node RETURN node');
INSERT INTO _assert SELECT 'singleton refactor does not collapse existing edges', (SELECT count(*) FROM edges WHERE type='SINGLE69')=2;
SELECT CASE WHEN json_array_length(cypher('CALL apoc.refactor.mergeNodes([],{mergeRels:true}) YIELD node RETURN node'))=0
 THEN 'empty refactor yields no rows: ok'
 ELSE json('empty refactor assertion failed') END;
SELECT name,ok FROM _assert;
