-- Scoped subqueries, conditional updates, and conservative template extensions.
-- Independent fixtures: no application templates or external data are embedded.
.load ./build/graphqlite

CREATE TEMP TABLE _assert(name TEXT, ok INTEGER NOT NULL CHECK (ok = 1));

INSERT INTO _assert SELECT 'named imports',
  json(cypher('UNWIND [2, 4] AS x CALL (x) { RETURN x * 3 AS y } RETURN x, y ORDER BY x')) =
  json('[{"x":2,"y":6},{"x":4,"y":12}]');
INSERT INTO _assert SELECT 'wildcard imports',
  json(cypher('WITH 2 AS x, 5 AS y CALL (*) { RETURN x + y AS z } RETURN z')) = json('[{"z":7}]');
INSERT INTO _assert SELECT 'empty import scope',
  json(cypher('WITH 9 AS x CALL () { RETURN 4 AS y } RETURN x, y')) = json('[{"x":9,"y":4}]');
INSERT INTO _assert SELECT 'quoted import',
  json(cypher('WITH 6 AS `two words` CALL (`two words`) { RETURN `two words` + 1 AS n } RETURN n')) = json('[{"n":7}]');
INSERT INTO _assert SELECT 'imports survive inner WITH',
  json(cypher('WITH 7 AS x CALL (x) { WITH 2 AS y RETURN x + y AS n } RETURN n')) = json('[{"n":9}]');
INSERT INTO _assert SELECT 'nested wildcard retains explicit import',
  json(cypher('WITH 3 AS x CALL (x) { WITH 2 AS y CALL (*) { RETURN x + y AS z } RETURN z AS n } RETURN n')) = json('[{"n":5}]');
INSERT INTO _assert SELECT 'scoped union',
  json(cypher('WITH 2 AS x CALL (x) { RETURN x AS y UNION ALL RETURN x + 1 AS y } RETURN y ORDER BY y')) = json('[{"y":2},{"y":3}]');

INSERT INTO _assert SELECT 'missing named import rejected',
  json_extract(cypher_validate('WITH 1 AS x CALL (missing) { RETURN 1 AS y } RETURN y'), '$.error') LIKE 'SyntaxError: UndefinedVariable:%';
INSERT INTO _assert SELECT 'unimported return variable rejected',
  json_extract(cypher_validate('WITH 1 AS x, 2 AS hidden CALL (x) { RETURN hidden AS y } RETURN y'), '$.error') LIKE 'SyntaxError: UndefinedVariable:%';
INSERT INTO _assert SELECT 'empty imports do not inherit outer scope',
  json_extract(cypher_validate('WITH 1 AS x CALL () { RETURN x AS y } RETURN y'), '$.error') LIKE 'SyntaxError: UndefinedVariable:%';
INSERT INTO _assert SELECT 'duplicate import rejected',
  json_extract(cypher_validate('WITH 1 AS x CALL (x, x) { RETURN x AS y } RETURN y'), '$.error') LIKE 'SyntaxError: VariableAlreadyBound:%';
INSERT INTO _assert SELECT 'import cannot be rebound by WITH',
  json_extract(cypher_validate('WITH 1 AS x CALL (x) { WITH 2 AS x RETURN x AS y } RETURN y'), '$.error') LIKE 'SyntaxError: VariableAlreadyBound:%';
INSERT INTO _assert SELECT 'subquery output cannot overwrite outer variable',
  json_extract(cypher_validate('WITH 1 AS x CALL (x) { RETURN x } RETURN x'), '$.error') LIKE 'SyntaxError: VariableAlreadyBound:%';
INSERT INTO _assert SELECT 'unimported variable in map rejected',
  json_extract(cypher_validate('WITH 1 AS x, 2 AS hidden CALL (x) { RETURN {value: hidden} AS y } RETURN y'), '$.error') LIKE 'SyntaxError: UndefinedVariable:%';
INSERT INTO _assert SELECT 'unimported variable in CASE rejected',
  json_extract(cypher_validate('WITH 1 AS x, 2 AS hidden CALL (x) { RETURN CASE WHEN x = 1 THEN hidden ELSE 0 END AS y } RETURN y'), '$.error') LIKE 'SyntaxError: UndefinedVariable:%';
INSERT INTO _assert SELECT 'list comprehension local variable is allowed',
  json(cypher('WITH [1, 2] AS xs CALL (xs) { RETURN [v IN xs | v + 1] AS ys } RETURN ys')) = json('[{"ys":[2,3]}]');

