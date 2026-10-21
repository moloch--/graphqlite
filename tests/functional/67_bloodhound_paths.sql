-- BloodHound path semantics: tied shortest paths, genuine unbounded trails,
-- and correlated variable-length EXISTS in both full and pattern forms.
-- All assertions reject NULL as well as false, so missing rows cannot pass.
.load ./build/graphqlite
CREATE TEMP TABLE _assert(name TEXT, ok INTEGER NOT NULL CHECK (ok = 1));

SELECT cypher('CREATE (a:BH67:BH67Start {name: "A"}), (b:BH67 {name: "B"}), (c:BH67 {name: "C"}), (d:BH67:BH67Target {name: "D", highvalue: true}), (e:BH67:BH67Target {name: "E", highvalue: false}), (z:BH67:BH67Start {name: "Z"}), (a)-[:BH67_R]->(b), (a)-[:BH67_R]->(c), (b)-[:BH67_R]->(d), (c)-[:BH67_R]->(d), (d)-[:BH67_R]->(e)');

INSERT INTO _assert SELECT 'shortestPath chooses one tied shortest path',
    json(cypher('MATCH p=shortestPath((a:BH67 {name:"A"})-[:BH67_R*1..]->(d:BH67 {name:"D"})) RETURN length(p) AS hops')) = json('[{"hops":2}]');
INSERT INTO _assert SELECT 'allShortestPaths keeps both tied shortest paths',
    json(cypher('MATCH p=allShortestPaths((a:BH67 {name:"A"})-[:BH67_R*1..]->(d:BH67 {name:"D"})) RETURN length(p) AS hops')) = json('[{"hops":2},{"hops":2}]');
INSERT INTO _assert SELECT 'shortest selection is per endpoint pair',
    json(cypher('MATCH p=shortestPath((a:BH67 {name:"A"})-[:BH67_R*1..]->(d:BH67Target)) RETURN d.name AS name,length(p) AS hops ORDER BY name')) = json('[{"name":"D","hops":2},{"name":"E","hops":3}]');
INSERT INTO _assert SELECT 'shortest reversed direction',
    json(cypher('MATCH p=shortestPath((d:BH67 {name:"D"})<-[:BH67_R*1..]-(a:BH67 {name:"A"})) RETURN length(p) AS hops')) = json('[{"hops":2}]');
INSERT INTO _assert SELECT 'allShortest reversed direction',
    json(cypher('MATCH p=allShortestPaths((d:BH67 {name:"D"})<-[:BH67_R*1..]-(a:BH67 {name:"A"})) RETURN length(p) AS hops')) = json('[{"hops":2},{"hops":2}]');
INSERT INTO _assert SELECT 'shortest undirected direction',
    json(cypher('MATCH p=shortestPath((d:BH67 {name:"D"})-[:BH67_R*1..]-(a:BH67 {name:"A"})) RETURN length(p) AS hops')) = json('[{"hops":2}]');
INSERT INTO _assert SELECT 'shortest max bound excludes longer paths',
    json_array_length(cypher('MATCH p=shortestPath((a:BH67 {name:"A"})-[:BH67_R*1..1]->(d:BH67 {name:"D"})) RETURN p')) = 0;
INSERT INTO _assert SELECT 'shortest disconnected endpoint gives no rows',
    json_array_length(cypher('MATCH p=shortestPath((a:BH67 {name:"A"})-[:BH67_R*1..]->(z:BH67 {name:"Z"})) RETURN p')) = 0;

INSERT INTO _assert SELECT 'OPTIONAL shortest preserves missing outer match',
    json(cypher('MATCH (u:BH67Start) OPTIONAL MATCH p=shortestPath((u)-[:BH67_R*1..]->(g:BH67Target {name:"D"})) RETURN u.name AS name,length(p) AS hops ORDER BY name')) = json('[{"name":"A","hops":2},{"name":"Z","hops":null}]');
INSERT INTO _assert SELECT 'OPTIONAL allShortest preserves ties and missing row',
    json(cypher('MATCH (u:BH67Start) OPTIONAL MATCH p=allShortestPaths((u)-[:BH67_R*1..]->(g:BH67Target {name:"D"})) RETURN u.name AS name,length(p) AS hops ORDER BY name')) = json('[{"name":"A","hops":2},{"name":"A","hops":2},{"name":"Z","hops":null}]');

INSERT INTO _assert SELECT 'full EXISTS variable length with inner WHERE',
    json(cypher('MATCH (u:BH67Start) WHERE EXISTS { MATCH (u)-[:BH67_R*1..]->(g:BH67Target) WHERE g.highvalue=true } RETURN u.name AS name')) = json('[{"name":"A"}]');
