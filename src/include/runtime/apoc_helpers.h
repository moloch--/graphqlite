#ifndef RUNTIME_APOC_HELPERS_H
#define RUNTIME_APOC_HELPERS_H
#include "graphqlite_sqlite.h"
void gql_apoc_to_json(sqlite3_context *, int, sqlite3_value **);
void gql_apoc_text_replace(sqlite3_context *, int, sqlite3_value **);
void gql_apoc_text_indexof(sqlite3_context *, int, sqlite3_value **);
#endif
