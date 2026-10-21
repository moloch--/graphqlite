-- BloodHound uses Contains in attack-path relationship alternatives.
.load ./build/graphqlite
CREATE TEMP TABLE _assert(name TEXT, ok INTEGER NOT NULL CHECK (ok=1));
SELECT cypher('CREATE (a:BH74 {id:1}), (b:BH74 {id:2}), (c:BH74 {id:3}), (a)-[:Contains]->(b), (b)-[:MemberOf]->(c)');
INSERT INTO _assert SELECT 'keyword first in alternatives',json(cypher('MATCH (a:BH74)-[r:Contains|MemberOf]->(b) RETURN type(r) AS kind ORDER BY kind'))=json('[{"kind":"Contains"},{"kind":"MemberOf"}]');
INSERT INTO _assert SELECT 'keyword second in alternatives',json(cypher('MATCH (a:BH74)-[r:MemberOf|Contains]->(b) RETURN type(r) AS kind ORDER BY kind'))=json('[{"kind":"Contains"},{"kind":"MemberOf"}]');
INSERT INTO _assert SELECT 'keyword after colon alternative',json(cypher('MATCH (a:BH74)-[r:MemberOf|:Contains]->(b) RETURN type(r) AS kind ORDER BY kind'))=json('[{"kind":"Contains"},{"kind":"MemberOf"}]');
INSERT INTO _assert SELECT 'keyword in recursive alternatives',json(cypher('MATCH p=shortestPath((a:BH74 {id:1})-[:Absent|MemberOf|Contains*]->(b:BH74 {id:3})) RETURN length(p) AS hops'))=json('[{"hops":2}]');
INSERT INTO _assert SELECT 'keyword types remain case sensitive',json(cypher('MATCH (a:BH74)-[r:MemberOf|CONTAINS]->(b) RETURN type(r) AS kind'))=json('[{"kind":"MemberOf"}]');
SELECT count(*) AS passed FROM _assert;
