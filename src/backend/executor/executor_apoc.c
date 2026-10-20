/* Native implementation of the APOC subset used by Cirro. The public
 * procedure boundary receives evaluated values, never Cypher source snippets
 * substituted with string interpolation. All graph mutations are atomic. */
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "executor/executor_apoc.h"
#include "executor/executor_internal.h"
#include "runtime/gql_error.h"

static int fail(cypher_result *r, const char *message)
{
    set_result_error(r, message);
    return -1;
}

static char *field(sqlite3 *db, const char *json, const char *path, const char *want)
{
    sqlite3_stmt *st = NULL;
    char *out = NULL;
    if (sqlite3_prepare_v2(db, "SELECT json_extract(?1,?2),json_type(?1,?2)", -1, &st, NULL) !=
        SQLITE_OK)
        return NULL;
    sqlite3_bind_text(st, 1, json, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, path, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_type(st, 0) != SQLITE_NULL) {
        const char *type = (const char *)sqlite3_column_text(st, 1);
        if (!want || (type && !strcmp(type, want)))
            out = strdup((const char *)sqlite3_column_text(st, 0));
    }
    sqlite3_finalize(st);
    return out;
}

static bool has_type(sqlite3 *db, const char *json, const char *path, const char *types)
{
    sqlite3_stmt *st = NULL;
    bool ok = false;
    if (sqlite3_prepare_v2(db, "SELECT instr(?3,','||coalesce(json_type(?1,?2),'missing')||',')>0",
                           -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, json, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, path, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 3, types, -1, SQLITE_TRANSIENT);
        ok = sqlite3_step(st) == SQLITE_ROW && sqlite3_column_int(st, 0);
    }
    sqlite3_finalize(st);
    return ok;
}

static int argument_count(sqlite3 *db, const char *args)
{
    sqlite3_stmt *st = NULL;
    int n = -1;
    if (sqlite3_prepare_v2(db, "SELECT json_array_length(?1)", -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, args, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(st) == SQLITE_ROW)
            n = sqlite3_column_int(st, 0);
    }
    sqlite3_finalize(st);
    return n;
}

static int exec_ids(sqlite3 *db, const char *sql, int a, int b)
{
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK)
        return -1;
    sqlite3_bind_int(st, 1, a);
    sqlite3_bind_int(st, 2, b);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    return rc == SQLITE_DONE ? 0 : -1;
}

static int entity_id(sqlite3 *db, const char *json, bool edge)
{
    sqlite3_stmt *st = NULL;
    int id = -1;
    const char *sql = edge ? "SELECT id FROM edges WHERE id=json_extract(?1,'$.id') AND "
                             "json_type(?1,'$.id')='integer' AND json_type(?1,'$.type')='text'"
                           : "SELECT id FROM nodes WHERE id=json_extract(?1,'$.id') AND "
                             "json_type(?1,'$.id')='integer' AND json_type(?1,'$.labels')='array'";
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK)
        return -1;
    sqlite3_bind_text(st, 1, json, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW) {
        sqlite3_int64 x = sqlite3_column_int64(st, 0);
        if (x > 0 && x <= INT_MAX)
            id = (int)x;
    }
    sqlite3_finalize(st);
    return id;
}

/* Each encoded value retains its type: true is different from 1, and a
 * string containing JSON remains a string. Caller frees the JSON object. */
static char *properties(sqlite3 *db, int id, bool edge)
{
    const char *kind = edge ? "edge" : "node", *idcol = edge ? "edge_id" : "node_id";
    char *sql =
        sqlite3_mprintf("SELECT coalesce(json_group_object(k.key,json(p.v)),'{}') FROM ("
                        "SELECT key_id,json_quote(value) v FROM %s_props_int WHERE %s=?1 UNION ALL "
                        "SELECT key_id,json_quote(value) FROM %s_props_real WHERE %s=?1 UNION ALL "
                        "SELECT key_id,json_quote(value) FROM %s_props_text WHERE %s=?1 UNION ALL "
                        "SELECT key_id,CASE value WHEN 1 THEN 'true' ELSE 'false' END FROM "
                        "%s_props_bool WHERE %s=?1 UNION ALL "
                        "SELECT key_id,value FROM %s_props_json WHERE %s=?1) p JOIN property_keys "
                        "k ON k.id=p.key_id",
                        kind, idcol, kind, idcol, kind, idcol, kind, idcol, kind, idcol);
    if (!sql)
        return NULL;
    sqlite3_stmt *st = NULL;
    char *out = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int(st, 1, id);
        if (sqlite3_step(st) == SQLITE_ROW)
            out = strdup((const char *)sqlite3_column_text(st, 0));
    }
    sqlite3_finalize(st);
    sqlite3_free(sql);
    return out;
}

