/*
 * transform_expr_predicate.c
 *    Predicate expression transformations for Cypher queries
 *
 * This file contains transformations for predicate expressions:
 * - EXISTS { pattern } - pattern existence check
 * - EXISTS(n.property) - property existence check
 * - all/any/none/single(x IN list WHERE predicate) - list predicates
 * - reduce(acc = initial, x IN list | expr) - list reduction
 */

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "transform/cypher_transform.h"
#include "transform/transform_expr_predicate.h"
#include "transform/transform_helpers.h"
#include "parser/cypher_ast.h"
#include "parser/cypher_debug.h"

/* Variable-length pattern predicates use the same MATCH transformer as
 * full existential subqueries. This preserves endpoint property maps, inner
 * WHERE predicates, both directions, and relationship-unique traversal. */
static bool exists_pattern_has_varlen(ast_list *patterns)
{
    if (!patterns) return false;
    for (int i = 0; i < patterns->count; i++) {
        ast_node *pattern = patterns->items[i];
        if (!pattern || pattern->type != AST_NODE_PATH) continue;
        cypher_path *path = (cypher_path *)pattern;
        if (!path->elements) continue;
        for (int j = 0; j < path->elements->count; j++) {
            ast_node *element = path->elements->items[j];
            if (element && element->type == AST_NODE_REL_PATTERN &&
                ((cypher_rel_pattern *)element)->varlen) return true;
        }
    }
    return false;
}

