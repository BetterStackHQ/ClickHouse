-- The materialized view select plan cache is rebuilt when the view query or the
-- structure of the involved tables changes, and results stay correct.

DROP TABLE IF EXISTS t_mvpci_src;
DROP TABLE IF EXISTS t_mvpci_dst;
DROP VIEW IF EXISTS t_mvpci_mv;

CREATE TABLE t_mvpci_src (k UInt64, v UInt64) ENGINE = MergeTree ORDER BY k;
CREATE TABLE t_mvpci_dst (k UInt64, v UInt64) ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW t_mvpci_mv TO t_mvpci_dst AS SELECT k, v FROM t_mvpci_src;

SET use_materialized_view_select_plan_cache = 1;

INSERT INTO t_mvpci_src VALUES (1, 10);
INSERT INTO t_mvpci_src VALUES (2, 20);

-- `MODIFY QUERY`: the cached plan must not survive.
ALTER TABLE t_mvpci_mv MODIFY QUERY SELECT k, v * 100 AS v FROM t_mvpci_src;
INSERT INTO t_mvpci_src VALUES (3, 30);
INSERT INTO t_mvpci_src VALUES (4, 40);

SELECT k, v FROM t_mvpci_dst ORDER BY k;

-- Source structure change: a column added with a default participates correctly.
ALTER TABLE t_mvpci_src ADD COLUMN extra UInt64 DEFAULT 7;
ALTER TABLE t_mvpci_dst ADD COLUMN extra UInt64 DEFAULT 0;
ALTER TABLE t_mvpci_mv MODIFY QUERY SELECT k, v * 100 AS v, extra FROM t_mvpci_src;
INSERT INTO t_mvpci_src VALUES (5, 50, 5);
INSERT INTO t_mvpci_src (k, v) VALUES (6, 60);

SELECT k, v, extra FROM t_mvpci_dst WHERE k >= 5 ORDER BY k;

-- `DROP`/`CREATE` of the view starts a fresh cache under the new UUID.
DROP VIEW t_mvpci_mv;
CREATE MATERIALIZED VIEW t_mvpci_mv TO t_mvpci_dst AS SELECT k, v, extra FROM t_mvpci_src;
INSERT INTO t_mvpci_src VALUES (7, 70, 3);
SELECT k, v, extra FROM t_mvpci_dst WHERE k = 7;

-- Different input headers (column-subset inserts) are distinct cache variants.
INSERT INTO t_mvpci_src (k) VALUES (8);
SELECT k, v, extra FROM t_mvpci_dst WHERE k = 8;

-- A metadata change on the target table alone also invalidates.
ALTER TABLE t_mvpci_dst MODIFY COLUMN extra UInt64 DEFAULT 1;
INSERT INTO t_mvpci_src VALUES (9, 90, 4);
SELECT k, v, extra FROM t_mvpci_dst WHERE k = 9;
SYSTEM FLUSH LOGS query_views_log;
SELECT sum(ProfileEvents['MaterializedViewSelectPlanCacheRebuilds']) >= 1 AS rebuilt
FROM system.query_views_log
WHERE view_name = currentDatabase() || '.t_mvpci_mv';

DROP VIEW t_mvpci_mv;
DROP TABLE t_mvpci_src;
DROP TABLE t_mvpci_dst;
