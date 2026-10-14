#!/usr/bin/env bash

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

# The dependency graph describes itself only when a trace message would be written.
# A client which asked for trace logs must still receive the description even when
# the server's own logging level is higher.

CLICKHOUSE_CLIENT_TRACE=${CLICKHOUSE_CLIENT/"--send_logs_level=${CLICKHOUSE_CLIENT_SERVER_LOGS_LEVEL}"/"--send_logs_level=trace"}
CLICKHOUSE_CLIENT_WARNING=${CLICKHOUSE_CLIENT/"--send_logs_level=${CLICKHOUSE_CLIENT_SERVER_LOGS_LEVEL}"/"--send_logs_level=warning"}

$CLICKHOUSE_CLIENT --query "CREATE TABLE dep_src (x UInt64) ENGINE = Null"
$CLICKHOUSE_CLIENT --query "CREATE TABLE dep_dst (x UInt64) ENGINE = MergeTree ORDER BY x"

logs=$($CLICKHOUSE_CLIENT_TRACE \
    --query "CREATE MATERIALIZED VIEW dep_mv TO dep_dst AS SELECT x FROM dep_src" 2>&1 >/dev/null)
if echo "$logs" | grep -qF "ViewDeps: Table ${CLICKHOUSE_DATABASE}.dep_src"; then
    echo "trace requested: described"
else
    echo "trace requested: missing"
fi

$CLICKHOUSE_CLIENT --query "DROP TABLE dep_mv"

logs=$($CLICKHOUSE_CLIENT_WARNING \
    --query "CREATE MATERIALIZED VIEW dep_mv TO dep_dst AS SELECT x FROM dep_src" 2>&1 >/dev/null)
if echo "$logs" | grep -qF "ViewDeps: Table"; then
    echo "trace not requested: described"
else
    echo "trace not requested: silent"
fi

$CLICKHOUSE_CLIENT --query "DROP TABLE dep_mv"
$CLICKHOUSE_CLIENT --query "DROP TABLE dep_dst"
$CLICKHOUSE_CLIENT --query "DROP TABLE dep_src"
