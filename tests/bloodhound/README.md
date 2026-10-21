# BloodHound-style Cypher regression tests

These tests compare identical Cypher and parameters against the native
GraphQLite extension and an actual Neo4j instance. Both engines must match
explicit expected results, including duplicate counts, scalar types, and ordered
path contents. Unordered result rows are compared as multisets. For
`shortestPath`, tied path selection is unspecified, so unfiltered ties compare
endpoints, lengths and cardinality; `allShortestPaths` compares all path contents.
Filtered shortest paths also verify the surviving path contents, including a
longer path when every shorter candidate fails the predicate.

This suite tests the query engine. It does not import SharpHound data, implement
BloodHound's `AD_ATTACK_PATHS` application rewrite, reproduce its derived edges,
or establish full BloodHound compatibility. Relationship alternatives are
explicit in the queries. Fixtures are synthetic and contain positive, negative,
disconnected, tied-path, cyclic and deep-chain examples.

## Run

Use a **disposable empty Neo4j database**. The runner refuses nonempty databases
and cleans up only its `GraphQLiteRegression` fixture nodes. It does not need
APOC. An unavailable oracle is a failure, never a skipped parity check.

```sh
python -m pip install angreal==2.9.2 neo4j==5.28.2
docker run --rm -d --name graphqlite-oracle \
  -p 127.0.0.1:17687:7687 -e NEO4J_AUTH=none \
  neo4j@sha256:d6269a020149934597c8c3df926d080a612796dbbb48861ca9d5b1109cabf0d8

angreal build extension --release
angreal test bloodhound --neo4j-uri bolt://127.0.0.1:17687
docker stop graphqlite-oracle
```

Wait for Neo4j's startup to complete before running the test. For an authenticated
disposable instance, set `NEO4J_USER` and `NEO4J_PASSWORD`; credentials are not
written to reports. The pinned image is Neo4j 2026.09.0. `NEO4J_URI` can replace the URI argument. Set
`GQLITE_TEST_PYTHON` when the angreal runtime and test interpreter differ.

The report at `build/bloodhound-parity.json` records the extension hash, SQLite
and Neo4j versions, every query and parameter, expected results, actual results,
and errors. Expected regex failures must be language errors; connection errors
and timeouts fail the test. Setup and cleanup failures also fail the run and are
recorded in the report. There is a per-query timeout. To prove regression sensitivity,
use `--extension /path/to/old/graphqlite.so --output build/before.json`.

The 110-case suite covers shortest-path ties, all shortest paths, reversed paths,
path-node labels and variable shadowing, variable-length correlated `EXISTS`,
long unbounded traversal, retained explicit bounds, relationship uniqueness,
zero-hop paths, optional aggregation and paths, BloodHound password-age
expressions, negative epoch fractions and regex full-match semantics. Whole-clause
OPTIONAL regressions include chained and comma-separated patterns, correlated
predicates, empty membership groups, nullable paths, and relationship uniqueness.
WITH regressions preserve ordered relationship lists and their entity metadata
through explicit, wildcard, aliased, repeated, and aggregated projections.