/* A property as encoded JSON, or NULL when absent. */
static char *property_json(sqlite3 *db, const char *props, const char *key)
{
    sqlite3_stmt *st = NULL;
    char *out = NULL;
    if (sqlite3_prepare_v2(db,
                           "SELECT CASE type WHEN 'true' THEN 'true' WHEN 'false' THEN 'false' "
                           "WHEN 'array' THEN value WHEN 'object' THEN value ELSE "
                           "json_quote(value) END FROM json_each(?1) WHERE key=?2",
                           -1, &st, NULL) != SQLITE_OK)
        return NULL;
    sqlite3_bind_text(st, 1, props, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, key, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW)
        out = strdup((const char *)sqlite3_column_text(st, 0));
    sqlite3_finalize(st);
    return out;
}

/* APOC combine: flatten existing arrays, keep first occurrence of each typed
 * value, and keep a scalar when the combined set has only one member. */
static char *combine(sqlite3 *db, const char *a, const char *b)
{
    const char *sql =
        "WITH input(v,ord) AS (VALUES(?1,0),(?2,1)), elems AS ("
        "SELECT j.type,j.value, i.ord,j.key FROM input i,json_each(CASE WHEN "
        "json_type(i.v)='array' THEN i.v ELSE json_array(json(i.v)) END) j), "
        "unique_values AS (SELECT type,value,min(ord*1000000000+key) pos FROM elems GROUP BY "
        "type,value), "
        "encoded AS (SELECT CASE type WHEN 'true' THEN 'true' WHEN 'false' THEN 'false' WHEN "
        "'array' THEN value WHEN 'object' THEN value ELSE json_quote(value) END v FROM "
        "unique_values ORDER BY pos) "
        "SELECT CASE count(*) WHEN 1 THEN min(v) ELSE json_group_array(json(v)) END FROM encoded";
    sqlite3_stmt *st = NULL;
    char *out = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK)
        return NULL;
    sqlite3_bind_text(st, 1, a, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, b, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_text(st, 0))
        out = strdup((const char *)sqlite3_column_text(st, 0));
    sqlite3_finalize(st);
    return out;
}

/* Schema delete-one helpers report absence as -1 and delete-all helpers
 * suppress statement errors. Refactoring needs checked, idempotent cleanup. */
static int delete_properties(cypher_executor *ex, int id, bool edge, const char *key)
{
    static const char *types[] = {"int", "real", "text", "bool", "json"};
    for (int i = 0; i < 5; i++) {
        char sql[200];
        snprintf(sql, sizeof(sql), "DELETE FROM %s_props_%s WHERE %s_id=?1%s",
                 edge ? "edge" : "node", types[i], edge ? "edge" : "node",
                 key ? " AND key_id=(SELECT id FROM property_keys WHERE key=?2)" : "");
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(ex->db, sql, -1, &st, NULL) != SQLITE_OK)
            return -1;
        sqlite3_bind_int(st, 1, id);
        if (key)
            sqlite3_bind_text(st, 2, key, -1, SQLITE_TRANSIENT);
        int rc = sqlite3_step(st);
        sqlite3_finalize(st);
        if (rc != SQLITE_DONE)
            return -1;
    }
    return 0;
}

