"""WITH must transport variable-length relationships as ordered entity lists."""


def cases(Case):
    pair = (
        "MATCH(a:OptUser {objectid:'oa'}) "
        "MATCH(a)-[rs:OptMember*1..1]->(b:OptGroup {objectid:'mid'}) "
        "MATCH(b)-[ss:OptMember*1..1]->(c:OptGroup {objectid:'live-525'}) "
    )
    result = []
    for name, projection in [('explicit', 'WITH a,b,c,rs,ss '), ('star', 'WITH * ')]:
        result.append(Case(
            'WITH ' + name + ' transports bound variable-length lists',
            pair + projection +
            'OPTIONAL MATCH(a)-[rs*]->(x),(b)-[ss*]->(y) '
            'RETURN x.objectid AS x,y.objectid AS y',
            [{'x': 'mid', 'y': 'live-525'}],
        ))
    path = (
        "MATCH p=(a:OptUser {objectid:'oa'})-[rs:OptMember*2..2]->"
        "(c:OptGroup {objectid:'live-525'}) "
    )
    result.append(Case(
        'WITH relationship list preserves ordered entities',
        path + 'WITH rs RETURN size(rs) AS size,[r IN rs | type(r)] AS kinds',
        [{'size': 2, 'kinds': ['OptMember', 'OptMember']}],
    ))
    result.append(Case(
        'WITH star retains named path and relationship list',
        path + 'WITH * RETURN length(p) AS hops,size(rs) AS size',
        [{'hops': 2, 'size': 2}],
    ))
    result.append(Case(
        'repeated WITH star retains list inner kind for UNWIND',
        path + 'WITH rs AS rels WITH * WITH rels UNWIND rels AS r '
        'RETURN type(r) AS kind,startNode(r).objectid AS source,endNode(r).objectid AS target ORDER BY source',
        [{'kind': 'OptMember', 'source': 'mid', 'target': 'live-525'}, {'kind': 'OptMember', 'source': 'oa', 'target': 'mid'}], ordered=True,
    ))
    result.append(Case(
        'WITH zero-hop relationship list remains empty',
        "MATCH(a:OptUser {objectid:'oa'}) MATCH(a)-[rs:Missing*0..0]->(b) "
        'WITH rs RETURN rs,size(rs) AS size',
        [{'rs': [], 'size': 0}],
    ))
    for name, projection in [('explicit', 'WITH rs '), ('star', 'WITH * ')]:
        result.append(Case(
            'WITH ' + name + ' optional relationship list remains null',
            "MATCH(a:OptUser {objectid:'oa'}) OPTIONAL MATCH(a)-[rs:Missing*1..1]->(b) "
            + projection + 'RETURN rs,size(rs) AS size',
            [{'rs': None, 'size': None}],
        ))
    result.append(Case(
        'WITH DISTINCT preserves relationship list values',
        path + 'WITH DISTINCT rs WITH rs AS rels RETURN size(rels) AS size',
        [{'size': 2}],
    ))
    result.append(Case(
        'WITH relationship list aggregation preserves grouping keys',
        path + 'WITH rs,count(*) AS count RETURN size(rs) AS size,count',
        [{'size': 2, 'count': 1}],
    ))
    result.append(Case(
        'WITH empty list can rebind a zero-hop path',
        "MATCH(a:OptUser {objectid:'oa'}) MATCH(a)-[rs:Missing*0..0]->(b) "
        'WITH a,rs OPTIONAL MATCH(a)-[rs*0..]->(x) RETURN x.objectid AS x,size(rs) AS size',
        [{'x': 'oa', 'size': 0}],
    ))
    result.append(Case(
        'WITH null list cannot rebind a zero-hop path',
        "MATCH(a:OptUser {objectid:'oa'}) OPTIONAL MATCH(a)-[rs:Missing*1..1]->(b) "
        'WITH a,rs OPTIONAL MATCH(a)-[rs*0..]->(x) RETURN x.objectid AS x,rs',
        [{'x': None, 'rs': None}],
    ))
    result.append(Case(
        'WITH list order follows traversal rather than relationship IDs',
        "MATCH(a:OptUser {objectid:'oa'})-[rs:Parallel|OptMember*2..2]->"
        "(c:OptGroup {objectid:'live-525'}) WITH rs "
        'RETURN [r IN rs | type(r)] AS kinds ORDER BY kinds',
        [{'kinds': ['OptMember', 'OptMember']}, {'kinds': ['Parallel', 'OptMember']}, {'kinds': ['Parallel', 'OptMember']}], ordered=True,
    ))
    return result