/* Transform EXISTS expression */
int transform_exists_expression(cypher_transform_context *ctx, cypher_exists_expr *exists_expr)
{
    CYPHER_DEBUG("Transforming EXISTS expression");

    if (!exists_expr) {
        ctx->has_error = true;
        ctx->error_message = strdup("Invalid EXISTS expression");
        return -1;
    }

    if (exists_expr->expr_type == EXISTS_TYPE_PATTERN &&
        exists_pattern_has_varlen(exists_expr->expr.pattern)) {
        /* These temporary wrappers borrow the parser-owned pattern and WHERE
         * ASTs. Transform synchronously without freeing or retaining them. */
        cypher_match match = {
            .base = {.type = AST_NODE_MATCH},
            .pattern = exists_expr->expr.pattern,
            .where = exists_expr->where_clause,
        };
        ast_node *clauses[] = {(ast_node *)&match};
        ast_list clause_list = {.items = clauses, .count = 1, .capacity = 1};
        cypher_query query = {
            .base = {.type = AST_NODE_QUERY},
            .clauses = &clause_list,
        };
        cypher_exists_expr full = {
            .base = {.type = AST_NODE_EXISTS_EXPR},
            .expr_type = EXISTS_TYPE_QUERY,
            .expr.query = (ast_node *)&query,
            .is_subquery = true,
        };
        return transform_exists_expression(ctx, &full);
    }

    switch (exists_expr->expr_type) {
        case EXISTS_TYPE_QUERY:
            {
                /* GQLITE-T-0139: EXISTS { <read-only query> }. Transform the
                 * body in a CHILD context whose variable scope is seeded with
                 * every outer variable, bound to its outer alias, so the body's
                 * pattern references to outer variables become correlated
                 * references. Counters continue from the outer values so inner
                 * aliases and CTE names cannot shadow outer ones. The result
                 * is embedded as EXISTS (<sql>). Nested EXISTS { } recurse. */
                cypher_query *q = (cypher_query*)exists_expr->expr.query;
                if (!q || !q->clauses || q->clauses->count == 0) {
                    ctx->has_error = true;
                    ctx->error_message = strdup("EXISTS subquery is empty");
                    return -1;
                }
                cypher_transform_context *sub = cypher_transform_create_context_ex(ctx->db, false);
                if (!sub) {
                    ctx->has_error = true;
                    ctx->error_message = strdup("Out of memory in EXISTS subquery");
                    return -1;
                }
                sub->global_alias_counter = ctx->global_alias_counter + 1;
                sub->with_cte_counter = ctx->with_cte_counter + 100;
                sub->anon_node_base = ctx->anon_node_base + 1000;
                /* transform_match_pattern assigns anon_node_base from this
                 * counter. Seed both, otherwise a named inner path reuses an
                 * outer synthetic relationship name such as _pv_e0_1 and is
                 * incorrectly rebound to the outer path's relationship list. */
                sub->anon_node_counter = ctx->anon_node_counter + 1000;
                sub->current_graph = ctx->current_graph;   /* borrowed, not owned */
                int n_outer = transform_var_count(ctx->var_ctx);
                char **outer_tokens = calloc((size_t)(n_outer > 0 ? n_outer : 1), sizeof(char*));
                int outer_token_count = 0;
                for (int vi = 0; vi < n_outer; vi++) {
                    transform_var *v = transform_var_at(ctx->var_ctx, vi);
                    if (!v || !v->name) continue;
                    if (transform_var_is_path(ctx->var_ctx, v->name)) continue;
                    const char *alias = transform_var_get_alias(ctx->var_ctx, v->name);
                    if (!alias) continue;
                    if (transform_var_is_projected(ctx->var_ctx, v->name)) {
                        transform_var_register_projected(sub->var_ctx, v->name, alias);
                        transform_var_set_bound(sub->var_ctx, v->name, true);
                        if (transform_var_is_scalar_value(ctx->var_ctx, v->name)) {
                            transform_var_set_scalar_value(sub->var_ctx, v->name, true);
                        }
                        continue;
                    }
                    /* Register the outer entity the way a WITH does: the
                     * "alias" IS its id expression (`<alias>.id`, or the alias
                     * itself when the outer var is already a post-WITH id
                     * column). generate_node_match then JOINs the inner table
                     * on that id instead of re-emitting FROM nodes AS <alias>,
                     * which would shadow the outer alias and break the
                     * correlation. */
                    char id_expr[300];
                    if (transform_var_alias_is_id(ctx->var_ctx, v->name)) {
                        snprintf(id_expr, sizeof(id_expr), "%s", alias);
                    } else {
                        snprintf(id_expr, sizeof(id_expr), "%s.id", alias);
                    }
                    if (transform_var_is_edge(ctx->var_ctx, v->name)) {
                        transform_var_register_edge(sub->var_ctx, v->name, id_expr, NULL);
                    } else {
                        transform_var_register_node(sub->var_ctx, v->name, id_expr, NULL);
                    }
                    transform_var_set_bound(sub->var_ctx, v->name, true);
                    transform_var_set_alias_is_id(sub->var_ctx, v->name, true);
                    /* Remember the outer table token so the body never adds it to FROM. */
                    if (outer_tokens) {
                        const char *dot = strchr(id_expr, '.');
                        const char *start = dot ? dot : id_expr + strlen(id_expr);
                        while (start > id_expr && (isalnum((unsigned char)start[-1]) || start[-1] == '_')) start--;
                        size_t tl = (size_t)((dot ? dot : id_expr + strlen(id_expr)) - start);
                        char *tok = malloc(tl + 1);
                        if (tok) { memcpy(tok, start, tl); tok[tl] = '\0'; outer_tokens[outer_token_count++] = tok; }
                    }
                    if (transform_var_is_scalar_value(ctx->var_ctx, v->name)) {
                        transform_var_set_scalar_value(sub->var_ctx, v->name, true);
                    }
                }
                /* Outer variables behave like bindings from a previous clause. */
                transform_var_mark_inherited(sub->var_ctx);
                sub->correlated_outer_aliases = (const char **)outer_tokens;
                sub->correlated_outer_count = outer_token_count;
                int rc = cypher_transform_read_query_sql(sub, q);
                sub->correlated_outer_aliases = NULL;
                sub->correlated_outer_count = 0;
                for (int ti = 0; ti < outer_token_count; ti++) free(outer_tokens[ti]);
                free(outer_tokens);
                if (rc < 0 || sub->sql_size == 0) {
                    ctx->has_error = true;
                    free(ctx->error_message);
                    ctx->error_message = strdup(sub->error_message ? sub->error_message
                                                                   : "Failed to transform EXISTS subquery");
                    cypher_transform_free_context(sub);
                    return -1;
                }
                ctx->global_alias_counter = sub->global_alias_counter + 1;
                append_sql(ctx, "EXISTS (%s)", sub->sql_buffer);
                cypher_transform_free_context(sub);
                return 0;
            }
        case EXISTS_TYPE_PATTERN:
            {
                CYPHER_DEBUG("Transforming EXISTS pattern expression");

                if (!exists_expr->expr.pattern || exists_expr->expr.pattern->count == 0) {
                    ctx->has_error = true;
                    ctx->error_message = strdup("EXISTS pattern expression is empty");
                    return -1;
                }

                /* Generate SQL EXISTS subquery with pattern matching */
                append_sql(ctx, "EXISTS (");

                /* For each pattern in the EXISTS clause, we need to generate a subquery */
                /* that checks if the pattern exists in the database */
                ast_node *pattern = exists_expr->expr.pattern->items[0];

                if (pattern->type == AST_NODE_PATH) {
                    cypher_path *path = (cypher_path*)pattern;

                    /* Simple pattern like (n)-[r]->(m) */
                    if (path->elements && path->elements->count >= 1) {

                        /* Start with SELECT 1 to make it an existence check */
                        append_sql(ctx, "SELECT 1 FROM ");

                        bool first_table = true;
                        char node_aliases[10][32];  /* Support up to 10 nodes in pattern */
                        bool node_is_external[10];  /* Track which nodes are from outer context */
                        int node_count = 0;

                        /* Brace form may carry an inner WHERE referencing the
                         * subquery's own pattern variables (e.g. `m`, `r`).
                         * Register those inner variables against their subquery
                         * aliases so transform_expression can resolve them, then
                         * truncate the var context back once the subquery SQL is
                         * emitted (mirrors pattern-comprehension save/restore). */
                        int exists_saved_vars = transform_var_count(ctx->var_ctx);

                        /* Process each element in the path */
                        for (int i = 0; i < path->elements->count; i++) {
                            ast_node *element = path->elements->items[i];

                            if (element->type == AST_NODE_NODE_PATTERN) {
                                cypher_node_pattern *node = (cypher_node_pattern*)element;

                                /* Check if this node variable exists in outer context */
                                const char *outer_alias = NULL;
                                if (node->variable) {
                                    outer_alias = transform_var_get_alias(ctx->var_ctx, node->variable);
                                }

                                if (outer_alias) {
                                    /* Use alias from outer query - don't add to FROM */
                                    strncpy(node_aliases[node_count], outer_alias,
                                           sizeof(node_aliases[node_count]) - 1);
                                    node_aliases[node_count][sizeof(node_aliases[node_count]) - 1] = '\0';
                                    /* GQLITE-T-0139: an outer entity seeded into an
                                     * EXISTS { } body carries its id expression
                                     * (`<alias>.id`) as alias; the emitters below
                                     * append `.id` themselves, so strip it here. */
                                    if (transform_var_alias_is_id(ctx->var_ctx, node->variable)) {
                                        size_t al = strlen(node_aliases[node_count]);
                                        if (al > 3 && strcmp(node_aliases[node_count] + al - 3, ".id") == 0) {
                                            node_aliases[node_count][al - 3] = '\0';
                                        }
                                    }
                                    node_is_external[node_count] = true;
                                } else {
                                    /* Generate new alias and add to FROM */
                                    if (!first_table) {
                                        append_sql(ctx, ", ");
                                    }
                                    snprintf(node_aliases[node_count], sizeof(node_aliases[node_count]),
                                            "n%d", node_count);
                                    append_sql(ctx, "nodes AS %s", node_aliases[node_count]);
                                    node_is_external[node_count] = false;
                                    /* Register the inner node var so an inner WHERE
                                     * can reference it (ExistentialSubquery1 [2]). */
                                    if (node->variable && exists_expr->where_clause) {
                                        transform_var_register_node(ctx->var_ctx, node->variable,
                                                                    node_aliases[node_count], NULL);
                                    }
                                    first_table = false;
                                }
                                node_count++;

                            } else if (element->type == AST_NODE_REL_PATTERN && i > 0) {
                                /* Relationship pattern: -[variable:TYPE]-> */
                                cypher_rel_pattern *rel = (cypher_rel_pattern*)element;
                                if (!first_table) {
                                    append_sql(ctx, ", ");
                                }
                                append_sql(ctx, "edges AS e%d", i/2);  /* Relationships are at odd indices */
                                /* Register the inner rel var for the inner WHERE
                                 * (ExistentialSubquery1 [4]: `type(r) = 'NA'`). */
                                if (rel->variable && exists_expr->where_clause) {
                                    char ealias[16];
                                    snprintf(ealias, sizeof(ealias), "e%d", i/2);
                                    transform_var_register_edge(ctx->var_ctx, rel->variable,
                                                                ealias, rel->type);
                                }
                                first_table = false;
                            }
                        }

                        /* Add WHERE clause for joins and constraints */
                        append_sql(ctx, " WHERE ");

                        bool first_condition = true;
                        int rel_index = 0;

                        /* Generate join conditions between nodes and relationships */
                        for (int i = 0; i < path->elements->count; i++) {
                            ast_node *element = path->elements->items[i];

                            if (element->type == AST_NODE_REL_PATTERN && i > 0 && i < path->elements->count - 1) {
                                cypher_rel_pattern *rel = (cypher_rel_pattern*)element;

                                if (!first_condition) {
                                    append_sql(ctx, " AND ");
                                }

                                /* Join source node with relationship, respecting direction */
                                int left_node = i / 2;
                                int right_node = left_node + 1;

                                if (rel->left_arrow && !rel->right_arrow) {
                                    /* Incoming: <-[]-  means edge goes right_node -> left_node */
                                    append_sql(ctx, "e%d.source_id = %s.id AND e%d.target_id = %s.id",
                                              rel_index, node_aliases[right_node],
                                              rel_index, node_aliases[left_node]);
                                } else if (!rel->left_arrow && !rel->right_arrow) {
                                    /* Undirected: -[]-  match either direction */
                                    append_sql(ctx, "((e%d.source_id = %s.id AND e%d.target_id = %s.id) OR (e%d.source_id = %s.id AND e%d.target_id = %s.id))",
                                              rel_index, node_aliases[left_node],
                                              rel_index, node_aliases[right_node],
                                              rel_index, node_aliases[right_node],
                                              rel_index, node_aliases[left_node]);
                                } else {
                                    /* Outgoing: -[]->  (default) */
                                    append_sql(ctx, "e%d.source_id = %s.id AND e%d.target_id = %s.id",
                                              rel_index, node_aliases[left_node],
                                              rel_index, node_aliases[right_node]);
                                }

                                /* Add relationship type constraint if specified */
                                if (rel->type) {
                                    append_sql(ctx, " AND e%d.type = ", rel_index);
                                    append_string_literal(ctx, rel->type);
                                }

                                rel_index++;
                                first_condition = false;
                            } else if (element->type == AST_NODE_NODE_PATTERN) {
                                cypher_node_pattern *node = (cypher_node_pattern*)element;

                                /* Add label constraints if specified - one condition per label */
                                if (has_labels(node)) {
                                    for (int j = 0; j < node->labels->count; j++) {
                                        const char *label = get_label_string(node->labels->items[j]);
                                        if (label) {
                                            if (!first_condition) {
                                                append_sql(ctx, " AND ");
                                            }

                                            int current_node = (i == 0) ? 0 : i / 2;
                                            append_sql(ctx, "EXISTS (SELECT 1 FROM node_labels WHERE node_id = %s.id AND label = ",
                                                      node_aliases[current_node]);
                                            append_string_literal(ctx, label);
                                            append_sql(ctx, ")");
                                            first_condition = false;
                                        }
                                    }
                                }
                            }
                        }

                        /* Fold the inner WHERE predicate into the subquery,
                         * now that the pattern's own variables are registered.
                         * ExistentialSubquery1 [2]/[4]. */
                        if (exists_expr->where_clause) {
                            append_sql(ctx, first_condition ? "(" : " AND (");
                            if (transform_condition(ctx, exists_expr->where_clause) < 0) {
                                transform_var_truncate_to(ctx->var_ctx, exists_saved_vars);
                                return -1;
                            }
                            append_sql(ctx, ")");
                            first_condition = false;
                        }

                        /* Restore the outer variable scope. */
                        transform_var_truncate_to(ctx->var_ctx, exists_saved_vars);
                    } else {
                        /* Empty pattern - should not happen */
                        append_sql(ctx, "SELECT 0");
                    }
                } else {
                    /* Unsupported pattern type */
                    ctx->has_error = true;
                    ctx->error_message = strdup("Unsupported pattern type in EXISTS expression");
                    return -1;
                }

                append_sql(ctx, ")");
                return 0;
            }

        case EXISTS_TYPE_PROPERTY:
            {
                CYPHER_DEBUG("Transforming EXISTS property expression");

                if (!exists_expr->expr.property) {
                    ctx->has_error = true;
                    ctx->error_message = strdup("EXISTS property expression is empty");
                    return -1;
                }

                /* Generate property existence check */
                /* This should be a property access like n.property */
                if (exists_expr->expr.property->type == AST_NODE_PROPERTY) {
                    cypher_property *prop = (cypher_property*)exists_expr->expr.property;

                    if (prop->expr->type == AST_NODE_IDENTIFIER) {
                        cypher_identifier *id = (cypher_identifier*)prop->expr;
                        const char *alias = transform_var_get_alias(ctx->var_ctx, id->name);

                        if (!alias) {
                            ctx->has_error = true;
                            char error[256];
                            snprintf(error, sizeof(error), transform_var_is_path(ctx->var_ctx, id->name) ? "SyntaxError: InvalidArgumentType: EXISTS property: `%s` is a path" : "SyntaxError: UndefinedVariable: EXISTS property: `%s` is not defined", id->name);
                            ctx->error_message = strdup(error);
                            return -1;
                        }

                        /* Multi-graph support: get graph prefix for table references */
                        const char *graph = transform_var_get_graph(ctx->var_ctx, id->name);
                        const char *gprefix = "";
                        char gprefix_buf[64] = "";
                        if (graph && graph[0] != '\0') {
                            snprintf(gprefix_buf, sizeof(gprefix_buf), "%s.", graph);
                            gprefix = gprefix_buf;
                        }

                        /* Generate SQL to check if property exists */
                        append_sql(ctx, "(");
                        append_sql(ctx, "EXISTS (SELECT 1 FROM %snode_props_text npt JOIN %sproperty_keys pk ON npt.key_id = pk.id WHERE npt.node_id = %s.id AND pk.key = ", gprefix, gprefix, alias);
                        append_string_literal(ctx, prop->property_name);
                        append_sql(ctx, ") OR ");
                        append_sql(ctx, "EXISTS (SELECT 1 FROM %snode_props_int npi JOIN %sproperty_keys pk ON npi.key_id = pk.id WHERE npi.node_id = %s.id AND pk.key = ", gprefix, gprefix, alias);
                        append_string_literal(ctx, prop->property_name);
                        append_sql(ctx, ") OR ");
                        append_sql(ctx, "EXISTS (SELECT 1 FROM %snode_props_real npr JOIN %sproperty_keys pk ON npr.key_id = pk.id WHERE npr.node_id = %s.id AND pk.key = ", gprefix, gprefix, alias);
                        append_string_literal(ctx, prop->property_name);
                        append_sql(ctx, ") OR ");
                        append_sql(ctx, "EXISTS (SELECT 1 FROM %snode_props_bool npb JOIN %sproperty_keys pk ON npb.key_id = pk.id WHERE npb.node_id = %s.id AND pk.key = ", gprefix, gprefix, alias);
                        append_string_literal(ctx, prop->property_name);
                        append_sql(ctx, ")");
                        append_sql(ctx, ")");

                        return 0;
                    } else {
                        ctx->has_error = true;
                        ctx->error_message = strdup("EXISTS property must reference a variable");
                        return -1;
                    }
                } else {
                    ctx->has_error = true;
                    ctx->error_message = strdup("EXISTS property expression must be a property access");
                    return -1;
                }
            }

        default:
            ctx->has_error = true;
            ctx->error_message = strdup("Unknown EXISTS expression type");
            return -1;
    }
}