static int set_property(cypher_executor *ex, int id, bool edge, const char *key,
                        const char *encoded, cypher_result *r)
{
    char *map = sqlite3_mprintf("{\"v\":%s}", encoded);
    if (!map)
        return -1;
    property_type type;
    property_value value;
    property_value_init(&value);
    int rc = json_map_property(ex->db, map, "v", &type, &value);
    sqlite3_free(map);
    /* Edge setters do not remove a value from the previous typed table. */
    if (edge && delete_properties(ex, id, true, key) < 0)
        rc = -1;
    if (rc == -2) {
        rc = edge ? 0 : delete_properties(ex, id, false, key);
    } else if (rc == 0) {
        rc = edge ? cypher_schema_set_edge_property(ex->schema_mgr, id, key, type,
                                                    property_value_ptr(type, &value))
                  : cypher_schema_set_node_property(ex->schema_mgr, id, key, type,
                                                    property_value_ptr(type, &value));
    }
    property_value_free(&value);
    if (rc == 0)
        r->properties_set++;
    return rc;
}

static int apply_properties(cypher_executor *ex, int id, bool edge, const char *incoming,
                            const char *mode, cypher_result *r)
{
    char *current = properties(ex->db, id, edge);
    if (!current)
        return -1;
    sqlite3_stmt *st = NULL;
    int rc = -1;
    if (sqlite3_prepare_v2(ex->db, "SELECT key FROM json_each(?1)", -1, &st, NULL) != SQLITE_OK)
        goto done;
    sqlite3_bind_text(st, 1, incoming, -1, SQLITE_TRANSIENT);
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        const char *key = (const char *)sqlite3_column_text(st, 0);
        char *old = property_json(ex->db, current, key),
             *value = property_json(ex->db, incoming, key);
        if (!value) {
            free(old);
            rc = SQLITE_ERROR;
            break;
        }
        if (old && !strcmp(mode, "discard")) {
            free(old);
            free(value);
            continue;
        }
        if (old && !strcmp(mode, "combine")) {
            char *combined = combine(ex->db, old, value);
            free(value);
            value = combined;
        }
        free(old);
        if (!value || set_property(ex, id, edge, key, value, r) < 0) {
            free(value);
            rc = SQLITE_ERROR;
            break;
        }
        free(value);
    }
    rc = rc == SQLITE_DONE ? 0 : -1;
done:
    sqlite3_finalize(st);
    free(current);
    return rc;
}

static int output_entity(cypher_executor *ex, int id, bool edge, cypher_result *r)
{
    agtype_value *value = NULL;
    if (edge) {
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(ex->db, "SELECT type,source_id,target_id FROM edges WHERE id=?1", -1,
                               &st, NULL) != SQLITE_OK)
            return -1;
        sqlite3_bind_int(st, 1, id);
        if (sqlite3_step(st) == SQLITE_ROW)
            value = agtype_value_create_edge_with_properties(
                ex->db, id, (const char *)sqlite3_column_text(st, 0), sqlite3_column_int(st, 1),
                sqlite3_column_int(st, 2));
        sqlite3_finalize(st);
    } else
        value = agtype_value_create_vertex_with_properties(ex->db, id, NULL);
    if (!value)
        return -1;
    char *rendered = agtype_value_to_string(value);
    agtype_value_free(value);
    if (!rendered)
        return -1;
    /* Row bindings recognize canonical entity JSON; the agtype renderer is
     * deliberately pretty-spaced, so normalize before crossing this API. */
    sqlite3_stmt *compact = NULL;
    char *json = NULL;
    if (sqlite3_prepare_v2(ex->db, "SELECT json(?1)", -1, &compact, NULL) == SQLITE_OK) {
        sqlite3_bind_text(compact, 1, rendered, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(compact) == SQLITE_ROW)
            json = strdup((const char *)sqlite3_column_text(compact, 0));
    }
    sqlite3_finalize(compact);
    free(rendered);
    if (!json)
        return -1;
    r->column_count = 1;
    r->row_count = 1;
    r->column_names = calloc(1, sizeof(char *));
    r->data = calloc(1, sizeof(char **));
    r->data_types = calloc(1, sizeof(int *));
    if (!r->column_names || !r->data || !r->data_types) {
        free(json);
        return -1;
    }
    r->column_names[0] = strdup(edge ? "rel" : "node");
    r->data[0] = calloc(1, sizeof(char *));
    r->data_types[0] = calloc(1, sizeof(int));
    if (!r->column_names[0] || !r->data[0] || !r->data_types[0]) {
        free(json);
        return -1;
    }
    r->data[0][0] = json;
    r->data_types[0][0] = GQL_COL_TYPE_JSON;
    return 0;
}

