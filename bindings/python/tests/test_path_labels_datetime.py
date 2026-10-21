"""Regression coverage for path entity labels and datetime epoch properties."""

import time

import pytest

from graphqlite import Graph
from test_graph import get_extension_path


@pytest.fixture
def g():
    with Graph(":memory:", extension_path=get_extension_path()) as graph:
        yield graph


@pytest.fixture
def path_graph(g):
    g.query(
        "CREATE (a:Base:User {name:'A'}), (b:Base:Group {name:'B'}), "
        "(c:Base:Group {name:'C'}), (:Unrelated), "
        "(a)-[:MemberOf]->(b), (b)-[:MemberOf]->(c)"
    )
    return g


PATH = "MATCH p=(a:User)-[:MemberOf*1..3]->(c:Group {name:'C'}) "


def test_labels_of_path_nodes_in_comprehension(path_graph):
    rows = list(path_graph.query(
        PATH + "RETURN [n IN nodes(p) | labels(n)] AS labels, "
        "[n IN nodes(p) | n:Base] AS base, "
        "[n IN nodes(p) | n:User] AS user"
    ))
    assert rows == [{
        "labels": [["Base", "User"], ["Base", "Group"], ["Base", "Group"]],
        "base": [True, True, True],
        "user": [True, False, False],
    }]


@pytest.mark.parametrize(
    "predicate, expected",
    [
        ("ALL(n IN nodes(p) WHERE n:Base)", 1),
        ("ALL(n IN nodes(p) WHERE 'Base' IN labels(n))", 1),
        ("ALL(n IN nodes(p) WHERE n:User OR n:Group)", 1),
        ("ALL(n IN nodes(p) WHERE n:Group)", 0),
        ("ANY(n IN nodes(p) WHERE n:User)", 1),
        ("NONE(n IN nodes(p) WHERE n:Missing)", 1),
        ("SINGLE(n IN nodes(p) WHERE n:User)", 1),
    ],
)
def test_path_label_quantifiers(path_graph, predicate, expected):
    assert list(path_graph.query(
        PATH + f"WHERE {predicate} RETURN count(p) AS count"
    )) == [{"count": expected}]


def test_projected_entity_labels_and_nulls(path_graph):
    rows = list(path_graph.query(
        "MATCH (a:User) WITH [a, null] AS values "
        "RETURN [n IN values | labels(n)] AS labels, "
        "[n IN values | n:Base] AS base"
    ))
    assert rows == [{"labels": [["Base", "User"], None], "base": [True, None]}]
    assert list(path_graph.query(
        "MATCH (n:User) WITH n RETURN labels(n) AS labels, n:Base AS base"
    )) == [{"labels": ["Base", "User"], "base": True}]
    assert list(path_graph.query(
        "OPTIONAL MATCH (n:Missing) RETURN labels(n) AS labels, n:Base AS base"
    )) == [{"labels": None, "base": None}]


def test_label_predicates_preserve_outer_node_scope(path_graph):
    assert list(path_graph.query(
        PATH + "WHERE ALL(a IN nodes(p) WHERE a:Base) "
        "RETURN labels(a) AS outerLabels, a:User AS outerUser, "
        "[a IN nodes(p) | [a IN [a] | a:Base]] AS nested"
    )) == [{
        "outerLabels": ["Base", "User"], "outerUser": True,
        "nested": [[True], [True], [True]],
    }]


def test_nested_quantifiers_preserve_node_scope(path_graph):
    assert list(path_graph.query(
        PATH + "WHERE ALL(n IN nodes(p) WHERE ANY(n IN [n] WHERE n:Base)) "
        "RETURN count(p) AS count"
    )) == [{"count": 1}]


def test_relationship_type_predicate_on_path_values(path_graph):
    assert list(path_graph.query(
        PATH + "RETURN [r IN relationships(p) | r:MemberOf] AS types, "
        "ALL(r IN relationships(p) WHERE r:MemberOf) AS allTypes"
    )) == [{"types": [True, True], "allTypes": True}]


def test_unlabelled_node_and_invalid_projected_value(g):
    g.query("CREATE (n)")
    assert list(g.query(
        "MATCH (n) WITH [n] AS xs RETURN [x IN xs | labels(x)] AS labels, "
        "[x IN xs | x:Missing] AS missing"
    )) == [{"labels": [[]], "missing": [False]}]
    with pytest.raises(Exception, match="labels\\(\\).*Node"):
        g.query("WITH [42] AS xs RETURN [x IN xs | labels(x)] AS labels")


@pytest.mark.parametrize(
    "constructor, seconds, millis",
    [
        ("datetime('1970-01-01T00:00:00Z')", 0, 0),
        ("datetime('1970-01-01T01:00:00+01:00')", 0, 0),
        ("datetime('1970-01-01T00:00:00-05:30')", 19800, 19800000),
        ("datetime('1969-12-31T23:59:59.999999999Z')", 0, -1),
        ("datetime('1969-12-31T23:59:59.000000001Z')", -1, -1000),
        ("datetime('1969-12-31T23:59:58.999999999Z')", -1, -1001),
        ("datetime('2000-01-01T00:00:00.123456789Z')", 946684800, 946684800123),
        ("datetime({year:2000, month:1, day:1, hour:1, minute:0, "
         "second:0, millisecond:123, timezone:'+01:00'})", 946684800, 946684800123),
    ],
)
def test_datetime_epoch_fields_direct_and_projected(g, constructor, seconds, millis):
    expected = [{"lower": seconds, "camel": seconds, "millis": millis}]
    assert list(g.query(
        f"RETURN {constructor}.epochseconds AS lower, "
        f"{constructor}.epochSeconds AS camel, {constructor}.epochMillis AS millis"
    )) == expected
    assert list(g.query(
        f"WITH {constructor} AS d RETURN d.epochseconds AS lower, "
        "d.epochSeconds AS camel, d.epochMillis AS millis"
    )) == expected


def test_datetime_epoch_null_and_current_time(g):
    assert list(g.query(
        "RETURN datetime(null).epochseconds AS seconds"
    )) == [{"seconds": None}]
    before = int(time.time())
    rows = list(g.query("RETURN datetime().epochseconds AS seconds"))
    after = int(time.time())
    assert before <= rows[0]["seconds"] <= after


def test_datetime_epoch_filter_preserves_integer_arithmetic(g):
    g.query("CREATE (:User {lastlogon:946684799}), (:User {lastlogon:946684800})")
    assert list(g.query(
        "MATCH (u:User) WHERE u.lastlogon < datetime('2000-01-01T00:00:00Z').epochseconds "
        "RETURN u.lastlogon AS value"
    )) == [{"value": 946684799}]