/* Transform list predicate: all/any/none/single(x IN list WHERE predicate)
 *
 * Emits openCypher three-valued-logic semantics:
 *
 *   Let T = count of elements where (pred) is TRUE
 *       F = count where (pred) is FALSE
 *       N = count where (pred) is NULL
 *       TOT = T+F+N
 *
 *   all:    TOT=0 → TRUE ; F>0 → FALSE ; N>0 → NULL ; else TRUE
 *   any:    T>0 → TRUE  ; N>0 → NULL  ; else FALSE
 *   none:   T>0 → FALSE ; N>0 → NULL  ; else TRUE   (TOT=0 also TRUE)
 *   single: T>1 → FALSE ; N>0 → NULL  ; T=1 → TRUE  ; else FALSE
 *
 * SQL pattern:
 *   (SELECT CASE ... END FROM (SELECT (<pred>) AS p FROM json_each(<list>)))
 */
int transform_list_predicate(cypher_transform_context *ctx, cypher_list_predicate *pred)
{
    CYPHER_DEBUG("Transforming list predicate type %d", pred->pred_type);

    if (!pred || !pred->variable || !pred->list_expr || !pred->predicate) {
        ctx->has_error = true;
        ctx->error_message = strdup("Invalid list predicate");
        return -1;
    }

    /* Evaluate the input in the parent scope, then create a local binding.
     * Preserve the complete outer variable: restoring only its alias loses
     * the node/edge kind and makes a later labels(n) treat its id as JSON. */
    char *input = cypher_transform_capture_expression(ctx, pred->list_expr);
    if (!input) return -1;
    int saved_count = transform_var_count(ctx->var_ctx);
    int shadow_index = -1;
    transform_var shadow = {0};
    for (int i = 0; i < saved_count; i++) {
        transform_var *v = transform_var_at(ctx->var_ctx, i);
        if (v->name && !strcmp(v->name, pred->variable)) {
            shadow_index = i;
            shadow = *v;
            memset(v, 0, sizeof(*v));
            break;
        }
    }
    int rc = 0;

    /* Give this level's json_each a unique alias so nested quantifiers
     * (e.g. single(x IN ... WHERE none(y IN x ...))) don't shadow each
     * other — the inner json_each must not capture the outer iteration
     * variable. Map the predicate variable to "<alias>.value".
     * (Quantifier6 family.) */
    char je_alias[32], je_value[40];
    snprintf(je_alias, sizeof(je_alias), "_je_%d", ctx->quantifier_counter++);
    snprintf(je_value, sizeof(je_value), "%s.value", je_alias);

    /* Register the predicate variable to map to <alias>.value, with the
     * element's type tag (a boolean stays a boolean). */
    if (transform_var_register_projected(ctx->var_ctx, pred->variable, je_value) < 0) {
        rc = -1;
        goto cleanup;
    }
    {
        char tag[256];
        snprintf(tag, sizeof(tag),
                 "(CASE %s.type WHEN 'true' THEN 'bool' WHEN 'false' THEN 'bool' "
                 "WHEN 'array' THEN 'json' WHEN 'object' THEN 'json' WHEN 'text' THEN 'text' END)",
                 je_alias);
        if (transform_var_set_tag(ctx->var_ctx, pred->variable, tag) < 0) {
            rc = -1;
            goto cleanup;
        }
    }

    /* all/any/none/single all use strict openCypher 3VL via the SUM-over-
     * json_each CASE below. (An earlier note claimed `all` had to keep a
     * legacy "ignore NULL → TRUE" form to satisfy Precedence1 [14]–[28];
     * that conflict no longer exists — Precedence1 stays 55/55 under strict
     * 3VL, and strict 3VL fixes Quantifier4 [10].) */
    {
        append_sql(ctx, "(SELECT CASE ");
        switch (pred->pred_type) {
            case LIST_PRED_ALL:
                /* F>0 → FALSE ; N>0 → NULL ; else TRUE (strict 3VL,
                 * Quantifier4 [10]). */
                append_sql(ctx,
                    "WHEN SUM(CASE WHEN p IS NOT NULL AND NOT p THEN 1 ELSE 0 END) > 0 THEN 0 "
                    "WHEN SUM(CASE WHEN p IS NULL THEN 1 ELSE 0 END) > 0 THEN NULL "
                    "ELSE 1 ");
                break;
            case LIST_PRED_ANY:
                /* T>0 → TRUE ; N>0 → NULL ; else FALSE */
                append_sql(ctx,
                    "WHEN SUM(CASE WHEN p IS NOT NULL AND p THEN 1 ELSE 0 END) > 0 THEN 1 "
                    "WHEN SUM(CASE WHEN p IS NULL THEN 1 ELSE 0 END) > 0 THEN NULL "
                    "ELSE 0 ");
                break;
            case LIST_PRED_NONE:
                /* T>0 → FALSE ; N>0 → NULL ; else TRUE */
                append_sql(ctx,
                    "WHEN SUM(CASE WHEN p IS NOT NULL AND p THEN 1 ELSE 0 END) > 0 THEN 0 "
                    "WHEN SUM(CASE WHEN p IS NULL THEN 1 ELSE 0 END) > 0 THEN NULL "
                    "ELSE 1 ");
                break;
            case LIST_PRED_SINGLE:
                /* T>1 → FALSE ; N>0 → NULL ; T=1 → TRUE ; else FALSE */
                append_sql(ctx,
                    "WHEN SUM(CASE WHEN p IS NOT NULL AND p THEN 1 ELSE 0 END) > 1 THEN 0 "
                    "WHEN SUM(CASE WHEN p IS NULL THEN 1 ELSE 0 END) > 0 THEN NULL "
                    "WHEN SUM(CASE WHEN p IS NOT NULL AND p THEN 1 ELSE 0 END) = 1 THEN 1 "
                    "ELSE 0 ");
                break;
            default:
                break;
        }
        append_sql(ctx, "END FROM (SELECT (");
        if (transform_condition(ctx, pred->predicate) < 0) {
            rc = -1;
            goto cleanup;
        }
        append_sql(ctx, ") AS p FROM json_each(%s) AS %s))", input, je_alias);
    }

cleanup:
    free(input);
    transform_var_truncate_to(ctx->var_ctx, saved_count);
    if (shadow_index >= 0) *transform_var_at(ctx->var_ctx, shadow_index) = shadow;
    return rc;
}