INSERT INTO _assert SELECT 'NOT EXISTS preserves disconnected outer rows',
    json(cypher('MATCH (u:BH67Start) WHERE NOT EXISTS { MATCH (u)-[:BH67_R*1..]->(g:BH67Target) WHERE g.highvalue=true } RETURN u.name AS name')) = json('[{"name":"Z"}]');
INSERT INTO _assert SELECT 'full EXISTS rejects unsatisfied inner WHERE',
    json_array_length(cypher('MATCH (u:BH67Start) WHERE EXISTS { MATCH (u)-[:BH67_R*1..]->(g:BH67Target) WHERE g.name="missing" } RETURN u')) = 0;
INSERT INTO _assert SELECT 'full EXISTS endpoint property map',
    json(cypher('MATCH (u:BH67Start) WHERE EXISTS { MATCH (u)-[:BH67_R*1..]->(g:BH67Target {name:"D"}) } RETURN u.name AS name')) = json('[{"name":"A"}]');
INSERT INTO _assert SELECT 'full EXISTS correlates both endpoints',
    json(cypher('MATCH (u:BH67Start),(g:BH67Target {name:"D"}) WHERE EXISTS { MATCH (u)-[:BH67_R*1..]->(g) } RETURN u.name AS name')) = json('[{"name":"A"}]');
INSERT INTO _assert SELECT 'bound endpoint label in variable-length EXISTS',
    json(cypher('MATCH (u:BH67Start),(g:BH67Target {name:"D"}) WHERE EXISTS { MATCH (u)-[:BH67_R*1..]->(g:BH67Target) } RETURN u.name AS name')) = json('[{"name":"A"}]');
INSERT INTO _assert SELECT 'disjunctive pattern predicates retain missing-label semantics',
    json(cypher('MATCH (a:BH67),(b:BH67) WHERE a.name="A" AND (a)-[:BH67_R]->(b:BH67) OR (a)-[:BH67_R*]->(b:BH67Missing) RETURN DISTINCT b.name AS name ORDER BY name')) = json('[{"name":"B"},{"name":"C"}]');
INSERT INTO _assert SELECT 'disjunctive pattern predicates after WITH',
    json(cypher('MATCH (a:BH67),(b:BH67) WITH a,b WHERE a.name="A" AND (a)-[:BH67_R]->(b:BH67) OR (a)-[:BH67_R*]->(b:BH67Missing) RETURN DISTINCT b.name AS name ORDER BY name')) = json('[{"name":"B"},{"name":"C"}]');
INSERT INTO _assert SELECT 'full EXISTS bound source property is enforced',
    json_array_length(cypher('MATCH (u:BH67Start {name:"A"}) WHERE EXISTS { MATCH (u {name:"Z"})-[:BH67_R*1..]->(:BH67Target) } RETURN u')) = 0;
INSERT INTO _assert SELECT 'full EXISTS bound target property is enforced',
    json_array_length(cypher('MATCH (u:BH67Start {name:"A"}),(g:BH67Target {name:"D"}) WHERE EXISTS { MATCH (u)-[:BH67_R*1..]->(g {name:"missing"}) } RETURN u')) = 0;
INSERT INTO _assert SELECT 'nested variable-length EXISTS stays correlated',
    json(cypher('MATCH (u:BH67Start) WHERE EXISTS { MATCH (u)-[:BH67_R*1..]->(g:BH67Target) WHERE EXISTS { MATCH (u)-[:BH67_R*1..]->(g) } } RETURN u.name AS name')) = json('[{"name":"A"}]');
INSERT INTO _assert SELECT 'full EXISTS after WITH remains correlated',
    json(cypher('MATCH (u:BH67Start) WITH u WHERE EXISTS { MATCH (u)-[:BH67_R*1..]->(g:BH67Target) WHERE g.highvalue=true } RETURN u.name AS name')) = json('[{"name":"A"}]');
INSERT INTO _assert SELECT 'full EXISTS undirected traversal',
    json(cypher('MATCH (u:BH67Start) WHERE EXISTS { MATCH (g:BH67Target {name:"D"})-[:BH67_R*1..]-(u) } RETURN u.name AS name')) = json('[{"name":"A"}]');
INSERT INTO _assert SELECT 'full EXISTS reversed traversal',
    json(cypher('MATCH (g:BH67Target {name:"D"}) WHERE EXISTS { MATCH (g)<-[:BH67_R*1..]-(u:BH67Start {name:"A"}) } RETURN g.name AS name')) = json('[{"name":"D"}]');
INSERT INTO _assert SELECT 'full EXISTS explicit RETURN',
    json(cypher('MATCH (u:BH67Start) WHERE EXISTS { MATCH (u)-[:BH67_R*1..]->(g:BH67Target) RETURN g } RETURN u.name AS name')) = json('[{"name":"A"}]');