static int read_ids(cypher_executor *ex, const char *list, bool edge, int **out, int *count)
{
    *out = NULL;
    *count = 0;
    sqlite3_stmt *st = NULL;
    int rc;
    if (sqlite3_prepare_v2(ex->db, "SELECT value FROM json_each(?1)", -1, &st, NULL) != SQLITE_OK)
        return -1;
    sqlite3_bind_text(st, 1, list, -1, SQLITE_TRANSIENT);
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        int id = entity_id(ex->db, (const char *)sqlite3_column_text(st, 0), edge);
        if (id < 0) {
            rc = SQLITE_ERROR;
            break;
        }
        bool seen = false;
        for (int i = 0; i < *count; i++)
            if ((*out)[i] == id)
                seen = true;
        if (seen)
            continue;
        int *ids = realloc(*out, (size_t)(*count + 1) * sizeof(int));
        if (!ids) {
            rc = SQLITE_NOMEM;
            break;
        }
        *out = ids;
        (*out)[(*count)++] = id;
    }
    sqlite3_finalize(st);
    return rc == SQLITE_DONE ? 0 : -1;
}

static int delete_edge(cypher_executor *ex, int id, cypher_result *r)
{
    if (delete_properties(ex, id, true, NULL) < 0 ||
        cypher_schema_delete_edge(ex->schema_mgr, id) < 0)
        return -1;
    r->relationships_deleted++;
    return 0;
}

static int merge_edge(cypher_executor *ex, int keep, int drop, const char *mode, cypher_result *r)
{
    if (keep == drop)
        return 0;
    char *props = properties(ex->db, drop, true);
    if (!props)
        return -1;
    int rc = apply_properties(ex, keep, true, props, mode, r);
    free(props);
    return rc < 0 ? -1 : delete_edge(ex, drop, r);
}

/* Coalesce parallel directed relationships of the same type only. Reverse
 * edges and edges of different types remain distinct; self-loops survive. */
static int collapse_edges(cypher_executor *ex, int node, const char *mode, const char *preserved,
                          cypher_result *r)
{
    sqlite3_stmt *st = NULL;
    int *keep = NULL, *drop = NULL, n = 0, rc = -1;
    const char *sql =
        "SELECT a.id,(SELECT min(b.id) FROM edges b WHERE b.source_id=a.source_id AND "
        "b.target_id=a.target_id AND b.type=a.type AND b.id NOT IN (SELECT value FROM "
        "json_each(?2))) k FROM edges a WHERE (a.source_id=?1 OR a.target_id=?1) AND a.id NOT IN "
        "(SELECT value FROM json_each(?2)) AND a.id>k ORDER BY a.id";
    if (sqlite3_prepare_v2(ex->db, sql, -1, &st, NULL) != SQLITE_OK)
        return -1;
    sqlite3_bind_int(st, 1, node);
    sqlite3_bind_text(st, 2, preserved, -1, SQLITE_TRANSIENT);
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        int *a = realloc(keep, (size_t)(n + 1) * sizeof(int));
        if (!a) {
            rc = SQLITE_NOMEM;
            break;
        }
        keep = a;
        int *b = realloc(drop, (size_t)(n + 1) * sizeof(int));
        if (!b) {
            rc = SQLITE_NOMEM;
            break;
        }
        drop = b;
        keep[n] = sqlite3_column_int(st, 1);
        drop[n++] = sqlite3_column_int(st, 0);
    }
    sqlite3_finalize(st);
    if (rc == SQLITE_DONE) {
        rc = 0;
        for (int i = 0; i < n && rc == 0; i++)
            rc = merge_edge(ex, keep[i], drop[i], mode, r);
    } else
        rc = -1;
    free(keep);
    free(drop);
    return rc;
}

/* Configuration outside this subset is rejected instead of silently
 * pretending to apply APOC behavior that GraphQLite does not implement. */
