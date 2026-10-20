---
title: APOC compatibility subset
---

GraphQLite implements the following APOC names directly, for graph import and
post-processing workflows. Installing Neo4j or the APOC Java library is not
required. This is a defined subset, not support for arbitrary APOC procedures.
Unknown procedures and unsupported configuration keys fail explicitly.
The `cypher_capabilities()` response advertises the individual
`apoc_convert_tojson`, `apoc_text_replace_posix_regex`, `apoc_text_indexof`,
`apoc_refactor_mergenodes_subset`, `apoc_refactor_mergerelationships_subset`,
`apoc_merge_relationship` and `apoc_periodic_iterate_sequential_atomic` features.

| Name | Supported behavior |
| --- | --- |
| `apoc.convert.toJson(value)` | Serialize a value into a JSON **string**, retaining nulls, booleans, maps, lists and string escaping. |
| `apoc.text.replace(text, regex, replacement)` | Replace every match of a POSIX extended regular expression. Replacement strings support `$0` through `$9` capture references. Java-specific regular expression extensions are not supported. |
| `apoc.text.indexOf(text, search [, from [, to]])` | Find a substring at a zero-based character offset, or return `-1`; optional bounds restrict the search. |
| `apoc.merge.relationship(start, type, identity, onCreate, end [, onMatch]) YIELD rel` | Match directed endpoints, dynamic relationship type and identity properties. Create the relationship if absent; apply the corresponding create or match properties. Null identity values are rejected. |
| `apoc.refactor.mergeNodes(nodes [, config]) YIELD node` | Keep the first node, union labels, merge properties and redirect incoming and outgoing relationships. |
| `apoc.refactor.mergeRelationships(rels [, config]) YIELD rel` | Keep the first relationship and its type, merge properties and delete the others. All relationships must have identical directed endpoints. |
| `apoc.periodic.iterate(producer, action, config)` | Materialize producer rows, import each row into the action preserving node and relationship identities, then execute the actions sequentially. |

The refactoring procedures accept `properties: 'overwrite'`, `'discard'` or
`'combine'`, and node refactoring also accepts `mergeRels: true`. Combine
flattens arrays, retains the first occurrence of each typed value and returns a
scalar for a one-element result. Boolean and numeric values remain distinct.
With relationship merging enabled, parallel relationships sharing the same
type and directed endpoints are combined. Existing self-relationships of the
surviving node are preserved; redirected relationships may form new
self-relationships. An empty input list yields no rows.

`apoc.periodic.iterate` accepts `batchSize`, `parallel` and `params`. SQLite has
one writer, so `parallel: true` uses the same sequential execution as
`parallel: false`. The producer is materialized before mutation, and the entire
procedure runs in the enclosing query's transaction. A failed action rolls back
the procedure and raises an error. This deliberately differs from Neo4j's
independently committed batch transactions and partial-failure reporting.
`batchSize` determines the reported logical batch count; it does not introduce
intermediate commits. Actions execute once per producer row; `_batch` and
`batchMode` are not implemented.

The procedure exposes `batches`, `total`, `failedBatches`, `failedOperations`,
`committedOperations`, `wasTerminated` and `errorMessages` through `YIELD`.
Successful execution reports zero failures. GraphQLite's ordinary write
statistics additionally report node, relationship and property changes.