-- Projected imports are a compatibility extension, evaluated from the outer
-- row. An alias does not replace or leak back into the outer variable.
INSERT INTO _assert SELECT 'projected imports per row',
  json(cypher('UNWIND [2, 5] AS x CALL (x, x + 1 AS y) { WITH 10 AS z RETURN x + y + z AS n } RETURN x, n ORDER BY x')) =
  json('[{"x":2,"n":15},{"x":5,"n":21}]');
INSERT INTO _assert SELECT 'projection can read outer variable without importing it',
  json(cypher('WITH 4 AS x CALL (x + 1 AS y) { RETURN y AS n } RETURN n')) = json('[{"n":5}]');
INSERT INTO _assert SELECT 'projection does not implicitly import its free variables',
  json_extract(cypher_validate('WITH 4 AS x CALL (x + 1 AS y) { RETURN x AS n } RETURN n'), '$.error') LIKE 'SyntaxError: UndefinedVariable:%';
INSERT INTO _assert SELECT 'projected import missing variable rejected',
  json_extract(cypher_validate('WITH 1 AS x CALL (missing + 1 AS y) { RETURN y AS n } RETURN n'), '$.error') LIKE 'SyntaxError: UndefinedVariable:%';
INSERT INTO _assert SELECT 'projected alias collision rejected',
  json_extract(cypher_validate('WITH 1 AS x CALL (x, 2 AS x) { RETURN x AS n } RETURN n'), '$.error') LIKE 'SyntaxError: VariableAlreadyBound:%';
INSERT INTO _assert SELECT 'projection requires explicit alias',
  json_extract(cypher_validate('WITH 1 AS x CALL (x + 1) { RETURN 1 AS n } RETURN n'), '$.valid') = 0;

INSERT INTO _assert SELECT 'false and null conditions preserve outer rows',
  json(cypher('UNWIND [true, false, null] AS enabled WHEN enabled THEN { CREATE (:Conditional68 {flag: true}) } CREATE (:After68) RETURN count(*) AS n')) = json('[{"n":3}]');
INSERT INTO _assert SELECT 'only true branch writes',
  json_extract(cypher('MATCH (n:Conditional68) RETURN count(n) AS n'), '$[0].n') = 1;
INSERT INTO _assert SELECT 'following clause runs for all outer rows',
  json_extract(cypher('MATCH (n:After68) RETURN count(n) AS n'), '$[0].n') = 3;
SELECT cypher('UNWIND [{key: "a", items: []}, {key: "b", items: [1, 2]}] AS row CALL (row) { WHEN size(row.items) > 0 THEN { UNWIND row.items AS value CREATE (:Nested68 {key: row.key, value: value}) } } CREATE (:Outer68 {key: row.key})') AS nested_condition;
INSERT INTO _assert SELECT 'conditional UNWIND body',
  json(cypher('MATCH (n:Nested68) RETURN n.key AS k, n.value AS v ORDER BY v')) = json('[{"k":"b","v":1},{"k":"b","v":2}]');
INSERT INTO _assert SELECT 'conditional empty input leaves parent row intact',
  json_extract(cypher('MATCH (n:Outer68) RETURN count(n) AS n'), '$[0].n') = 2;

SELECT cypher('CREATE (n:Dynamic68) WITH n, {alpha: 7, beta: "value"} AS values FOREACH (k IN keys(values) | SET n[k] = values[k])') AS dynamic_set;
INSERT INTO _assert SELECT 'dynamic properties retain value types',
  json(cypher('MATCH (n:Dynamic68) RETURN n.alpha AS a, n.beta AS b')) = json('[{"a":7,"b":"value"}]');
INSERT INTO _assert SELECT 'single trailing map comma accepted',
  json(cypher('RETURN {a: 1, b: 2,} AS m')) = json('[{"m":{"a":1,"b":2}}]');
INSERT INTO _assert SELECT 'repeated map comma rejected',
  json_extract(cypher_validate('RETURN {a: 1,,} AS m'), '$.valid') = 0;
INSERT INTO _assert SELECT 'three-part function name parses',
  json_extract(cypher_validate('RETURN apoc.convert.toJson({a: 1}) AS value'), '$.valid') = 1;
INSERT INTO _assert SELECT 'procedure keyword component parses',
  json_extract(cypher_validate('CALL apoc.merge.relationship(null, "R", {}, {}, null) YIELD rel RETURN rel'), '$.valid') = 1;

SELECT name, ok FROM _assert;
