#!/usr/bin/env python3
"""Compare identical BloodHound-style Cypher against GraphQLite and Neo4j.

Requires an EMPTY disposable Neo4j database. No external AD data is collected.
Each result must match both the oracle and an independent expected result.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import time

from neo4j import GraphDatabase, Query
from neo4j.exceptions import Neo4jError
if __package__:
    from .optional import FIXTURE as OPTIONAL_FIXTURE, cases as optional_cases
    from .with_varlen import cases as with_varlen_cases
else:
    from optional import FIXTURE as OPTIONAL_FIXTURE, cases as optional_cases
    from with_varlen import cases as with_varlen_cases


ROOT = Path(__file__).resolve().parents[2]
MARKER = "GraphQLiteRegression"
FIXTURE = """
CREATE
 (u:GraphQLiteRegression:Base:User {objectid:'alice',name:'ALICE@LAB.LOCAL',
     enabled:true,hasspn:true,pwdlastset:0}),
 (v:GraphQLiteRegression:Base:User {objectid:'bob',name:'BOB@LAB.LOCAL',
     enabled:false,hasspn:false,pwdlastset:1704164645}),
 (z:GraphQLiteRegression:Base:User {objectid:'isolated',name:'ISOLATED@LAB.LOCAL'}),
 (g:GraphQLiteRegression:Base:Group {objectid:'helpdesk',name:'HELPDESK@LAB.LOCAL'}),
 (g2:GraphQLiteRegression:Base:Group {objectid:'ops',name:'OPS@LAB.LOCAL'}),
 (da:GraphQLiteRegression:Base:Group:Tag_Tier_Zero
     {objectid:'S-1-5-21-100-512',name:'DOMAIN ADMINS@LAB.LOCAL',highvalue:true}),
 (c:GraphQLiteRegression:Base:Computer {objectid:'dc',name:'DC01.LAB.LOCAL'}),
 (u)-[:MemberOf]->(g), (u)-[:MemberOf]->(g2),
 (g)-[:MemberOf]->(da), (g2)-[:MemberOf]->(da),
 (g)-[:AdminTo]->(c), (c)-[:HasSession]->(u), (v)-[:GenericAll]->(da),
 (fa:GraphQLiteRegression:FilterNode {objectid:'fa'}),
 (fb:GraphQLiteRegression:FilterNode {objectid:'fb'}),
 (fc:GraphQLiteRegression:FilterNode {objectid:'fc'}),
 (fd:GraphQLiteRegression:FilterNode {objectid:'fd'}),
 (fe:GraphQLiteRegression:FilterNode {objectid:'fe'}),
 (ff:GraphQLiteRegression:FilterNode {objectid:'ff'}),
 (fa)-[:FilteredRoute]->(fb), (fb)-[:FilteredRoute]->(fd),
 (fa)-[:FilteredRoute]->(fc), (fc)-[:FilteredRoute]->(fd),
 (fa)-[:FilteredRoute]->(fe), (fe)-[:FilteredRoute]->(ff),
 (ff)-[:FilteredRoute]->(fd),
 (ca:GraphQLiteRegression:CycleNode {objectid:'ca'}),
 (cb:GraphQLiteRegression:CycleNode {objectid:'cb'}),
 (ca)-[:CycleRoute]->(cb), (cb)-[:CycleRoute]->(ca),
 (ca)-[:SelfLoop]->(ca)
