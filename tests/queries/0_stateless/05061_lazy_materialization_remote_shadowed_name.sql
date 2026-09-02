-- Lazy materialization over a distributed read inside a subquery, ordered by a column the inner
-- select projects under the same name it reads it by. Splitting the filter DAG for the lazy
-- half renames the shadowed input (`dt` -> `dt_0`), and the main branch then failed to find `dt`
-- (NOT_FOUND_COLUMN_IN_BLOCK). The optimization must skip such plans. Read-in-order is off so
-- that the plan is the one production reaches when the ordering column is not the leading key.

DROP TABLE IF EXISTS lm_remote_base;
DROP VIEW IF EXISTS lm_remote_view;

CREATE TABLE lm_remote_base (dt DateTime64(6, 'UTC'), idx UInt32, raw String, kind UInt8)
    ENGINE = MergeTree ORDER BY (kind, dt, idx);
INSERT INTO lm_remote_base SELECT toDateTime64('2026-01-01 00:00:00', 6) + number, number, repeat('x', 200), 1 FROM numbers(5000);
CREATE VIEW lm_remote_view AS SELECT * EXCEPT kind FROM lm_remote_base WHERE kind = 1;

SET optimize_read_in_order = 0;
SET query_plan_optimize_lazy_materialization = 1, query_plan_max_limit_for_lazy_materialization = 10000;

SELECT dt, length(raw) FROM (
    SELECT dt, raw FROM remote('127.0.0.1', currentDatabase(), lm_remote_view)
    WHERE dt > toDateTime64('2026-01-01 00:00:20', 6)
) ORDER BY dt ASC LIMIT 3;

SELECT count() FROM (
    SELECT * FROM (
        SELECT dt, raw FROM remote('127.0.0.1', currentDatabase(), lm_remote_view)
        WHERE dt > toDateTime64('2026-01-01 00:00:20', 6)
    ) ORDER BY dt ASC LIMIT 1000
);

DROP VIEW lm_remote_view;
DROP TABLE lm_remote_base;
