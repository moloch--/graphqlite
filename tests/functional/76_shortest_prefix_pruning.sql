.load ./build/graphqlite
-- Shortest-prefix pruning must retain every shortest tie and finite cycles.
CREATE TEMP TABLE _shortest_assert(name TEXT, ok INTEGER CHECK(ok=1));
SELECT cypher('UNWIND range(0,29) AS i CREATE (:BHDense76 {i:i})');
SELECT cypher('MATCH (a:BHDense76),(b:BHDense76) WHERE a.i <> b.i CREATE (a)-[:BHDenseEdge76]->(b)');
INSERT INTO _shortest_assert SELECT 'dense directed all-pairs shortest paths',
    json(cypher('MATCH p=allShortestPaths((a:BHDense76)-[:BHDenseEdge76*1..]->(b:BHDense76)) WHERE a.i <> b.i RETURN count(p) AS n'))=json('[{"n":870}]');
INSERT INTO _shortest_assert SELECT 'dense cycle all shortest ties',
    json(cypher('MATCH p=allShortestPaths((a:BHDense76 {i:0})-[:BHDenseEdge76*1..]->(a)) RETURN length(p) AS hops,count(p) AS n'))=json('[{"hops":2,"n":29}]');
INSERT INTO _shortest_assert SELECT 'shortest cycle selects one',
    json(cypher('MATCH p=shortestPath((a:BHDense76 {i:0})-[:BHDenseEdge76*1..]->(a)) RETURN length(p) AS hops'))=json('[{"hops":2}]');
INSERT INTO _shortest_assert SELECT 'zero-hop remains zero',
    json(cypher('MATCH p=allShortestPaths((a:BHDense76 {i:0})-[:BHDenseEdge76*0..]->(a)) RETURN length(p) AS hops,count(p) AS n'))=json('[{"hops":0,"n":1}]');
INSERT INTO _shortest_assert SELECT 'minimum above one retains longer routes',
    json(cypher('MATCH p=allShortestPaths((a:BHDense76 {i:0})-[:BHDenseEdge76*2..2]->(b:BHDense76 {i:29})) RETURN length(p) AS hops,count(p) AS n'))=json('[{"hops":2,"n":28}]');
INSERT INTO _shortest_assert SELECT 'maximum bound excludes cycle',
    json_array_length(cypher('MATCH p=shortestPath((a:BHDense76 {i:0})-[:BHDenseEdge76*1..1]->(a)) RETURN p'))=0;
SELECT cypher('CREATE (a:BHTypes76 {name:"a"}),(b:BHTypes76 {name:"b"}),(c:BHTypes76 {name:"c"}), (a)-[:BHFirst76 {ok:true}]->(b),(b)-[:BHSecond76 {ok:true}]->(c),(a)-[:BHOther76 {ok:false}]->(c)');
INSERT INTO _shortest_assert SELECT 'type alternatives constrain distance',
    json(cypher('MATCH p=shortestPath((a:BHTypes76 {name:"a"})-[:BHFirst76|BHSecond76*1..]->(c:BHTypes76 {name:"c"})) RETURN length(p) AS hops'))=json('[{"hops":2}]');
INSERT INTO _shortest_assert SELECT 'reversed distance direction',
    json(cypher('MATCH p=shortestPath((c:BHTypes76 {name:"c"})<-[:BHFirst76|BHSecond76*1..]-(a:BHTypes76 {name:"a"})) RETURN length(p) AS hops'))=json('[{"hops":2}]');
INSERT INTO _shortest_assert SELECT 'wrong directed traversal stays unreachable',
    json_array_length(cypher('MATCH p=shortestPath((c:BHTypes76 {name:"c"})-[:BHFirst76|BHSecond76*1..]->(a:BHTypes76 {name:"a"})) RETURN p'))=0;
INSERT INTO _shortest_assert SELECT 'inline relationship filters retain full search',
    json(cypher('MATCH p=shortestPath((a:BHTypes76 {name:"a"})-[*1.. {ok:true}]->(c:BHTypes76 {name:"c"})) RETURN length(p) AS hops'))=json('[{"hops":2}]');
INSERT INTO _shortest_assert SELECT 'path filter retains longer route',
    json(cypher('MATCH p=shortestPath((a:BHTypes76 {name:"a"})-[*1..]->(c:BHTypes76 {name:"c"})) WHERE ALL(r IN relationships(p) WHERE r.ok=true) RETURN length(p) AS hops'))=json('[{"hops":2}]');
SELECT cypher('MATCH (a:BHTypes76 {name:"a"}),(c:BHTypes76 {name:"c"}) CREATE (a)-[:BHFirst76]->(c)');
INSERT INTO _shortest_assert SELECT 'distance cache does not survive a new statement',
    json(cypher('MATCH p=shortestPath((a:BHTypes76 {name:"a"})-[:BHFirst76|BHSecond76*1..]->(c:BHTypes76 {name:"c"})) RETURN length(p) AS hops'))=json('[{"hops":1}]');
SELECT cypher('MATCH (a:BHDense76 {i:0}) CREATE (a)-[:BHDenseEdge76]->(a)');
INSERT INTO _shortest_assert SELECT 'self loop beats positive cycle',
    json(cypher('MATCH p=shortestPath((a:BHDense76 {i:0})-[:BHDenseEdge76*1..]->(a)) RETURN length(p) AS hops'))=json('[{"hops":1}]');
SELECT cypher('CREATE (:BHMarker76 {name:"/*_gql_selector_begin__gql_default_alias_2*//*_gql_selector_end__gql_default_alias_2*/"})');
INSERT INTO _shortest_assert SELECT 'selector markers in property literals are preserved',
    json(cypher('MATCH p=shortestPath((a:BHDense76 {i:0})-[:BHDenseEdge76*1..]->(b:BHDense76 {i:1})),(x:BHMarker76 {name:"/*_gql_selector_begin__gql_default_alias_2*//*_gql_selector_end__gql_default_alias_2*/"}) RETURN length(p) AS hops'))=json('[{"hops":1}]');
SELECT name,ok FROM _shortest_assert;
