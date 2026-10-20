-- Entity exports must contain structured JSON, not JSON encoded as text.
.load ./build/graphqlite
.bail on
CREATE TEMP TABLE assert_true (ok INTEGER NOT NULL CHECK(ok = 1));
SELECT cypher('CREATE (a:Person:Account {id: "a", active: true, roles: ["reader", "writer"]}), (b:Person {id: "b"}), (a)-[:KNOWS {active: false, scores: [1,2]}]->(b)');
INSERT INTO assert_true SELECT json_type(value, '$.n.labels') = 'array' AND json_type(value, '$.n.properties') = 'object' FROM json_each(cypher('MATCH (n) RETURN n'));
INSERT INTO assert_true SELECT json_extract(value, '$.n.properties.active') = 1 AND json_type(value, '$.n.properties.active') = 'true' AND json_type(value, '$.n.properties.roles') = 'array' FROM json_each(cypher('MATCH (n {id: "a"}) RETURN n'));
INSERT INTO assert_true SELECT json_type(value, '$.r.properties') = 'object' AND json_type(value, '$.r.properties.active') = 'false' AND json_type(value, '$.r.properties.scores') = 'array' FROM json_each(cypher('MATCH ()-[r]->() RETURN r'));
INSERT INTO assert_true SELECT count(*) = 4 FROM assert_true;