INSERT INTO _assert SELECT 'pattern EXISTS variable length endpoint properties',
    json(cypher('MATCH (u:BH67Start) WHERE EXISTS { (u)-[:BH67_R*1..]->(:BH67Target {name:"D"}) } RETURN u.name AS name')) = json('[{"name":"A"}]');
INSERT INTO _assert SELECT 'pattern EXISTS inner WHERE is enforced',
    json_array_length(cypher('MATCH (u:BH67Start) WHERE EXISTS { (u)-[:BH67_R*1..]->(g:BH67Target) WHERE g.name="missing" } RETURN u')) = 0;
INSERT INTO _assert SELECT 'legacy EXISTS variable length',
    json(cypher('MATCH (u:BH67Start) WHERE EXISTS((u)-[:BH67_R*1..]->(:BH67Target)) RETURN u.name AS name')) = json('[{"name":"A"}]');
INSERT INTO _assert SELECT 'EXISTS exact zero hops includes isolated node',
    json(cypher('MATCH (u:BH67Start) WHERE EXISTS { MATCH (u)-[:BH67_R*0..0]->(u) } RETURN u.name AS name ORDER BY name')) = json('[{"name":"A"},{"name":"Z"}]');

-- Repeated vertices are allowed, repeated relationships are not.
SELECT cypher('CREATE (a:BH67Cycle {name:"cycle"}), (b:BH67Cycle), (a)-[:BH67_C]->(b), (b)-[:BH67_C]->(a), (a)-[:BH67_LOOP]->(a)');
INSERT INTO _assert SELECT 'unbounded relationship-unique cycle terminates',
    json(cypher('MATCH p=(a:BH67Cycle {name:"cycle"})-[:BH67_C*1..]->(a) RETURN length(p) AS hops')) = json('[{"hops":2}]');
INSERT INTO _assert SELECT 'EXISTS permits repeated vertex on distinct edges',
    json(cypher('MATCH (a:BH67Cycle {name:"cycle"}) WHERE EXISTS((a)-[:BH67_C*2..]->(a)) RETURN a.name AS name')) = json('[{"name":"cycle"}]');
INSERT INTO _assert SELECT 'EXISTS cannot reuse a relationship',
    json_array_length(cypher('MATCH (a:BH67Cycle {name:"cycle"}) WHERE EXISTS { MATCH (a)-[:BH67_C*3..]->(a) } RETURN a')) = 0;
INSERT INTO _assert SELECT 'undirected self loop has one orientation',
    json(cypher('MATCH p=allShortestPaths((a:BH67Cycle {name:"cycle"})-[:BH67_LOOP*1..]-(a)) RETURN length(p) AS hops')) = json('[{"hops":1}]');

-- WHERE participates in shortest-path selection: filtering out one tie
-- must retain the other, and excluding all two-hop paths must find length 3.
SELECT cypher('CREATE (a:BH67Filter {name:"A"}), (b:BH67Filter {name:"B"}), (c:BH67Filter {name:"C"}), (d:BH67Filter {name:"D"}), (e:BH67Filter {name:"E"}), (f:BH67Filter {name:"F"}), (a)-[:BH67_F]->(b), (b)-[:BH67_F]->(d), (a)-[:BH67_F]->(c), (c)-[:BH67_F]->(d), (a)-[:BH67_F]->(e), (e)-[:BH67_F]->(f), (f)-[:BH67_F]->(d)');
INSERT INTO _assert SELECT 'shortest WHERE excludes first tied path',
    json(cypher('MATCH p=shortestPath((a:BH67Filter {name:"A"})-[:BH67_F*1..]->(d:BH67Filter {name:"D"})) WHERE ALL(n IN nodes(p) WHERE n.name <> "B") RETURN [n IN nodes(p) | n.name] AS names')) = json('[{"names":["A","C","D"]}]');
INSERT INTO _assert SELECT 'shortest WHERE excludes second tied path',
    json(cypher('MATCH p=shortestPath((a:BH67Filter {name:"A"})-[:BH67_F*1..]->(d:BH67Filter {name:"D"})) WHERE ALL(n IN nodes(p) WHERE n.name <> "C") RETURN [n IN nodes(p) | n.name] AS names')) = json('[{"names":["A","B","D"]}]');
INSERT INTO _assert SELECT 'allShortest WHERE keeps eligible tied path',
    json(cypher('MATCH p=allShortestPaths((a:BH67Filter {name:"A"})-[:BH67_F*1..]->(d:BH67Filter {name:"D"})) WHERE ALL(n IN nodes(p) WHERE n.name <> "B") RETURN [n IN nodes(p) | n.name] AS names')) = json('[{"names":["A","C","D"]}]');
