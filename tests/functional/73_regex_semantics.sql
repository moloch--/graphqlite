-- Cypher =~ matches the entire value, with common Java/PCRE syntax.
.load ./build/graphqlite
CREATE TEMP TABLE _assert(name TEXT, ok INTEGER NOT NULL CHECK (ok = 1));

INSERT INTO _assert SELECT 'whole string rather than substring',
  json_extract(cypher('RETURN "prefix-admin-suffix" =~ "admin" AS matched'), '$[0].matched') = 0;
INSERT INTO _assert SELECT 'explicit substring search',
  json_extract(cypher('RETURN "prefix-admin-suffix" =~ ".*admin.*" AS matched'), '$[0].matched') = 1;
INSERT INTO _assert SELECT 'alternation backtracks to full match',
  json_extract(cypher('RETURN "ab" =~ "a|ab" AS matched'), '$[0].matched') = 1;
INSERT INTO _assert SELECT 'lazy quantifier expands to full match',
  json_extract(cypher('RETURN "abc" =~ ".*?" AS matched'), '$[0].matched') = 1;
INSERT INTO _assert SELECT 'ASCII case insensitive flag',
  json_extract(cypher('RETURN "Domain Admins" =~ "(?i)domain admins" AS matched'), '$[0].matched') = 1;
INSERT INTO _assert SELECT 'scoped case insensitive flag',
  json_extract(cypher('RETURN "DOMAIN.local" =~ "(?i:domain)[.]local" AS matched'), '$[0].matched') = 1;
INSERT INTO _assert SELECT 'positive lookahead',
  json_extract(cypher('RETURN "Admin1" =~ "(?=.*[0-9])[A-Za-z0-9]+" AS matched'), '$[0].matched') = 1;
INSERT INTO _assert SELECT 'negative lookahead excludes prefix',
  json_extract(cypher('RETURN "Guest1" =~ "(?!Guest)[A-Za-z0-9]+" AS matched'), '$[0].matched') = 0;
INSERT INTO _assert SELECT 'lookbehind can inspect earlier matched text',
  json_extract(cypher('RETURN "ab" =~ "a(?<=a)b" AS matched'), '$[0].matched') = 1;
INSERT INTO _assert SELECT 'null input stays null',
  json_type(cypher('RETURN null =~ ".*" AS matched'), '$[0].matched') = 'null' AND
  json_type(cypher('RETURN "abc" =~ null AS matched'), '$[0].matched') = 'null';
INSERT INTO _assert SELECT 'UTF-8 dot matches a code point',
  json_extract(cypher('RETURN "é" =~ "." AS matched'), '$[0].matched') = 1;
INSERT INTO _assert SELECT 'parameterized pattern preserves escaping',
  json_extract(cypher('RETURN $value =~ $pattern AS matched',
    '{"value":"User123","pattern":"(?<word>[A-Za-z]+)\\d+"}'), '$[0].matched') = 1;
INSERT INTO _assert SELECT 'dot excludes newline by default',
  regexp('a.b', 'a' || char(10) || 'b') = 0;
INSERT INTO _assert SELECT 'dotall flag includes newline',
  regexp('(?s)a.b', 'a' || char(10) || 'b') = 1;
INSERT INTO _assert SELECT 'multiline anchors',
  regexp('(?m)^a$' || char(10) || '^b$', 'a' || char(10) || 'b') = 1;
INSERT INTO _assert SELECT 'extended flag ignores whitespace',
  regexp('(?x) a b ', 'ab') = 1;
INSERT INTO _assert SELECT 'dollar never bypasses whole-string ending',
  regexp('a$', 'a' || char(10)) = 0;
SELECT name, ok FROM _assert;