static int check_config(sqlite3 *db, const char *config, const char *allowed, cypher_result *r)
{
    sqlite3_stmt *st = NULL;
    int rc;
    if (sqlite3_prepare_v2(db, "SELECT key FROM json_each(?1) WHERE instr(?2,','||key||',')=0", -1,
                           &st, NULL) != SQLITE_OK)
        return -1;
    sqlite3_bind_text(st, 1, config, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, allowed, -1, SQLITE_TRANSIENT);
    rc = sqlite3_step(st);
    if (rc == SQLITE_ROW) {
        char msg[256];
        snprintf(msg, sizeof(msg), "Unsupported APOC configuration option: %s",
                 sqlite3_column_text(st, 0));
        fail(r, msg);
    }
    sqlite3_finalize(st);
    return rc == SQLITE_DONE ? 0 : -1;
}

static char *existing_self_edges(sqlite3 *db, int id)
{
    sqlite3_stmt *st = NULL;
    char *out = NULL;
    if (sqlite3_prepare_v2(
            db, "SELECT json_group_array(id) FROM edges WHERE source_id=?1 AND target_id=?1", -1,
            &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int(st, 1, id);
        if (sqlite3_step(st) == SQLITE_ROW)
            out = strdup((const char *)sqlite3_column_text(st, 0));
    }
    sqlite3_finalize(st);
    return out;
}

static int refactor(cypher_executor *ex, const char *args, bool edge, cypher_result *r)
{
    char *list = field(ex->db, args, "$[0]", "array"),
         *config = field(ex->db, args, "$[1]", "object");
    if (!list) {
        free(config);
        return fail(r, "APOC refactor expects a list of graph entities");
    }
    if (!config)
        config = strdup("{}");
    const char *options = edge ? ",properties," : ",properties,mergeRels,";
    if (check_config(ex->db, config, options, r) < 0) {
        free(list);
        free(config);
        return -1;
    }
    if (!has_type(ex->db, config, "$.properties", ",missing,text,") ||
        !has_type(ex->db, config, "$.mergeRels", ",missing,true,false,")) {
        free(list);
        free(config);
        return fail(r, "APOC refactor expects a string properties policy and boolean mergeRels");
    }
    char *mode = field(ex->db, config, "$.properties", "text");
    if (!mode)
        mode = strdup("overwrite");
    if (strcmp(mode, "overwrite") && strcmp(mode, "discard") && strcmp(mode, "combine")) {
        free(list);
        free(config);
        free(mode);
        return fail(r, "Unsupported APOC properties policy");
    }
    char *merge = field(ex->db, config, "$.mergeRels", "true");
    bool merge_rels = merge != NULL;
    free(merge);
    int *ids = NULL, n = 0, rc = read_ids(ex, list, edge, &ids, &n);
    free(list);
    free(config);
    if (rc < 0) {
        free(ids);
        free(mode);
        return fail(r, "APOC refactor requires existing graph entities");
    }
    if (n == 0) {
        r->column_count = 1;
        r->column_names = calloc(1, sizeof(char *));
        if (r->column_names)
            r->column_names[0] = strdup(edge ? "rel" : "node");
        free(ids);
        free(mode);
        return r->column_names && r->column_names[0] ? 0 : -1;
    }
    char *preserved = !edge ? existing_self_edges(ex->db, ids[0]) : NULL;
    if (!edge && !preserved) {
        free(ids);
        free(mode);
        return -1;
    }
    if (edge) {
        /* Validate endpoints before modifying any relationship. Different
         * types are allowed; the first relationship's type is retained. */
        for (int i = 1; i < n; i++) {
            sqlite3_stmt *st = NULL;
            if (sqlite3_prepare_v2(ex->db,
                                   "SELECT a.source_id=b.source_id AND a.target_id=b.target_id "
                                   "FROM edges a,edges b WHERE a.id=?1 AND b.id=?2",
                                   -1, &st, NULL) != SQLITE_OK) {
                rc = -1;
                break;
            }
            sqlite3_bind_int(st, 1, ids[0]);
            sqlite3_bind_int(st, 2, ids[i]);
            bool same = sqlite3_step(st) == SQLITE_ROW && sqlite3_column_int(st, 0);
            sqlite3_finalize(st);
            if (!same) {
                rc = fail(
                    r, "apoc.refactor.mergeRelationships requires identical start and end nodes");
                break;
            }
        }
        for (int i = 1; i < n && rc == 0; i++)
            rc = merge_edge(ex, ids[0], ids[i], mode, r);
    } else {
        for (int i = 1; i < n && rc == 0; i++) {
            char *props = properties(ex->db, ids[i], false);
            if (!props) {
                rc = -1;
                break;
            }
            rc = apply_properties(ex, ids[0], false, props, mode, r);
            free(props);
            if (rc < 0)
                break;
            rc = exec_ids(ex->db,
                          "INSERT OR IGNORE INTO node_labels(node_id,label) SELECT ?1,label FROM "
                          "node_labels WHERE node_id=?2",
                          ids[0], ids[i]);
            if (rc < 0)
                break;
            rc = exec_ids(ex->db,
                          "UPDATE edges SET source_id=CASE source_id WHEN ?2 THEN ?1 ELSE "
                          "source_id END,target_id=CASE target_id WHEN ?2 THEN ?1 ELSE target_id "
                          "END WHERE source_id=?2 OR target_id=?2",
                          ids[0], ids[i]);
            if (rc < 0)
                break;
            if (delete_properties(ex, ids[i], false, NULL) < 0 ||
                exec_ids(ex->db, "DELETE FROM node_labels WHERE node_id=?1", ids[i], 0) < 0 ||
                cypher_schema_delete_node(ex->schema_mgr, ids[i]) < 0) {
                rc = -1;
                break;
            }
            r->nodes_deleted++;
        }
        if (rc == 0 && merge_rels && n > 1)
            rc = collapse_edges(ex, ids[0], mode, preserved, r);
    }
    if (rc == 0)
        rc = output_entity(ex, ids[0], edge, r);
    free(ids);
    free(mode);
    free(preserved);
    return rc;
}

/* Return 1 for a match, 0 for a mismatch, and -1 for an evaluation error. */
static int identity_matches(sqlite3 *db, const char *properties_json, const char *identity)
{
    sqlite3_stmt *st = NULL;
    int same = -1;
    const char *sql =
        "SELECT NOT EXISTS(SELECT 1 FROM json_each(?1) i LEFT JOIN json_each(?2) p ON p.key=i.key "
        "WHERE p.key IS NULL OR p.type!=i.type OR p.value IS NOT i.value)";
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, identity, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, properties_json, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(st) == SQLITE_ROW)
            same = sqlite3_column_int(st, 0);
    }
    sqlite3_finalize(st);
    return same;
}