INSERT INTO _assert SELECT 'shortest WHERE finds longer eligible path',
    json(cypher('MATCH p=shortestPath((a:BH67Filter {name:"A"})-[:BH67_F*1..]->(d:BH67Filter {name:"D"})) WHERE ALL(n IN nodes(p) WHERE n.name <> "B" AND n.name <> "C") RETURN [n IN nodes(p) | n.name] AS names')) = json('[{"names":["A","E","F","D"]}]');
INSERT INTO _assert SELECT 'allShortest WHERE finds longer eligible path',
    json(cypher('MATCH p=allShortestPaths((a:BH67Filter {name:"A"})-[:BH67_F*1..]->(d:BH67Filter {name:"D"})) WHERE a.name="A" AND ALL(n IN nodes(p) WHERE n.name <> "B" AND n.name <> "C") AND d.name="D" RETURN length(p) AS hops')) = json('[{"hops":3}]');
INSERT INTO _assert SELECT 'shortest WHERE rejecting every path gives no row',
    json_array_length(cypher('MATCH p=shortestPath((a:BH67Filter {name:"A"})-[:BH67_F*1..]->(d:BH67Filter {name:"D"})) WHERE ALL(n IN nodes(p) WHERE n.name <> "D") RETURN p')) = 0;

INSERT INTO _assert SELECT 'nested shortest EXISTS retains outer candidate scope',
    json(cypher('MATCH p=shortestPath((a:BH67Filter {name:"A"})-[:BH67_F*1..]->(d:BH67Filter {name:"D"})) WHERE ALL(n IN nodes(p) WHERE n.name <> "B") AND EXISTS { MATCH q=shortestPath((x:BH67Filter {name:"E"})-[:BH67_F*1..]->(d)) WHERE a.name="A" RETURN q } RETURN [n IN nodes(p) | n.name] AS names')) = json('[{"names":["A","C","D"]}]');
INSERT INTO _assert SELECT 'nested shortest EXISTS rejects wrong outer property',
    json_array_length(cypher('MATCH p=shortestPath((a:BH67Filter {name:"A"})-[:BH67_F*1..]->(d:BH67Filter {name:"D"})) WHERE EXISTS { MATCH q=shortestPath((x:BH67Filter {name:"E"})-[:BH67_F*1..]->(d)) WHERE a.name="E" RETURN q } RETURN p')) = 0;
SELECT cypher('MATCH (n:BH67Filter {name:"B"}) SET n.name="_gql_default_alias_0.id"');
INSERT INTO _assert SELECT 'candidate rebind preserves SQL-looking string literals',
    json(cypher('MATCH p=shortestPath((a:BH67Filter {name:"A"})-[:BH67_F*1..]->(d:BH67Filter {name:"D"})) WHERE ALL(n IN nodes(p) WHERE n.name <> "_gql_default_alias_0.id") RETURN [n IN nodes(p) | n.name] AS names')) = json('[{"names":["A","C","D"]}]');

-- A 101-edge chain catches the previous silent default upper bound of 100.
SELECT cypher('UNWIND range(0,101) AS i CREATE (:BH67Chain {i:i})');
SELECT cypher('MATCH (a:BH67Chain),(b:BH67Chain) WHERE b.i=a.i+1 CREATE (a)-[:BH67_NEXT]->(b)');
INSERT INTO _assert SELECT 'unbounded path reaches beyond 100 hops',
    json(cypher('MATCH p=(:BH67Chain {i:0})-[:BH67_NEXT*1..]->(:BH67Chain {i:101}) RETURN length(p) AS hops')) = json('[{"hops":101}]');
INSERT INTO _assert SELECT 'shortest path reaches beyond 100 hops',
    json(cypher('MATCH p=shortestPath((:BH67Chain {i:0})-[:BH67_NEXT*1..]->(:BH67Chain {i:101})) RETURN length(p) AS hops')) = json('[{"hops":101}]');
INSERT INTO _assert SELECT 'explicit hop bound still applies',
    json_array_length(cypher('MATCH p=(:BH67Chain {i:0})-[:BH67_NEXT*1..100]->(:BH67Chain {i:101}) RETURN p')) = 0;
INSERT INTO _assert SELECT 'full EXISTS reaches beyond 100 hops',
    json(cypher('MATCH (a:BH67Chain {i:0}) WHERE EXISTS { MATCH (a)-[:BH67_NEXT*1..]->(:BH67Chain {i:101}) } RETURN a.i AS i')) = json('[{"i":0}]');
INSERT INTO _assert SELECT 'pattern EXISTS reaches beyond 100 hops',
    json(cypher('MATCH (a:BH67Chain {i:0}) WHERE EXISTS((a)-[:BH67_NEXT*1..]->(:BH67Chain {i:101})) RETURN a.i AS i')) = json('[{"i":0}]');

SELECT name,ok FROM _assert;
