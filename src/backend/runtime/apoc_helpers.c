/* Small APOC expression subset used by Cirro. No external APOC runtime. */
#include <regex.h>
#include <stdlib.h>
#include <string.h>
#include "runtime/apoc_helpers.h"
#include "runtime/gql_error.h"

void gql_apoc_to_json(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    (void)argc;
    unsigned st = sqlite3_value_subtype(argv[0]);
    if (st == GQL_SUBTYPE_JSON) {
        sqlite3_result_text(ctx, (const char *)sqlite3_value_text(argv[0]), -1, SQLITE_TRANSIENT);
    } else if (st == GQL_SUBTYPE_BOOLEAN) {
        const char *s = (const char *)sqlite3_value_text(argv[0]);
        sqlite3_result_text(ctx, s && (!strcmp(s, "true") || !strcmp(s, "1")) ? "true" : "false",
                            -1, SQLITE_STATIC);
    } else {
        sqlite3_stmt *s = NULL;
        sqlite3 *db = sqlite3_context_db_handle(ctx);
        if (sqlite3_prepare_v2(db, "SELECT json_quote(?1)", -1, &s, NULL) != SQLITE_OK) {
            sqlite3_result_error(ctx, sqlite3_errmsg(db), -1);
            return;
        }
        sqlite3_bind_value(s, 1, argv[0]);
        if (sqlite3_step(s) == SQLITE_ROW)
            sqlite3_result_text(ctx, (const char *)sqlite3_column_text(s, 0), -1, SQLITE_TRANSIENT);
        else
            sqlite3_result_error(ctx, sqlite3_errmsg(db), -1);
        sqlite3_finalize(s);
    }
}

void gql_apoc_text_replace(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    (void)argc;
    for (int i = 0; i < 3; i++)
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
            sqlite3_result_null(ctx);
            return;
        }
    for (int i = 0; i < 3; i++)
        if (sqlite3_value_type(argv[i]) != SQLITE_TEXT) {
            sqlite3_result_error(ctx, "apoc.text.replace expects three strings", -1);
            return;
        }
    const char *text = (const char *)sqlite3_value_text(argv[0]);
    const char *pattern = (const char *)sqlite3_value_text(argv[1]);
    const char *replacement = (const char *)sqlite3_value_text(argv[2]);
    regex_t re;
    int rc = regcomp(&re, pattern, REG_EXTENDED);
    if (rc) {
        char error[256];
        regerror(rc, &re, error, sizeof(error));
        sqlite3_result_error(ctx, error, -1);
        return;
    }
    sqlite3_str *out = sqlite3_str_new(sqlite3_context_db_handle(ctx));
    const char *at = text;
    regmatch_t m[10];
    int flags = 0;
    while ((rc = regexec(&re, at, 10, m, flags)) == 0) {
        sqlite3_str_append(out, at, (int)m[0].rm_so);
        for (const char *p = replacement; *p; p++) {
            if (*p == '$' && p[1] >= '0' && p[1] <= '9') {
                int group = *++p - '0';
                if (m[group].rm_so >= 0)
                    sqlite3_str_append(out, at + m[group].rm_so,
                                       (int)(m[group].rm_eo - m[group].rm_so));
            } else if (*p == '\\' && p[1])
                sqlite3_str_appendchar(out, 1, *++p);
            else
                sqlite3_str_appendchar(out, 1, *p);
        }
        at += m[0].rm_eo;
        if (m[0].rm_eo == m[0].rm_so) {
            if (!*at)
                break;
            /* Advance one UTF-8 character after an empty match. */
            sqlite3_str_appendchar(out, 1, *at++);
            while (((unsigned char)*at & 0xc0) == 0x80)
                sqlite3_str_appendchar(out, 1, *at++);
        }
        flags = REG_NOTBOL;
    }
    if (rc != 0 && rc != REG_NOMATCH) {
        char error[256];
        regerror(rc, &re, error, sizeof(error));
        sqlite3_free(sqlite3_str_finish(out));
        regfree(&re);
        sqlite3_result_error(ctx, error, -1);
        return;
    }
    sqlite3_str_appendall(out, at);
    char *value = sqlite3_str_finish(out);
    regfree(&re);
    if (!value)
        sqlite3_result_error_nomem(ctx);
    else
        sqlite3_result_text(ctx, value, -1, sqlite3_free);
}

void gql_apoc_text_indexof(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    if (argc < 2 || argc > 4) {
        sqlite3_result_error(ctx, "apoc.text.indexOf expects 2 to 4 arguments", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL || sqlite3_value_type(argv[1]) == SQLITE_NULL) {
        sqlite3_result_null(ctx);
        return;
    }
    if (sqlite3_value_type(argv[0]) != SQLITE_TEXT || sqlite3_value_type(argv[1]) != SQLITE_TEXT) {
        sqlite3_result_error(ctx, "apoc.text.indexOf expects strings", -1);
        return;
    }
    const char *text = (const char *)sqlite3_value_text(argv[0]),
               *find = (const char *)sqlite3_value_text(argv[1]);
    int start = argc > 2 ? sqlite3_value_int(argv[2]) : 0,
        end = argc > 3 ? sqlite3_value_int(argv[3]) : -1;
    int index = 0;
    if (start < 0)
        start = 0;
    size_t n = strlen(find);
    for (const char *p = text;; p++) {
        if (((unsigned char)*p & 0xc0) == 0x80)
            continue;
        if (end >= 0 && index >= end)
            break;
        if (index >= start && !strncmp(p, find, n)) {
            int chars = 0;
            for (size_t j = 0; j < n; j++)
                if (((unsigned char)find[j] & 0xc0) != 0x80)
                    chars++;
            if (end < 0 || index + chars <= end) {
                sqlite3_result_int(ctx, index);
                return;
            }
        }
        if (!*p)
            break;
        index++;
    }
    sqlite3_result_int(ctx, -1);
}
