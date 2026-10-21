#include <CUnit/CUnit.h>
#include <sqlite3.h>
#include <string.h>

#include "runtime/udf_helpers.h"
#include "test_regex.h"

static sqlite3 *regex_db;

static int setup_regex(void) {
    if (sqlite3_open(":memory:", &regex_db) != SQLITE_OK) return -1;
    return sqlite3_create_function(regex_db, "regexp", 2, SQLITE_UTF8, NULL,
                                   regexp_func, NULL, NULL) == SQLITE_OK ? 0 : -1;
}

static int teardown_regex(void) {
    int rc = sqlite3_close(regex_db);
    regex_db = NULL;
    return rc == SQLITE_OK ? 0 : -1;
}

static void assert_regex(const char *pattern, const char *subject, int expected) {
    sqlite3_stmt *statement = NULL;
    CU_ASSERT_EQUAL_FATAL(sqlite3_prepare_v2(regex_db, "SELECT regexp(?1, ?2)",
                                           -1, &statement, NULL), SQLITE_OK);
    sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_STATIC);
    sqlite3_bind_text(statement, 2, subject, -1, SQLITE_STATIC);
    int rc = sqlite3_step(statement);
    CU_ASSERT_EQUAL(rc, SQLITE_ROW);
    if (rc == SQLITE_ROW) {
        CU_ASSERT_EQUAL(sqlite3_column_type(statement, 0), SQLITE_INTEGER);
        CU_ASSERT_EQUAL(sqlite3_column_int(statement, 0), expected);
    }
    sqlite3_finalize(statement);
}

static void test_whole_string(void) {
    assert_regex("admin", "prefix-admin-suffix", 0);
    assert_regex(".*admin.*", "prefix-admin-suffix", 1);
    assert_regex("a|ab", "ab", 1);
    assert_regex(".*?", "abc", 1);
    assert_regex("", "", 1);
    assert_regex("", "x", 0);
    assert_regex("a$", "a\n", 0);
    assert_regex(".", "é", 1);
    assert_regex("\\d+", "١٢", 0); /* Java's default shorthand is ASCII. */
    assert_regex("\\w+", "é", 0);
}

static void test_flags_and_assertions(void) {
    assert_regex("(?i)admin", "ADMIN", 1);
    assert_regex("(?i:admin)(?-i:User)", "ADMINUser", 1);
    assert_regex("(?i:admin)(?-i:User)", "ADMINUSER", 0);
    assert_regex("a.b", "a\nb", 0);
    assert_regex("(?s)a.b", "a\nb", 1);
    assert_regex("(?m)^a$\n^b$", "a\nb", 1);
    assert_regex("(?x) a b ", "ab", 1);
    assert_regex("(?=.*[0-9])[A-Za-z0-9]+", "Admin1", 1);
    assert_regex("(?!Guest)[A-Za-z0-9]+", "Guest1", 0);
    assert_regex("a(?<=a)b", "ab", 1);
    assert_regex("a(?<!b)b", "ab", 1);
    assert_regex("(?<word>[A-Za-z]+)-\\k<word>", "user-user", 1);
    assert_regex("(?<word>[A-Za-z]+)-\\k<word>", "user-admin", 0);
    assert_regex("\\u0041", "A", 1);
    assert_regex("\\Q(?U)[a&&b]\\E", "(?U)[a&&b]", 1);
}

static void test_errors(void) {
    const char *patterns[] = {
        "[", "(unclosed", "(?U)abc", "(?u:abc)", "(?d)abc",
        "[a-z&&[^aeiou]]", "[a[b]]", "\\p{javaLowerCase}"
    };
    for (size_t i = 0; i < sizeof(patterns) / sizeof(patterns[0]); i++) {
        sqlite3_stmt *statement = NULL;
        CU_ASSERT_EQUAL_FATAL(sqlite3_prepare_v2(regex_db, "SELECT regexp(?1,'abc')",
                                               -1, &statement, NULL), SQLITE_OK);
        sqlite3_bind_text(statement, 1, patterns[i], -1, SQLITE_STATIC);
        CU_ASSERT_EQUAL(sqlite3_step(statement), SQLITE_ERROR);
        CU_ASSERT_PTR_NOT_NULL(strstr(sqlite3_errmsg(regex_db), "regex"));
        sqlite3_finalize(statement);
    }
}