"""
PATH = ("MATCH p=(u:User {objectid:'alice'})-[:MemberOf*1..]->"
        "(g:Group {objectid:'S-1-5-21-100-512'}) ")
CHAIN = ("MATCH p=(a:Chain {position:0})-[:Next*1..]->"
         "(b:Chain {position:101}) ")


@dataclass
class Case:
    name: str
    query: str
    expected: list[dict] = field(default_factory=list)
    params: dict = field(default_factory=dict)
    ordered: bool = False
    error: bool = False


def cases():
    result = [
        Case("keyword relationship alternatives",
             "MATCH (u:User)-[r:Contains|MemberOf|END]->(g:Group) "
             "RETURN u.objectid AS user,g.objectid AS group ORDER BY group",
             [{"user":"alice","group":"helpdesk"},{"user":"alice","group":"ops"}], ordered=True),
        Case("kerberoastable users",
             "MATCH (u:User) WHERE u.enabled=true AND u.hasspn=true "
             "RETURN u.objectid AS user", [{"user": "alice"}]),
        Case("membership paths preserve multiplicity", PATH +
             "RETURN u.objectid AS user,length(p) AS hops",
             [{"user": "alice", "hops": 2}] * 2),
        Case("one shortest path per endpoint pair",
             "MATCH p=shortestPath((u:User)-[:MemberOf|GenericAll*1..]->"
             "(g:Group {objectid:'S-1-5-21-100-512'})) "
             "RETURN u.objectid AS user,length(p) AS hops ORDER BY user",
             [{"user": "alice", "hops": 2}, {"user": "bob", "hops": 1}], ordered=True),
        Case("all tied shortest paths",
             "MATCH p=allShortestPaths((u:User {objectid:'alice'})-[:MemberOf*1..]->"
             "(g:Group {objectid:'S-1-5-21-100-512'})) "
             "RETURN [n IN nodes(p) | n.objectid] AS path",
             [{"path": ["alice", "helpdesk", "S-1-5-21-100-512"]},
              {"path": ["alice", "ops", "S-1-5-21-100-512"]}]),
        Case("reverse shortest traversal",
             "MATCH p=shortestPath((g:Group {objectid:'S-1-5-21-100-512'})"
             "<-[:MemberOf*1..]-(u:User {objectid:'alice'})) RETURN length(p) AS hops",
             [{"hops": 2}]),
        Case("path node label predicates", PATH +
             "WHERE ALL(n IN nodes(p) WHERE n:User OR n:Group) RETURN count(p) AS paths",
             [{"paths": 2}]),
        Case("path node labels function", PATH +
             "WHERE ALL(n IN nodes(p) WHERE 'Base' IN labels(n)) RETURN count(p) AS paths",
             [{"paths": 2}]),
        Case("path label negative filter", PATH +
             "WHERE ANY(n IN nodes(p) WHERE n:Computer) RETURN count(p) AS paths",
             [{"paths": 0}]),
        Case("quantifier restores outer binding", PATH +
             "WHERE ALL(u IN nodes(p) WHERE u:Base) "
             "RETURN DISTINCT u.objectid AS user,u:User AS isUser",
             [{"user": "alice", "isUser": True}]),
        Case("path list projection", PATH +
             "RETURN [n IN nodes(p) | 'Base' IN labels(n)] AS bases",
             [{"bases": [True, True, True]}] * 2),
        Case("relationship predicates", PATH +
             "WHERE NONE(r IN relationships(p) WHERE type(r)='GenericAll') "
             "RETURN count(p) AS paths", [{"paths": 2}]),
        Case("correlated variable-length EXISTS",
             "MATCH (u:User) WHERE EXISTS { MATCH (u)-[:MemberOf*1..]->(g:Group) "
             "WHERE g.highvalue=true } RETURN u.objectid AS user", [{"user": "alice"}]),
        Case("correlated variable-length NOT EXISTS",
             "MATCH (u:User) WHERE NOT EXISTS { MATCH (u)-[:MemberOf*1..]->"
             "(:Group {highvalue:true}) } RETURN u.objectid AS user ORDER BY user",
             [{"user": "bob"}, {"user": "isolated"}], ordered=True),
        Case("EXISTS respects inner filter",
             "MATCH (u:User) WHERE EXISTS { MATCH (u)-[:MemberOf*1..]->(g:Group) "
             "WHERE g.name='ABSENT' } RETURN u.objectid AS user", []),
        Case("EXISTS respects correlated source properties",
             "MATCH (u:User {objectid:'alice'}) WHERE EXISTS { "
             "MATCH (u {name:'ABSENT'})-[:MemberOf*1..]->(:Group) } "
             "RETURN u.objectid AS user", []),
        Case("EXISTS bounded lower limit",
             "MATCH (u:User) WHERE EXISTS { MATCH (u)-[:MemberOf*3..4]->"
             "(:Group {highvalue:true}) } RETURN u.objectid AS user", []),
        Case("one-hop EXISTS remains valid",
             "MATCH (u:User) WHERE EXISTS { MATCH (u)-[:MemberOf]->(:Group) } "
             "RETURN u.objectid AS user", [{"user": "alice"}]),
        Case("unbounded path exceeds 100 hops", CHAIN +
             "RETURN length(p) AS hops", [{"hops": 101}]),
        Case("unbounded shortest exceeds 100 hops",
             "MATCH p=shortestPath((a:Chain {position:0})-[:Next*]->"
             "(b:Chain {position:101})) RETURN length(p) AS hops", [{"hops": 101}]),
        Case("explicit path bound retained",
             "MATCH p=(a:Chain {position:0})-[:Next*1..100]->"
             "(b:Chain {position:101}) RETURN length(p) AS hops", []),
        Case("long EXISTS",
             "MATCH (a:Chain {position:0}) WHERE EXISTS { MATCH (a)-[:Next*]->"
             "(:Chain {position:101}) } RETURN a.position AS start", [{"start": 0}]),
        Case("long pattern predicate",
             "MATCH (a:Chain {position:0}) WHERE (a)-[:Next*]->(:Chain {position:101}) "
             "RETURN a.position AS start", [{"start": 0}]),
        Case("zero-hop EXISTS includes isolated node",
             "MATCH (u:User) WHERE EXISTS { MATCH (u)-[:MemberOf*0..0]->(u) } "
             "RETURN u.objectid AS user ORDER BY user",
             [{"user": "alice"}, {"user": "bob"}, {"user": "isolated"}], ordered=True),
        Case("unbounded cycle permits repeated node",
             "MATCH p=(a:CycleNode {objectid:'ca'})-[:CycleRoute*1..]->(a) "
             "RETURN length(p) AS hops", [{"hops": 2}]),
        Case("cycle EXISTS cannot reuse relationship",
             "MATCH (a:CycleNode {objectid:'ca'}) WHERE EXISTS { "
             "MATCH (a)-[:CycleRoute*3..]->(a) } RETURN a.objectid AS node", []),
        Case("undirected self-loop emitted once",
             "MATCH p=(a:CycleNode {objectid:'ca'})-[:SelfLoop*1..]-(a) "
             "RETURN length(p) AS hops", [{"hops": 1}]),
        Case("optional match null and aggregation",
             "MATCH (u:User) OPTIONAL MATCH (u)-[:MemberOf]->(g:Group) "
             "RETURN u.objectid AS user,count(g) AS groups ORDER BY user",
             [{"user": "alice", "groups": 2}, {"user": "bob", "groups": 0},
              {"user": "isolated", "groups": 0}], ordered=True),
        Case("optional shortest preserves missing endpoint",
             "MATCH (u:User) WITH u,u.objectid AS user "
             "OPTIONAL MATCH p=shortestPath((u)-[:MemberOf*1..]->"
             "(g:Group {objectid:'S-1-5-21-100-512'})) "
             "RETURN user,length(p) AS hops ORDER BY user",
             [{"user": "alice", "hops": 2}, {"user": "bob", "hops": None},
              {"user": "isolated", "hops": None}], ordered=True),
        Case("optional all shortest preserves missing endpoint",
             "MATCH (u:User) WITH u,u.objectid AS user "
             "OPTIONAL MATCH p=allShortestPaths((u)-[:MemberOf*1..]->"
             "(g:Group {objectid:'S-1-5-21-100-512'})) "
             "RETURN user,length(p) AS hops ORDER BY user",
             [{"user": "alice", "hops": 2}] * 2 + [{"user": "bob", "hops": None},
              {"user": "isolated", "hops": None}], ordered=True),
        Case("password-age predicate",
             "MATCH (u:User) WHERE u.pwdlastset < "
             "(datetime('2024-01-02T03:04:05Z').epochseconds - 365*86400) "
             "RETURN u.objectid AS user", [{"user": "alice"}]),
        Case("nested shortest EXISTS preserves outer endpoint scope",
             "MATCH p=shortestPath((a:FilterNode {objectid:'fa'})-[:FilteredRoute*1..]->"
             "(b:FilterNode {objectid:'fd'})) "
             "WHERE ALL(n IN nodes(p) WHERE NOT n.objectid IN ['fb','fc']) "
             "AND EXISTS { MATCH q=shortestPath((e:FilterNode {objectid:'fe'})"
             "-[:FilteredRoute*1..]->(b)) WHERE a.objectid='fa' AND length(q)=2 } "
             "RETURN [n IN nodes(p) | n.objectid] AS path",
             [{"path": ["fa", "fe", "ff", "fd"]}]),
    ]
    for function in ("shortestPath", "allShortestPaths"):
        for excluded, path in [
            (["fb"], ["fa", "fc", "fd"]),
            (["fc"], ["fa", "fb", "fd"]),
            (["fb", "fc"], ["fa", "fe", "ff", "fd"]),
        ]:
            result.append(Case(f"{function} filters candidates excluding {excluded}",
                               f"MATCH p={function}((a:FilterNode {{objectid:'fa'}})"
                               "-[:FilteredRoute*1..]->(b:FilterNode {objectid:'fd'})) "
                               "WHERE ALL(n IN nodes(p) WHERE NOT n.objectid IN $excluded) "
                               "RETURN [n IN nodes(p) | n.objectid] AS path",
                               [{"path": path}], {"excluded": excluded}))
    # Test both spellings used by Neo4j and BloodHound, including offset inputs.
    for text, expected in [
        ("1970-01-01T00:00:00Z", 0),
        ("2024-01-02T03:04:05Z", 1704164645),
        ("2024-01-02T05:04:05+02:00", 1704164645),
        ("1969-12-31T23:59:59.500Z", 0),
        ("1969-12-31T23:59:59.000000001Z", -1),
    ]:
        for prop in ("epochseconds", "epochSeconds"):
            result.append(Case(f"datetime {text} {prop}",
                               f"RETURN datetime($instant).{prop} AS seconds",
                               [{"seconds": expected}], {"instant": text}))
    result.append(Case("current datetime epoch",
                       "RETURN datetime().epochseconds >= $before AND "
                       "datetime().epochseconds <= $after AS valid",
                       [{"valid": True}],
                       {"before": int(time.time()) - 60, "after": int(time.time()) + 600}))
    for name, value, pattern, expected in [
        ("full string rejects substring", "DOMAIN ADMINS@LAB.LOCAL", "DOMAIN ADMINS", False),
        ("full string accepts wildcard", "DOMAIN ADMINS@LAB.LOCAL", ".*DOMAIN ADMINS.*", True),
        ("alternatives backtrack to whole input", "ab", "a|ab", True),
        ("case insensitive flag", "Alice", "(?i)alice", True),
        ("lookahead", "ALICE@LAB.LOCAL", "(?=.*@LAB).*", True),
        ("lookahead negative", "ALICE@OTHER", "(?=.*@LAB).*", False),
        ("negative lookahead", "BOB", "(?!ALICE).*", True),
        ("Java digit class", "user12", r"user\d+", True),
        ("named backreference", "alice-alice", r"(?<who>\w+)-\k<who>", True),
        ("dot excludes newline", "a\nb", ".*", False),
        ("dotall flag", "a\nb", "(?s).*", True),
        ("Unicode literal", "café", "café", True),
        ("empty pattern", "", "", True),
        ("null value", None, ".*", None),
        ("null pattern", "Alice", None, None),
    ]:
        result.append(Case(f"regex {name}", "RETURN $value =~ $pattern AS matched",
                           [{"matched": expected}], {"value": value, "pattern": pattern}))
    result.append(Case("regex invalid pattern", "RETURN 'a' =~ '[' AS matched", error=True))
    result.extend(optional_cases(Case))
    result.extend(with_varlen_cases(Case))
    return result


def encoded(value):
    # JSON distinguishes booleans, numbers, nulls and strings; sort object keys
    # only. Preserve duplicate rows and all path/list ordering.
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def comparable(rows, ordered):
    values = [encoded(row) for row in rows]
    return values if ordered else sorted(values)


def regex_error(error, backend):
    """Infrastructure failures must never satisfy an expected syntax error."""
    message = str(error).lower()
    if backend == "neo4j":
        return (isinstance(error, Neo4jError)
                and error.code in ("Neo.ClientError.Statement.SemanticError",
                                   "Neo.ClientError.Statement.SyntaxError")
                and "invalid regex" in message)
    return (isinstance(error, (sqlite3.OperationalError, RuntimeError))
            and "invalid regex at byte" in message)


class Extension:
    def __init__(self, path, timeout):
        self.db = sqlite3.connect(":memory:")
        self.db.enable_load_extension(True)
        self.db.load_extension(str(path))
        self.db.enable_load_extension(False)
        self.timeout = timeout

    def query(self, cypher, params=None):
        deadline = time.monotonic() + self.timeout
        self.db.set_progress_handler(lambda: time.monotonic() > deadline, 1000)
        value = json.loads(self.db.execute("SELECT cypher(?,?)",
                                          (cypher, encoded(params or {}))).fetchone()[0])
        if isinstance(value, dict) and "error" in value:
            raise RuntimeError(value["error"])
        return value

    def close(self):
        self.db.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extension", required=True, type=Path)
    parser.add_argument("--neo4j-uri", default=os.environ.get("NEO4J_URI", "bolt://127.0.0.1:7687"))
    parser.add_argument("--database", default="neo4j")
    parser.add_argument("--output", type=Path, default=ROOT / "build/bloodhound-parity.json")
    parser.add_argument("--timeout", type=float, default=15)
    args = parser.parse_args()
    password = os.environ.get("NEO4J_PASSWORD")
    auth = (os.environ.get("NEO4J_USER", "neo4j"), password) if password else None
    report = {
        "scope": "Synthetic BloodHound-style query regression; no AD ingestion or BloodHound application parity",
        "extension_sha256": hashlib.sha256(args.extension.read_bytes()).hexdigest(),
        "sqlite_version": sqlite3.sqlite_version,
        "passed": False, "cases": [],
    }
    extension = None
    try:
        extension = Extension(args.extension.resolve(), args.timeout)
        with GraphDatabase.driver(args.neo4j_uri, auth=auth, connection_timeout=args.timeout) as driver:
            with driver.session(database=args.database) as session:
                def oracle(query, params=None):
                    return session.run(Query(query, timeout=args.timeout), params or {}).data()

                if oracle("MATCH (n) RETURN count(n) AS count") != [{"count": 0}]:
                    raise RuntimeError("Refusing to modify a nonempty Neo4j database; use a disposable empty instance")
                report["neo4j"] = oracle("CALL dbms.components() YIELD name,versions RETURN name,versions")
                try:
                    for query, params in [
                        (FIXTURE, {}),
                        (OPTIONAL_FIXTURE, {}),
                        ("UNWIND $nodes AS row CREATE (:GraphQLiteRegression:Chain {position:row})",
                         {"nodes": list(range(102))}),
                        ("MATCH (a:Chain),(b:Chain) WHERE b.position=a.position+1 "
                         "CREATE (a)-[:Next]->(b)", {}),
                    ]:
                        extension.query(query, params)
                        oracle(query, params)
                    for case in cases():
                        entry = {"name": case.name, "query": case.query, "params": case.params,
                                 "ordered": case.ordered, "expects_error": case.error,
                                 "expected": case.expected}
                        for name, execute in (("graphqlite", extension.query), ("neo4j", oracle)):
                            try:
                                entry[name] = execute(case.query, case.params)
                            except Exception as error:
                                entry[name + "_error"] = str(error)
                                entry[name + "_regex_error"] = regex_error(error, name)
                        if case.error:
                            passed = all(entry.get(name + "_regex_error", False)
                                         for name in ("graphqlite", "neo4j"))
                        else:
                            expected = comparable(case.expected, case.ordered)
                            passed = all(name in entry and comparable(entry[name], case.ordered) == expected
                                         for name in ("graphqlite", "neo4j"))
                        entry["passed"] = passed
                        report["cases"].append(entry)
                        print(f"{'PASS' if passed else 'FAIL'} {case.name}", flush=True)
                finally:
                    # Only the fixtures created by this runner carry this label.
                    oracle(f"MATCH (n:{MARKER}) DETACH DELETE n")
                report["passed"] = bool(report["cases"]) and all(
                    case["passed"] for case in report["cases"])
    except Exception as error:
        report["passed"] = False
        report["infrastructure_error"] = str(error)
        raise
    finally:
        if extension:
            extension.close()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    passed = sum(case["passed"] for case in report["cases"])
    print(f"{passed}/{len(report['cases'])} cases passed; report: {args.output}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
