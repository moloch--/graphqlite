.load ./build/graphqlite
CREATE TEMP TABLE _assert(name TEXT, ok INTEGER NOT NULL CHECK (ok=1));
INSERT INTO _assert SELECT 'column order survives maps',json(cypher_result('RETURN 1 AS zebra, 2 AS alpha'))=json('{"columns":["zebra","alpha"],"rows":[{"zebra":1,"alpha":2}]}');
INSERT INTO _assert SELECT 'empty projection schema',json(cypher_result('MATCH (n:Missing75) RETURN n.name AS zebra, n.objectid AS alpha'))=json('{"columns":["zebra","alpha"],"rows":[]}');
INSERT INTO _assert SELECT 'typed parameters',json(cypher_result('RETURN $b AS flag, $s AS text, $a AS array','{"b":true,"s":"42","a":[1,"x"]}'))=json('{"columns":["flag","text","array"],"rows":[{"flag":true,"text":"42","array":[1,"x"]}]}');
INSERT INTO _assert SELECT 'null is not a missing row',json(cypher_result('RETURN null AS value'))=json('{"columns":["value"],"rows":[{"value":null}]}');
INSERT INTO _assert SELECT 'escaped column names',json(cypher_result('RETURN 1 AS `quote"name`'))=json('{"columns":["quote\"name"],"rows":[{"quote\"name":1}]}');
SELECT count(*) AS passed FROM _assert;