static int validate_identity(sqlite3 *db, const char *identity, cypher_result *r)
{
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT 1 FROM json_each(?1) WHERE type='null' LIMIT 1", -1, &st,
                           NULL) != SQLITE_OK)
        return -1;
    sqlite3_bind_text(st, 1, identity, -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc == SQLITE_ROW)
        return fail(r, "apoc.merge.relationship identity properties cannot be null");
    return rc == SQLITE_DONE ? 0 : -1;
}

static int merge_relationship(cypher_executor *ex, const char *args, cypher_result *r)
{
    char *start = field(ex->db, args, "$[0]", "object"),
         *type = field(ex->db, args, "$[1]", "text"),
         *ident = field(ex->db, args, "$[2]", "object"),
         *create = field(ex->db, args, "$[3]", "object"),
         *end = field(ex->db, args, "$[4]", "object"),
         *match = field(ex->db, args, "$[5]", "object");
    int rc = -1, id = -1, source = start ? entity_id(ex->db, start, false) : -1,
        target = end ? entity_id(ex->db, end, false) : -1;
    if (source < 0 || target < 0 || !type || !*type || !ident || !create) {
        fail(r, "apoc.merge.relationship expects start node, type, identity map, create map, end "
                "node [, match map]");
        goto done;
    }
    if (validate_identity(ex->db, ident, r) < 0)
        goto done;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(
            ex->db,
            "SELECT id FROM edges WHERE source_id=?1 AND target_id=?2 AND type=?3 ORDER BY id", -1,
            &st, NULL) != SQLITE_OK)
        goto done;
    sqlite3_bind_int(st, 1, source);
    sqlite3_bind_int(st, 2, target);
    sqlite3_bind_text(st, 3, type, -1, SQLITE_TRANSIENT);
    int step;
    while ((step = sqlite3_step(st)) == SQLITE_ROW) {
        int candidate = sqlite3_column_int(st, 0);
        char *props = properties(ex->db, candidate, true);
        int same = props ? identity_matches(ex->db, props, ident) : -1;
        free(props);
        if (same < 0) {
            step = SQLITE_ERROR;
            break;
        }
        if (same) {
            id = candidate;
            break;
        }
    }
    sqlite3_finalize(st);
    if (step != SQLITE_ROW && step != SQLITE_DONE)
        goto done;
    if (id < 0) {
        id = cypher_schema_create_edge(ex->schema_mgr, source, target, type);
        if (id < 0)
            goto done;
        r->relationships_created++;
        if (apply_properties(ex, id, true, ident, "overwrite", r) < 0 ||
            apply_properties(ex, id, true, create, "overwrite", r) < 0)
            goto done;
    } else if (match && apply_properties(ex, id, true, match, "overwrite", r) < 0)
        goto done;
    rc = output_entity(ex, id, true, r);
