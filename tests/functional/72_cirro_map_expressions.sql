-- Computed SET map entries must be evaluated, typed, and stored, not omitted.
.load ./build/graphqlite
CREATE TEMP TABLE _assert(name TEXT, ok INTEGER NOT NULL CHECK (ok = 1));

INSERT INTO _assert SELECT 'case aliases',
  json(cypher('RETURN lower("MiXeD") AS lo, upper("MiXeD") AS hi')) =
  json('[{"lo":"mixed","hi":"MIXED"}]');

SELECT cypher('UNWIND [{id:1, `@odata.type`:"#Example.User", tags:{origin:"fixture"}}, {id:2, `@odata.type`:"#Example.Group", tags:{}}] AS row MERGE (n:Computed72 {id:row.id}) SET n += {odataType:lower(row["@odata.type"]), tags:[key IN keys(row.tags) | key + ":" + row.tags[key]], flag:true, nested:[true,[false,1],"[1]"], raw:lower("[TRUE]")}');
INSERT INTO _assert SELECT 'nonempty and empty tags are arrays',
  json(cypher('MATCH (n:Computed72) RETURN n.id AS id, n.odataType AS odataType, n.tags AS tags ORDER BY id')) =
  json('[{"id":1,"odataType":"#example.user","tags":["origin:fixture"]},{"id":2,"odataType":"#example.group","tags":[]}]');
INSERT INTO _assert SELECT 'nested values and JSON-looking strings retain their types',
  json(cypher('MATCH (n:Computed72 {id:1}) RETURN n.flag AS flag, n.nested AS nested, n.raw AS raw')) =
  json('[{"flag":true,"nested":[true,[false,1],"[1]"],"raw":"[true]"}]');

SELECT cypher('UNWIND [{id:1,values:[[1,2],[3]]}] AS row MATCH (n:Computed72 {id:row.id}) SET n += {nested:[x IN row.values | [x IN x | x + 1]], shadow:[n IN [1,2] | n + 1], filtered:[x IN [true,false] WHERE x | x], selected:CASE WHEN row.id=1 THEN keys(row) ELSE [] END}');
INSERT INTO _assert SELECT 'comprehension nesting, shadowing and predicate scope',
  json(cypher('MATCH (n:Computed72 {id:1}) RETURN n.nested AS nested, n.shadow AS shadow, n.filtered AS filtered, n.selected AS selected')) =
  json('[{"nested":[[2,3],[4]],"shadow":[2,3],"filtered":[true],"selected":["id","values"]}]');

SELECT cypher('MATCH (n:Computed72 {id:2}) SET n.tags=[x IN [1,2] | x + 3]');
INSERT INTO _assert SELECT 'standalone property SET comprehension',
  json(cypher('MATCH (n:Computed72 {id:2}) RETURN n.tags AS tags')) = json('[{"tags":[4,5]}]');

SELECT cypher('CREATE (:Replace72 {old:"kept", remove:"gone"})');
SELECT cypher('MATCH (n:Replace72) SET n={copy:n.old, typed:[true,false]}');
INSERT INTO _assert SELECT 'map replacement evaluates before deleting original properties',
  json(cypher('MATCH (n:Replace72) RETURN n.old AS old, n.remove AS removed, n.copy AS copy, n.typed AS typed')) =
  json('[{"old":null,"removed":null,"copy":"kept","typed":[true,false]}]');
SELECT cypher('MATCH (n:Replace72) SET n += {copy:null}');
INSERT INTO _assert SELECT 'null in map update removes a property',
  json(cypher('MATCH (n:Replace72) RETURN keys(n) AS keys')) = json('[{"keys":["typed"]}]');
INSERT INTO _assert SELECT 'repeated null map update is a no-op',
  json(cypher('MATCH (n:Replace72) SET n += {copy:null} RETURN keys(n) AS keys')) = json('[{"keys":["typed"]}]');

SELECT cypher('MATCH (n:Computed72 {id:2}) SET n.tags=keys({a:1})');
INSERT INTO _assert SELECT 'standalone function SET preserves list type',
  json(cypher('MATCH (n:Computed72 {id:2}) RETURN n.tags AS tags')) = json('[{"tags":["a"]}]');

INSERT INTO _assert SELECT 'null input propagates through comprehensions',
  json(cypher('WITH {empty:[], missing:null} AS row RETURN [x IN row.empty | x] AS empty, [x IN row.missing | x] AS missing, [x IN keys(row.absent) | x] AS absent')) =
  json('[{"empty":[],"missing":null,"absent":null}]');
SELECT cypher('MATCH (n:Computed72 {id:1}) SET n += {fromNull:[x IN null | x], fromMissing:[x IN keys(n.absent) | x]}');
INSERT INTO _assert SELECT 'null and absent list inputs do not become array properties',
  json(cypher('MATCH (n:Computed72 {id:1}) RETURN n.fromNull AS fromNull, n.fromMissing AS fromMissing')) =
  json('[{"fromNull":null,"fromMissing":null}]');
INSERT INTO _assert SELECT 'null SET target skips map evaluation',
  json(cypher('OPTIONAL MATCH (n:Missing72) SET n += {x:1} RETURN n')) = json('[{"n":null}]');

SELECT name, ok FROM _assert;