static void test_nulls(void) {
    sqlite3_stmt *statement = NULL;
    CU_ASSERT_EQUAL_FATAL(sqlite3_prepare_v2(regex_db,
        "SELECT regexp(NULL,'abc'), regexp('.*',NULL), regexp('[',NULL)",
        -1, &statement, NULL), SQLITE_OK);
    CU_ASSERT_EQUAL(sqlite3_step(statement), SQLITE_ROW);
    for (int i = 0; i < 3; i++)
        CU_ASSERT_EQUAL(sqlite3_column_type(statement, i), SQLITE_NULL);
    sqlite3_finalize(statement);
}

static void test_explicit_lengths(void) {
    sqlite3_stmt *statement = NULL;
    CU_ASSERT_EQUAL_FATAL(sqlite3_prepare_v2(regex_db, "SELECT regexp(?1,?2)",
                                           -1, &statement, NULL), SQLITE_OK);
    sqlite3_bind_text(statement, 1, "a.b", 3, SQLITE_STATIC);
    sqlite3_bind_text(statement, 2, "a\0b", 3, SQLITE_STATIC);
    CU_ASSERT_EQUAL(sqlite3_step(statement), SQLITE_ROW);
    CU_ASSERT_EQUAL(sqlite3_column_int(statement, 0), 1);
    sqlite3_reset(statement);
    sqlite3_bind_text(statement, 1, "a", 1, SQLITE_STATIC);
    CU_ASSERT_EQUAL(sqlite3_step(statement), SQLITE_ROW);
    CU_ASSERT_EQUAL(sqlite3_column_int(statement, 0), 0);
    sqlite3_reset(statement);
    sqlite3_bind_text(statement, 1, "a\0b", 3, SQLITE_STATIC);
    CU_ASSERT_EQUAL(sqlite3_step(statement), SQLITE_ROW);
    CU_ASSERT_EQUAL(sqlite3_column_int(statement, 0), 1);
    sqlite3_reset(statement);
    sqlite3_bind_text(statement, 1, ".", 1, SQLITE_STATIC);
    sqlite3_bind_text(statement, 2, "\x80", 1, SQLITE_STATIC);
    CU_ASSERT_EQUAL(sqlite3_step(statement), SQLITE_ERROR);
    sqlite3_finalize(statement);
}

static void test_pattern_cache(void) {
    sqlite3_stmt *statement = NULL;
    CU_ASSERT_EQUAL_FATAL(sqlite3_prepare_v2(regex_db,
        "WITH v(value) AS (VALUES('ab'),('ac'),('ab')) "
        "SELECT regexp('a(?=b)b',value) FROM v",
        -1, &statement, NULL), SQLITE_OK);
    for (int i = 0; i < 3; i++) {
        CU_ASSERT_EQUAL(sqlite3_step(statement), SQLITE_ROW);
        CU_ASSERT_EQUAL(sqlite3_column_int(statement, 0), i != 1);
    }
    CU_ASSERT_EQUAL(sqlite3_step(statement), SQLITE_DONE);
    sqlite3_finalize(statement);
    CU_ASSERT_EQUAL_FATAL(sqlite3_prepare_v2(regex_db,
        "WITH p(pattern) AS (VALUES('a|ab'),('a'),('ab')) "
        "SELECT regexp(pattern,'ab') FROM p",
        -1, &statement, NULL), SQLITE_OK);
    for (int i = 0; i < 3; i++) {
        CU_ASSERT_EQUAL(sqlite3_step(statement), SQLITE_ROW);
        CU_ASSERT_EQUAL(sqlite3_column_int(statement, 0), i != 1);
    }
    CU_ASSERT_EQUAL(sqlite3_step(statement), SQLITE_DONE);
    sqlite3_finalize(statement);
}

int init_regex_suite(void) {
    CU_pSuite suite = CU_add_suite("Regex semantics", setup_regex, teardown_regex);
    if (!suite ||
        !CU_add_test(suite, "Whole-string matching and UTF-8", test_whole_string) ||
        !CU_add_test(suite, "Flags, assertions and captures", test_flags_and_assertions) ||
        !CU_add_test(suite, "Invalid and unsupported patterns fail explicitly", test_errors) ||
        !CU_add_test(suite, "Null propagation", test_nulls) ||
        !CU_add_test(suite, "Embedded NUL and invalid UTF-8", test_explicit_lengths) ||
        !CU_add_test(suite, "Pattern cache lifetime and invalidation", test_pattern_cache))
        return CU_get_error();
    return CUE_SUCCESS;
}