done:
    free(start);
    free(type);
    free(ident);
    free(create);
    free(end);
    free(match);
    return rc;
}

static int iterate(cypher_executor *ex, const char *args, cypher_result *r)
{
    char *producer = field(ex->db, args, "$[0]", "text"),
         *action = field(ex->db, args, "$[1]", "text"),
         *config = field(ex->db, args, "$[2]", "object");
    if (!producer || !action || !config) {
        free(producer);
        free(action);
        free(config);
        return fail(r, "apoc.periodic.iterate expects producer, action, configuration map");
    }
    if (check_config(ex->db, config, ",batchSize,parallel,params,", r) < 0) {
        free(producer);
        free(action);
        free(config);
        return -1;
    }
    if (!has_type(ex->db, config, "$.batchSize", ",missing,integer,") ||
        !has_type(ex->db, config, "$.parallel", ",missing,true,false,") ||
        !has_type(ex->db, config, "$.params", ",missing,object,")) {
        free(producer);
        free(action);
        free(config);
        return fail(r, "Invalid apoc.periodic.iterate configuration value type");
    }
    char *batch = field(ex->db, config, "$.batchSize", "integer");
    long batchsize = batch ? strtol(batch, NULL, 10) : 10000;
    free(batch);
    if (batchsize <= 0) {
        free(producer);
        free(action);
        free(config);
        return fail(r, "apoc.periodic.iterate batchSize must be positive");
    }
    /* SQLite has one writer: parallel requests are executed sequentially.
     * Materialization keeps producer iteration stable while graph changes.
     * One enclosing transaction intentionally makes failures atomic. */
    const char *saved = ex->params_json;
    char *params = field(ex->db, config, "$.params", "object");
    if (params)
        ex->params_json = params;
    cypher_result *rows = cypher_executor_execute(ex, producer);
    int rc = 0;
    if (!rows || !rows->success) {
        rc = fail(r, rows && rows->error_message ? rows->error_message : "APOC producer failed");
        goto done;
    }
    for (int i = 0; i < rows->row_count; i++) {
        cypher_result *one = executor_execute_imported(ex, action, rows, i);
        if (!one || !one->success) {
            rc = fail(r, one && one->error_message ? one->error_message : "APOC action failed");
            if (one)
                cypher_result_free(one);
            break;
        }
        r->nodes_created += one->nodes_created;
        r->nodes_deleted += one->nodes_deleted;
        r->relationships_created += one->relationships_created;
        r->relationships_deleted += one->relationships_deleted;
        r->properties_set += one->properties_set;
        cypher_result_free(one);
    }
    if (rc == 0) {
        static const char *names[] = {"batches",
                                      "total",
                                      "failedBatches",
                                      "failedOperations",
                                      "committedOperations",
                                      "wasTerminated",
                                      "errorMessages"};
        int n = 7;
        r->column_count = n;
        r->row_count = 1;
        r->column_names = calloc(n, sizeof(char *));
        r->data = calloc(1, sizeof(char **));
        r->data_types = calloc(1, sizeof(int *));
        if (!r->column_names || !r->data || !r->data_types) {
            rc = -1;
            goto done;
        }
        r->data[0] = calloc(n, sizeof(char *));
        r->data_types[0] = calloc(n, sizeof(int));
        if (!r->data[0] || !r->data_types[0]) {
            rc = -1;
            goto done;
        }
        for (int k = 0; k < n; k++) {
            r->column_names[k] = strdup(names[k]);
            r->data_types[0][k] = SQLITE_INTEGER;
        }
        char value[64];
        snprintf(value, sizeof(value), "%ld",
                 rows->row_count ? (rows->row_count - 1) / batchsize + 1 : 0);
        r->data[0][0] = strdup(value);
        snprintf(value, sizeof(value), "%d", rows->row_count);
        r->data[0][1] = strdup(value);
        r->data[0][4] = strdup(value);
        r->data[0][2] = strdup("0");
        r->data[0][3] = strdup("0");
        r->data[0][5] = strdup("false");
        r->data_types[0][5] = GQL_COL_TYPE_BOOLEAN;
        r->data[0][6] = strdup("{}");
        r->data_types[0][6] = GQL_COL_TYPE_JSON;
    }
done:
    ex->params_json = saved;
    free(params);
    if (rows)
        cypher_result_free(rows);
    free(producer);
    free(action);
    free(config);
    return rc;
}

