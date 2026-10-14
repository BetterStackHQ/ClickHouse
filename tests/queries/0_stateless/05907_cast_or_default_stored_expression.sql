-- accurateCastOrDefault and the to*OrDefault functions resolved their inner cast on every execution
-- through a resolver that holds the query context weakly. Stored expressions outlive that context
-- (column defaults are evaluated by later inserts, a sorting key by merges) and failed with
-- "Context has expired". The cast must not consult the query context when it is built or executed.

-- The expiring context exists only on the analyzer paths of the default and mutation evaluation.
SET enable_analyzer = 1;

DROP TABLE IF EXISTS t_cast_or_default_stored;

CREATE TABLE t_cast_or_default_stored
(
    s String,
    x UInt32,
    lc LowCardinality(String) DEFAULT s,
    ns Nullable(String) DEFAULT if(s = '', NULL, s),
    m UInt32 MATERIALIZED accurateCastOrDefault(s, 'UInt32'),
    d UInt32 DEFAULT toUInt32OrDefault(s, 7::UInt32),
    dt DateTime64(3, 'UTC') MATERIALIZED toDateTime64OrDefault(s, 3, 'UTC'),
    dec Decimal(18, 2) MATERIALIZED toDecimal64OrDefault(s, 2),
    lc_n UInt32 MATERIALIZED accurateCastOrDefault(lc, 'UInt32'),
    ns_n Nullable(UInt32) MATERIALIZED accurateCastOrDefault(ns, 'Nullable(UInt32)'),
    x_def UInt32 MATERIALIZED toUInt32OrDefault(s, x)
)
ENGINE = MergeTree ORDER BY x;

-- A multi-row block with a date only the best-effort parser accepts, and a single-row async insert.
INSERT INTO t_cast_or_default_stored (s, x) VALUES ('42', 1), ('not a number', 2), ('2024-01-02 03:04:05.678', 3), ('', 0), ('26 Jul 2024 11:00:00', 7);
INSERT INTO t_cast_or_default_stored (s, x) SETTINGS async_insert = 1, wait_for_async_insert = 1 VALUES ('25 Jul 2024 10:00:00', 4);

SELECT x, s, m, d, dt, dec, lc_n, ns_n, x_def FROM t_cast_or_default_stored ORDER BY x;

-- The stored expressions agree with the same functions evaluated by a fresh query.
SELECT count()
FROM t_cast_or_default_stored
WHERE m != accurateCastOrDefault(s, 'UInt32')
    OR d != toUInt32OrDefault(s, 7::UInt32)
    OR dt != toDateTime64OrDefault(s, 3, 'UTC')
    OR dec != toDecimal64OrDefault(s, 2)
    OR lc_n != accurateCastOrDefault(lc, 'UInt32')
    OR ns_n IS DISTINCT FROM accurateCastOrDefault(ns, 'Nullable(UInt32)')
    OR x_def != toUInt32OrDefault(s, x);

-- Defaults added by ALTER are built with the ALTER's query context.
ALTER TABLE t_cast_or_default_stored ADD COLUMN m2 Nullable(String) MATERIALIZED accurateCastOrDefault(s, 'Nullable(String)');
INSERT INTO t_cast_or_default_stored (s, x) VALUES ('after alter', 5);
SELECT x, s, m, m2 FROM t_cast_or_default_stored WHERE x >= 4 ORDER BY x;

-- A sorting key modified by ALTER is re-evaluated by merges.
ALTER TABLE t_cast_or_default_stored ADD COLUMN y String, MODIFY ORDER BY (x, accurateCastOrDefault(y, 'UInt32'));
INSERT INTO t_cast_or_default_stored (s, x, y) VALUES ('6', 6, '6');
OPTIMIZE TABLE t_cast_or_default_stored FINAL;
SELECT count() FROM t_cast_or_default_stored;
SELECT count() FROM system.parts WHERE database = currentDatabase() AND table = 't_cast_or_default_stored' AND active;

DROP TABLE t_cast_or_default_stored;
