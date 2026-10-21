"""OPTIONAL clause atomicity and Protected Users regressions."""
FIXTURE = """
CREATE (a:GraphQLiteRegression:OptBase:OptUser:OptTier {objectid:'oa',enabled:true,sensitive:false}),
 (b:GraphQLiteRegression:OptBase:OptUser:OptTier {objectid:'ob',enabled:false,sensitive:false}),
 (mid:GraphQLiteRegression:OptBase:OptGroup {objectid:'mid'}),
 (live:GraphQLiteRegression:OptBase:OptGroup {objectid:'live-525'}),
 (live2:GraphQLiteRegression:OptBase:OptGroup {objectid:'live2-525'}),
 (empty:GraphQLiteRegression:OptBase:OptGroup {objectid:'empty-525'}),
 (other:GraphQLiteRegression:OptBase:OptGroup {objectid:'other'}),
 (a)-[:OptMember]->(mid), (mid)-[:OptMember]->(live),
 (a)-[:OptMember]->(live2), (b)-[:OptMember]->(other),
 (a)-[:Parallel]->(mid), (a)-[:Parallel]->(mid)
"""

def cases(Case):
    result=[]
    outer="MATCH (m:OptUser) WHERE m:OptTier "
    optional="OPTIONAL MATCH (g:OptGroup)<-[:OptMember*1..]-(n:OptBase) WHERE "
    project=" WITH m,COLLECT(n) AS matchingNs WHERE NONE(n IN matchingNs WHERE n.objectid=m.objectid) RETURN m.objectid AS id ORDER BY id"
    for name, predicate, expected in [
        ('empty Protected Users',"g.objectid='empty-525'",['oa','ob']),
        ('absent Protected Users',"g.objectid='missing-525'",['oa','ob']),
        ('present direct and transitive Protected Users',"g.objectid ENDS WITH '-525' AND g.objectid <> 'empty-525'",['ob']),
    ]:
        result.append(Case(name,outer+optional+predicate+project,[{'id':x} for x in expected],ordered=True))
    result.append(Case('delegable accounts with empty Protected Users',outer+"AND m.enabled=true AND m.sensitive=false "+optional+"g.objectid='empty-525'"+project,[{'id':'oa'}],ordered=True))
    result.append(Case('optional preserves empty collected list',outer+optional+"g.objectid='empty-525' WITH m,COLLECT(n) AS ns RETURN m.objectid AS id,ns,size(ns) AS size ORDER BY id",[{'id':'oa','ns':[],'size':0},{'id':'ob','ns':[],'size':0}],ordered=True))
    result.append(Case('optional has no synthetic outer users',outer+"AND m.objectid='missing' "+optional+"g.objectid='empty-525'"+project,[],ordered=True))
    result.append(Case('both fresh endpoints null together',outer+optional+"g.objectid='empty-525' RETURN m.objectid AS id,g.objectid AS g,n.objectid AS n ORDER BY id",[{'id':x,'g':None,'n':None} for x in ['oa','ob']],ordered=True))
    result.append(Case('fresh endpoint WHERE correlates outer identity',outer+optional+"g.objectid='live2-525' AND n.objectid=m.objectid RETURN m.objectid AS id,g.objectid AS g,n.objectid AS n ORDER BY id",[{'id':'oa','g':'live2-525','n':'oa'},{'id':'ob','g':None,'n':None}],ordered=True))
    result.append(Case('leading optional is one null row',"OPTIONAL MATCH (a:OptMissing)-[:OptMember*]->(b:OptBase) RETURN a,b",[{'a':None,'b':None}]))
    result.append(Case('WITH before optional retains outer identity',"MATCH(m:OptUser) WITH m "+optional+"g.objectid='empty-525'"+project,[{'id':'oa'},{'id':'ob'}],ordered=True))
    result.append(Case('optional rejects missing endpoint label',outer+"OPTIONAL MATCH (a:OptBase)-[:OptMember*]->(b:OptMissing) RETURN m.objectid AS id,a,b ORDER BY id",[{'id':x,'a':None,'b':None} for x in ['oa','ob']],ordered=True))
    result.append(Case('optional inline properties are atomic',outer+"OPTIONAL MATCH (a:OptBase {objectid:'oa'})-[:OptMember*]->(b:OptGroup {objectid:'missing'}) RETURN m.objectid AS id,a,b ORDER BY id",[{'id':x,'a':None,'b':None} for x in ['oa','ob']],ordered=True))
    anchor="MATCH (a:OptUser {objectid:'oa'}) "
    chain="OPTIONAL MATCH p=(a)-[rs:OptMember*1..1]->(b:OptBase)-[ss:OptMember*1..1]->(c:OptBase) "
    result.append(Case('chained optional rejects whole path',anchor+chain+"WHERE c.objectid='missing' RETURN a.objectid AS a,b,c,size(rs) AS rs,size(ss) AS ss,length(p) AS hops",[{'a':'oa','b':None,'c':None,'rs':None,'ss':None,'hops':None}]))
    result.append(Case('chained optional keeps only complete candidates',anchor+chain+"WHERE c.objectid='live-525' RETURN a.objectid AS a,b.objectid AS b,c.objectid AS c,length(p) AS hops",[{'a':'oa','b':'mid','c':'live-525','hops':2}]))
    result.append(Case('chained optional cross-endpoint OR',anchor+chain+"WHERE (b.objectid='mid' AND c.objectid='live-525') OR (b.objectid='live2-525' AND c.objectid='missing') RETURN b.objectid AS b,c.objectid AS c",[{'b':'mid','c':'live-525'}]))
    result.append(Case('chained optional preserves bound endpoints',"MATCH(a:OptUser {objectid:'oa'}),(c:OptGroup {objectid:'live-525'}) OPTIONAL MATCH (a)-[:OptMember*1..1]->(b:OptBase)-[:OptMember*1..1]->(c) WHERE b.objectid='missing' RETURN a.objectid AS a,b,c.objectid AS c",[{'a':'oa','b':None,'c':'live-525'}]))
    result.append(Case('comma patterns share one optional unit',anchor+"OPTIONAL MATCH (a)-[rs:OptMember*1..1]->(b),(a)-[ss:Missing*1..1]->(c) RETURN a.objectid AS a,b,c,size(rs) AS rs,size(ss) AS ss",[{'a':'oa','b':None,'c':None,'rs':None,'ss':None}]))
    result.append(Case('separate optional clauses keep earlier bindings',anchor+"OPTIONAL MATCH (a)-[rs:OptMember*1..1]->(b) OPTIONAL MATCH (a)-[ss:Missing*1..1]->(c) RETURN b.objectid AS b,c,size(rs) AS rs,size(ss) AS ss ORDER BY b",[{'b':'live2-525','c':None,'rs':1,'ss':None},{'b':'mid','c':None,'rs':1,'ss':None}],ordered=True))
    result.append(Case('optional keeps duplicate outer rows',"UNWIND [1,1] AS i OPTIONAL MATCH (a:OptMissing)-[:OptMember*]->(b) RETURN i,a,b",[{'i':1,'a':None,'b':None}]*2))
    result.append(Case('WITH-bound endpoint label failure is optional',anchor+"WITH a OPTIONAL MATCH (a:OptMissing)-[:OptMember*0..1]->(b) RETURN a.objectid AS a,b",[{'a':'oa','b':None}]))
    result.append(Case('optional zero-hop keeps same endpoint',anchor+"OPTIONAL MATCH p=(a)-[:Missing*0..0]->(b:OptUser) RETURN a.objectid AS a,b.objectid AS b,length(p) AS hops",[{'a':'oa','b':'oa','hops':0}]))
    result.append(Case('optional null anchor does not invent zero-hop',"OPTIONAL MATCH (a:OptMissing) WITH a OPTIONAL MATCH (a)-[:OptMember*0..1]->(b) RETURN a,b",[{'a':None,'b':None}]))
    result.append(Case('optional parallel paths retain multiplicity',anchor+"OPTIONAL MATCH (a)-[:Parallel*1..1]->(b) RETURN b.objectid AS b",[{'b':'mid'}]*2))
    result.append(Case('optional predicates ignore SQL-looking literal',outer+optional+"g.objectid='_gql_default_alias_1.id LEFT JOIN nodes ON 1=1'"+project,[{'id':'oa'},{'id':'ob'}],ordered=True))
    result.append(Case('optional segments cannot reuse one relationship',anchor+"OPTIONAL MATCH (a)-[:OptMember*1..1]->(b)<-[:OptMember*1..1]-(c) RETURN a.objectid AS a,b,c",[{'a':'oa','b':None,'c':None}]))
    result.append(Case('optional mixed segments cannot reuse one relationship',anchor+"OPTIONAL MATCH (a)-[:OptMember]->(b)<-[:OptMember*1..1]-(c) RETURN a.objectid AS a,b,c",[{'a':'oa','b':None,'c':None}]))
    result.append(Case('optional comma patterns cannot reuse one relationship',anchor+"OPTIONAL MATCH (a)-[:OptMember*1..1]->(b),(c)-[:OptMember*1..1]->(b) RETURN a.objectid AS a,b,c",[{'a':'oa','b':None,'c':None}]))
    result.append(Case('optional projected relationship lists have unique aliases',anchor+"MATCH(a)-[r:OptMember]->(b:OptGroup {objectid:'mid'}) MATCH(b)-[s:OptMember]->(c:OptGroup {objectid:'live-525'}) WITH a,b,c,[r] AS rs,[s] AS ss OPTIONAL MATCH (a)-[rs*]->(x),(b)-[ss*]->(y) RETURN x.objectid AS x,y.objectid AS y",[{'x':'mid','y':'live-525'}]))
    result.append(Case('failed optional returns a null path value',anchor+chain+"WHERE c.objectid='missing' RETURN p",[{'p':None}]))
    bound = "MATCH(a:OptUser {objectid:'oa'}),(b:OptGroup {objectid:'live-525'}) "
    result.append(Case('optional single table retains both bound endpoints',bound+"OPTIONAL MATCH p=(a)-[rs:OptMember*]->(b) RETURN a.objectid AS a,b.objectid AS b,length(p) AS hops,size(rs) AS size",[{'a':'oa','b':'live-525','hops':2,'size':2}]))
    result.append(Case('optional single table preserves missing path and endpoints',bound+"OPTIONAL MATCH p=(a)-[rs:Missing*]->(b) RETURN a.objectid AS a,b.objectid AS b,p,rs",[{'a':'oa','b':'live-525','p':None,'rs':None}]))
    result.append(Case('optional single table evaluates list predicate before null extension',bound+"OPTIONAL MATCH(a)-[rs:OptMember*]-(b) WHERE rs IS NULL AND a<>b RETURN a.objectid AS a,b.objectid AS b,rs",[{'a':'oa','b':'live-525','rs':None}]))
    return result