bool executor_apoc_known(const char *name)
{
    return name && (!strcasecmp(name, "apoc.periodic.iterate") ||
                    !strcasecmp(name, "apoc.refactor.mergeNodes") ||
                    !strcasecmp(name, "apoc.refactor.mergeRelationships") ||
                    !strcasecmp(name, "apoc.merge.relationship"));
}

int executor_apoc_call(cypher_executor *ex, const char *name, const char *args, cypher_result *r)
{
    if (!executor_apoc_known(name))
        return fail(r, "ProcedureError: ProcedureNotFound: unsupported APOC procedure");
    int argc = argument_count(ex->db, args);
    bool periodic = !strcasecmp(name, "apoc.periodic.iterate"),
         dynamic = !strcasecmp(name, "apoc.merge.relationship");
    if ((periodic && argc != 3) || (dynamic && (argc < 5 || argc > 6)) ||
        (!periodic && !dynamic && (argc < 1 || argc > 2)))
        return fail(r, "Invalid APOC procedure argument count");
    if (!periodic && !dynamic && !has_type(ex->db, args, "$[1]", ",missing,object,"))
        return fail(r, "APOC refactor configuration must be a map");
    if (dynamic && !has_type(ex->db, args, "$[5]", ",missing,object,"))
        return fail(r, "APOC onMatch properties must be a map");
    if (sqlite3_exec(ex->db, "SAVEPOINT gql_apoc", NULL, NULL, NULL) != SQLITE_OK)
        return fail(r, sqlite3_errmsg(ex->db));
    int rc;
    if (!strcasecmp(name, "apoc.periodic.iterate"))
        rc = iterate(ex, args, r);
    else if (!strcasecmp(name, "apoc.refactor.mergeNodes"))
        rc = refactor(ex, args, false, r);
    else if (!strcasecmp(name, "apoc.refactor.mergeRelationships"))
        rc = refactor(ex, args, true, r);
    else
        rc = merge_relationship(ex, args, r);
    if (rc == 0 && sqlite3_exec(ex->db, "RELEASE gql_apoc", NULL, NULL, NULL) != SQLITE_OK)
        rc = fail(r, sqlite3_errmsg(ex->db));
    if (rc < 0) {
        if (!r->error_message)
            fail(r, sqlite3_errcode(ex->db) == SQLITE_OK ? "APOC operation failed"
                                                         : sqlite3_errmsg(ex->db));
        sqlite3_exec(ex->db, "ROLLBACK TO gql_apoc", NULL, NULL, NULL);
        cypher_schema_clear_property_key_cache(ex->schema_mgr);
        r->nodes_created = r->nodes_deleted = r->relationships_created = r->relationships_deleted =
            r->properties_set = 0;
        sqlite3_exec(ex->db, "RELEASE gql_apoc", NULL, NULL, NULL);
    }
    if (rc == 0) {
        r->success = true;
        if (r->nodes_created || r->nodes_deleted || r->relationships_deleted ||
            r->relationships_created || r->properties_set)
            ex->graph_dirty = true;
    }
    return rc;
}
