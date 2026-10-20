#ifndef EXECUTOR_APOC_H
#define EXECUTOR_APOC_H

#include "executor/cypher_executor.h"

/* args_json is a JSON array of evaluated arguments. Entity arguments retain
 * their internal id plus labels (nodes) or type/startNode/endNode (edges).
 * Populates caller-owned result, including typed yielded entities and stats.
 * Returns 0 on success, -1 on error. Only the documented APOC subset is accepted. */
int executor_apoc_call(cypher_executor *executor, const char *name, const char *args_json,
                       cypher_result *result);
bool executor_apoc_known(const char *name);

/* Implemented by query_dispatch.c. Execute one action against a materialized
 * producer row, preserving graph entity identity. Caller owns the result. */
cypher_result *executor_execute_imported(cypher_executor *executor, const char *query,
                                         const cypher_result *bindings, int row);

#endif
