-- WITH projections retain variable-length relationship list values and metadata.

.load ./build/graphqlite

CREATE TEMP TABLE _assert(name TEXT, ok INTEGER NOT NULL CHECK(ok=1));

SELECT cypher('
CREATE (a:GraphQLiteRegression:OptBase:OptUser:OptTier {objectid:''oa'',enabled:true,sensitive:false}),
 (b:GraphQLiteRegression:OptBase:OptUser:OptTier {objectid:''ob'',enabled:false,sensitive:false}),
 (mid:GraphQLiteRegression:OptBase:OptGroup {objectid:''mid''}),
 (live:GraphQLiteRegression:OptBase:OptGroup {objectid:''live-525''}),
 (live2:GraphQLiteRegression:OptBase:OptGroup {objectid:''live2-525''}),
 (empty:GraphQLiteRegression:OptBase:OptGroup {objectid:''empty-525''}),
 (other:GraphQLiteRegression:OptBase:OptGroup {objectid:''other''}),
 (a)-[:OptMember]->(mid), (mid)-[:OptMember]->(live),
 (a)-[:OptMember]->(live2), (b)-[:OptMember]->(other),
 (a)-[:Parallel]->(mid), (a)-[:Parallel]->(mid)
');

INSERT INTO _assert SELECT 'WITH explicit transports bound variable-length lists', json(cypher('MATCH(a:OptUser {objectid:''oa''}) MATCH(a)-[rs:OptMember*1..1]->(b:OptGroup {objectid:''mid''}) MATCH(b)-[ss:OptMember*1..1]->(c:OptGroup {objectid:''live-525''}) WITH a,b,c,rs,ss OPTIONAL MATCH(a)-[rs*]->(x),(b)-[ss*]->(y) RETURN x.objectid AS x,y.objectid AS y')) = json('[{"x":"mid","y":"live-525"}]');

INSERT INTO _assert SELECT 'WITH star transports bound variable-length lists', json(cypher('MATCH(a:OptUser {objectid:''oa''}) MATCH(a)-[rs:OptMember*1..1]->(b:OptGroup {objectid:''mid''}) MATCH(b)-[ss:OptMember*1..1]->(c:OptGroup {objectid:''live-525''}) WITH * OPTIONAL MATCH(a)-[rs*]->(x),(b)-[ss*]->(y) RETURN x.objectid AS x,y.objectid AS y')) = json('[{"x":"mid","y":"live-525"}]');

INSERT INTO _assert SELECT 'WITH relationship list preserves ordered entities', json(cypher('MATCH p=(a:OptUser {objectid:''oa''})-[rs:OptMember*2..2]->(c:OptGroup {objectid:''live-525''}) WITH rs RETURN size(rs) AS size,[r IN rs | type(r)] AS kinds')) = json('[{"size":2,"kinds":["OptMember","OptMember"]}]');

INSERT INTO _assert SELECT 'WITH star retains named path and relationship list', json(cypher('MATCH p=(a:OptUser {objectid:''oa''})-[rs:OptMember*2..2]->(c:OptGroup {objectid:''live-525''}) WITH * RETURN length(p) AS hops,size(rs) AS size')) = json('[{"hops":2,"size":2}]');

INSERT INTO _assert SELECT 'repeated WITH star retains list inner kind for UNWIND', json(cypher('MATCH p=(a:OptUser {objectid:''oa''})-[rs:OptMember*2..2]->(c:OptGroup {objectid:''live-525''}) WITH rs AS rels WITH * WITH rels UNWIND rels AS r RETURN type(r) AS kind,startNode(r).objectid AS source,endNode(r).objectid AS target ORDER BY source')) = json('[{"kind":"OptMember","source":"mid","target":"live-525"},{"kind":"OptMember","source":"oa","target":"mid"}]');

INSERT INTO _assert SELECT 'WITH zero-hop relationship list remains empty', json(cypher('MATCH(a:OptUser {objectid:''oa''}) MATCH(a)-[rs:Missing*0..0]->(b) WITH rs RETURN rs,size(rs) AS size')) = json('[{"rs":[],"size":0}]');

INSERT INTO _assert SELECT 'WITH explicit optional relationship list remains null', json(cypher('MATCH(a:OptUser {objectid:''oa''}) OPTIONAL MATCH(a)-[rs:Missing*1..1]->(b) WITH rs RETURN rs,size(rs) AS size')) = json('[{"rs":null,"size":null}]');

INSERT INTO _assert SELECT 'WITH star optional relationship list remains null', json(cypher('MATCH(a:OptUser {objectid:''oa''}) OPTIONAL MATCH(a)-[rs:Missing*1..1]->(b) WITH * RETURN rs,size(rs) AS size')) = json('[{"rs":null,"size":null}]');

INSERT INTO _assert SELECT 'WITH DISTINCT preserves relationship list values', json(cypher('MATCH p=(a:OptUser {objectid:''oa''})-[rs:OptMember*2..2]->(c:OptGroup {objectid:''live-525''}) WITH DISTINCT rs WITH rs AS rels RETURN size(rels) AS size')) = json('[{"size":2}]');

INSERT INTO _assert SELECT 'WITH relationship list aggregation preserves grouping keys', json(cypher('MATCH p=(a:OptUser {objectid:''oa''})-[rs:OptMember*2..2]->(c:OptGroup {objectid:''live-525''}) WITH rs,count(*) AS count RETURN size(rs) AS size,count')) = json('[{"size":2,"count":1}]');

INSERT INTO _assert SELECT 'WITH empty list can rebind a zero-hop path', json(cypher('MATCH(a:OptUser {objectid:''oa''}) MATCH(a)-[rs:Missing*0..0]->(b) WITH a,rs OPTIONAL MATCH(a)-[rs*0..]->(x) RETURN x.objectid AS x,size(rs) AS size')) = json('[{"x":"oa","size":0}]');

INSERT INTO _assert SELECT 'WITH null list cannot rebind a zero-hop path', json(cypher('MATCH(a:OptUser {objectid:''oa''}) OPTIONAL MATCH(a)-[rs:Missing*1..1]->(b) WITH a,rs OPTIONAL MATCH(a)-[rs*0..]->(x) RETURN x.objectid AS x,rs')) = json('[{"x":null,"rs":null}]');

INSERT INTO _assert SELECT 'WITH list order follows traversal rather than relationship IDs', json(cypher('MATCH(a:OptUser {objectid:''oa''})-[rs:Parallel|OptMember*2..2]->(c:OptGroup {objectid:''live-525''}) WITH rs RETURN [r IN rs | type(r)] AS kinds ORDER BY kinds')) = json('[{"kinds":["OptMember","OptMember"]},{"kinds":["Parallel","OptMember"]},{"kinds":["Parallel","OptMember"]}]');

SELECT count(*) AS passed FROM _assert;