/* Transform reduce expression: reduce(acc = initial, x IN list | expr)
 *
 * SQL generation using recursive CTE:
 * (WITH RECURSIVE _reduce_N AS (
 *     SELECT initial AS acc, 0 AS idx
 *     UNION ALL
 *     SELECT (expression), idx + 1
 *     FROM _reduce_N, json_each(list)
 *     WHERE idx = json_each.key
 * )
 * SELECT acc FROM _reduce_N WHERE idx = json_array_length(list))
 */
int transform_reduce_expr(cypher_transform_context *ctx, cypher_reduce_expr *reduce)
{
    CYPHER_DEBUG("Transforming reduce expression");

    if (!reduce || !reduce->accumulator || !reduce->initial_value ||
        !reduce->variable || !reduce->list_expr || !reduce->expression) {
        ctx->has_error = true;
        ctx->error_message = strdup("Invalid reduce expression");
        return -1;
    }

    /* Generate unique CTE name */
    char cte_name[32];
    snprintf(cte_name, sizeof(cte_name), "_reduce_%d", ctx->reduce_counter++);

    /* Save existing aliases for accumulator and variable names */
    const char *old_acc_alias = transform_var_get_alias(ctx->var_ctx, reduce->accumulator);
    const char *old_var_alias = transform_var_get_alias(ctx->var_ctx, reduce->variable);
    char *saved_acc_alias = old_acc_alias ? strdup(old_acc_alias) : NULL;
    char *saved_var_alias = old_var_alias ? strdup(old_var_alias) : NULL;

    append_sql(ctx, "(WITH RECURSIVE %s AS (SELECT ", cte_name);

    /* Transform initial value */
    if (transform_expression(ctx, reduce->initial_value) < 0) {
        if (saved_acc_alias) free(saved_acc_alias);
        if (saved_var_alias) free(saved_var_alias);
        return -1;
    }

    append_sql(ctx, " AS acc, 0 AS idx UNION ALL SELECT (");

    /* Register variables for the expression:
     * - accumulator maps to cte_name.acc
     * - variable maps to json_each.value
     */
    char acc_ref[64];
    snprintf(acc_ref, sizeof(acc_ref), "%s.acc", cte_name);
    /* Register in unified system */
    transform_var_register_projected(ctx->var_ctx, reduce->accumulator, acc_ref);
    transform_var_register_projected(ctx->var_ctx, reduce->variable, "json_each.value");

    /* Transform the expression that computes new accumulator value */
    if (transform_expression(ctx, reduce->expression) < 0) {
        if (saved_acc_alias) free(saved_acc_alias);
        if (saved_var_alias) free(saved_var_alias);
        return -1;
    }

    append_sql(ctx, "), idx + 1 FROM %s, json_each(", cte_name);

    /* Transform list expression */
    if (transform_expression(ctx, reduce->list_expr) < 0) {
        if (saved_acc_alias) free(saved_acc_alias);
        if (saved_var_alias) free(saved_var_alias);
        return -1;
    }

    append_sql(ctx, ") WHERE %s.idx = json_each.key) SELECT acc FROM %s WHERE idx = json_array_length(",
               cte_name, cte_name);

    /* Transform list expression again for length check */
    if (transform_expression(ctx, reduce->list_expr) < 0) {
        if (saved_acc_alias) free(saved_acc_alias);
        if (saved_var_alias) free(saved_var_alias);
        return -1;
    }

    append_sql(ctx, "))");

    /* Restore old aliases */
    if (saved_acc_alias) {
        transform_var_register_projected(ctx->var_ctx, reduce->accumulator, saved_acc_alias);
        free(saved_acc_alias);
    }
    if (saved_var_alias) {
        transform_var_register_projected(ctx->var_ctx, reduce->variable, saved_var_alias);
        free(saved_var_alias);
    }

    return 0;
}
