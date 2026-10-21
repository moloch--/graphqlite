-- CALL UNION must transfer every result representation with each row.
-- Run with allocator poisoning or AddressSanitizer to verify cleanup as well.
.load ./build/graphqlite
CREATE TEMP TABLE _assert(name TEXT, ok INTEGER NOT NULL CHECK (ok = 1));

INSERT INTO _assert SELECT 'scoped UNION ALL appends typed rows',
  json(cypher('WITH 2 AS x CALL (x) { RETURN x AS y UNION ALL RETURN x + 1 AS y } RETURN y ORDER BY y')) =
  json('[{"y":2},{"y":3}]');
INSERT INTO _assert SELECT 'UNION compacts duplicates within and across branches',
  json(cypher('CALL () { UNWIND [2, 2, 3] AS y RETURN y UNION RETURN 3 AS y UNION RETURN 4 AS y } RETURN y ORDER BY y')) =
  json('[{"y":2},{"y":3},{"y":4}]');
INSERT INTO _assert SELECT 'empty left branch still owns appended rows',
  json(cypher('CALL () { UNWIND [] AS empty RETURN 2 AS y UNION ALL RETURN 2 AS y } RETURN y')) =
  json('[{"y":2}]');
INSERT INTO _assert SELECT 'empty right branch preserves original rows',
  json(cypher('CALL () { RETURN 2 AS y UNION ALL UNWIND [] AS empty RETURN 2 AS y } RETURN y')) =
  json('[{"y":2}]');
INSERT INTO _assert SELECT 'nested UNION ALL grows beyond initial result capacity',
  json(cypher('CALL () { UNWIND range(1, 65) AS y RETURN y UNION ALL UNWIND range(66, 130) AS y RETURN y UNION ALL RETURN 131 AS y } RETURN count(y) AS n, sum(y) AS total')) =
  json('[{"n":131,"total":8646}]');
INSERT INTO _assert SELECT 'UNION preserves bool list map and null values',
  json(cypher('CALL () { RETURN true AS b, [1, 2] AS xs, {n: 1} AS m, null AS z UNION ALL RETURN false AS b, [3] AS xs, {n: 2} AS m, null AS z } RETURN b, xs, m, z ORDER BY b DESC')) =
  json('[{"b":true,"xs":[1,2],"m":{"n":1},"z":null},{"b":false,"xs":[3],"m":{"n":2},"z":null}]');
SELECT name, ok FROM _assert;
