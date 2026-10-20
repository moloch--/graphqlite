---
title: Cirro compatibility
---

This fork extends GraphQLite 0.12.0 for Cirro's graph imports and postprocessing.
It accepts Cirro's existing Cypher templates without query rewriting. The
integration target is [Cirro v1.3.0](https://github.com/BishopFox/cirro/tree/cb298b7751a5c1e9afe9b413c6ac21c8a7c3c808).

The additions cover scoped `CALL (vars)`, `CALL (*)`, `CALL ()`, projected
imports (`CALL (row.id AS id)`), conditional update blocks
(`WHEN predicate THEN { ... }`), dynamic property assignment, and the
[APOC compatibility subset](/reference/apoc-compatibility/). Unit subqueries
preserve their outer row when a condition is false or an inner `UNWIND` is
empty. Returning subqueries preserve row multiplicity and entity identities.

The implementation also preserves boolean, list, map and string types across
SQLite scalar subqueries, projections and property assignment. JSON-looking
strings remain strings. These fixes are relevant to both Cirro and ordinary
GraphQLite queries.

The `set_typed_expression_values` capability covers evaluated `SET` maps and
list expressions that retain their value types. The `string_case_aliases`
capability covers `lower()` and `upper()` aliases for `toLower()` and
`toUpper()`. Both are advertised by `cypher_capabilities()`.

## Reproduce the checks

Use a separate Cirro checkout. Its templates are read at test time, not copied
into this MIT-licensed repository. The fixtures contain synthetic data.

```sh
python -m pip install angreal==2.9.2 PyYAML pytest
angreal build extension --release
angreal test unit
angreal test functional
angreal test tck-harness
angreal test tck
scripts/check-tck-baseline.sh
angreal test rust

# Use build/graphqlite.so on Linux, .dylib on macOS.
python tests/cirro/check.py --cirro-root ../cirro \
  --extension build/graphqlite.dylib --output build/cirro-extension.json
python tests/cirro/apoc_failures.py --extension build/graphqlite.dylib

# Repeat the same corpus through the public Rust binding with rusqlite 0.37
# and bundled SQLite 3.50.2, matching Cirro's dependency versions.
cargo build --locked --manifest-path tests/cirro/rust-runner/Cargo.toml \
  --target-dir build/cirro-rust
python tests/cirro/check.py --cirro-root ../cirro \
  --extension build/graphqlite.dylib \
  --rust-runner build/cirro-rust/debug/cirro-compat-runner \
  --output build/cirro-rust.json
```

The corpus validates all 142 templates and executes all 19 postprocessing
queries on empty graphs. Ten populated fixtures exercise users and groups,
conditional resources, nested networks, dynamic properties and relationships,
Tailscale, serialized settings, vault versions, deduplication with incident
edge properties, and rollback when a computed `SET` expression fails. Repeat
imports check idempotence. This is targeted query and binding coverage; it
does not run live cloud collection or every possible resource payload.

## Using the fork from Cirro

The [Cirro fork's optional GraphQLite backend](https://github.com/moloch--/cirro/blob/feat/graphqlite-backend/docs/usage/graphqlite.md)
uses this dependency while keeping Neo4j as its default backend. Its guide
covers the feature switch, native extension build, ingestion, and export.
The Rust crate can also be used from a Git revision with
`default-features = false`; load the locally built extension with
`Connection::open_with_extension`. The default
`bundled-extension` feature expects platform binaries under `bindings/rust/libs`;
building the source checkout alone does not publish those assets. `angreal test
rust` installs the current platform's extension there for local binding tests.

The supported APOC functions are deliberately bounded. In particular,
`apoc.periodic.iterate` executes sequentially and atomically within SQLite,
even when a template requests parallel execution. Java regular-expression
extensions and arbitrary APOC procedures are not implemented. See the subset
reference for accepted options and failure behavior. Cross-platform packaging,
including Windows and musl, needs its own verification before distributing a
Cirro build with this backend.
