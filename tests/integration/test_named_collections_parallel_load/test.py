import shlex

import pytest

from helpers.cluster import ClickHouseCluster

NAMED_COLLECTIONS_PATH = "/var/lib/clickhouse/named_collections"

NUM_COLLECTIONS = 500

NUM_THREADS = 8


@pytest.fixture(scope="module")
def cluster():
    try:
        cluster = ClickHouseCluster(__file__)
        cluster.add_instance(
            "node_parallel",
            main_configs=["configs/config.d/parallel_load.xml"],
            user_configs=["configs/users.d/users.xml"],
            stay_alive=True,
        )
        cluster.add_instance(
            "node_sequential",
            main_configs=["configs/config.d/sequential_load.xml"],
            user_configs=["configs/users.d/users.xml"],
            stay_alive=True,
        )
        cluster.start()
        yield cluster
    finally:
        cluster.shutdown()


def run_in_batches(node, queries, batch_size=100):
    for begin in range(0, len(queries), batch_size):
        node.query(";".join(queries[begin : begin + batch_size]))


def create_collections(node, count):
    run_in_batches(
        node,
        [
            f"CREATE NAMED COLLECTION collection_{i} AS "
            f"key1 = 'value_{i}', key2 = {i} OVERRIDABLE, key3 = 'shared'"
            for i in range(count)
        ],
    )


def drop_collections(node, count):
    run_in_batches(
        node,
        [f"DROP NAMED COLLECTION IF EXISTS collection_{i}" for i in range(count)],
    )


def dump_collections(node):
    return node.query(
        "SELECT name, collection, create_query FROM system.named_collections "
        "WHERE source = 'SQL' ORDER BY name"
    )


def write_file(node, file_name, content):
    path = shlex.quote(f"{NAMED_COLLECTIONS_PATH}/{file_name}")
    node.exec_in_container(
        ["bash", "-c", f"echo {shlex.quote(content)} > {path}"], user="root"
    )


def remove_file(node, file_name):
    path = shlex.quote(f"{NAMED_COLLECTIONS_PATH}/{file_name}")
    node.exec_in_container(["bash", "-c", f"rm -f {path}"], user="root")


def restart_if_stopped(node):
    if node.get_process_pid("clickhouse") is None:
        node.start_clickhouse()


def test_parallel_load(cluster):
    """The collections loaded by the thread pool are the ones loaded sequentially."""
    parallel = cluster.instances["node_parallel"]
    sequential = cluster.instances["node_sequential"]
    nodes = [parallel, sequential]

    try:
        for node in nodes:
            create_collections(node, NUM_COLLECTIONS)

        expected = dump_collections(sequential)
        assert dump_collections(parallel) == expected

        for node in nodes:
            node.restart_clickhouse()

        for node in nodes:
            assert dump_collections(node) == expected
            assert (
                node.query(
                    "SELECT count() FROM system.named_collections WHERE source = 'SQL'"
                )
                == f"{NUM_COLLECTIONS}\n"
            )

        assert parallel.contains_in_log(
            f"Loading {NUM_COLLECTIONS} named collections in {NUM_THREADS} threads"
        )
        assert sequential.contains_in_log(
            f"Loading {NUM_COLLECTIONS} named collections sequentially"
        )

        # The collections are usable and modifiable after a parallel load.
        parallel.query("ALTER NAMED COLLECTION collection_0 SET key1 = 'updated'")
        assert (
            parallel.query(
                "SELECT collection['key1'] FROM system.named_collections "
                "WHERE name = 'collection_0'"
            )
            == "updated\n"
        )
        parallel.query("CREATE NAMED COLLECTION collection_extra AS key1 = 'extra'")
        parallel.query("DROP NAMED COLLECTION collection_extra")
    finally:
        for node in nodes:
            drop_collections(node, NUM_COLLECTIONS)
            node.query("DROP NAMED COLLECTION IF EXISTS collection_extra")


@pytest.mark.parametrize("instance_name", ["node_parallel", "node_sequential"])
def test_unparsable_collection_aborts_startup(cluster, instance_name):
    """An unparsable metadata file fails the load with and without the pool."""
    node = cluster.instances[instance_name]
    count = 20

    try:
        create_collections(node, count)
        # Rotate before the failing start so that the grep below sees only this start.
        node.rotate_logs()
        node.stop_clickhouse()
        write_file(node, "broken.sql", "not a create query")

        # `start_clickhouse` only observes that the process is gone, which a server
        # that has not forked yet also satisfies, so the log is what proves the load
        # actually failed.
        node.start_clickhouse(expected_to_fail=True)
        assert node.get_process_pid("clickhouse") is None
        assert "Syntax error (in file broken.sql)" in node.grep_in_log(
            "Syntax error", only_latest=True
        )

        remove_file(node, "broken.sql")
        node.start_clickhouse()
        assert (
            node.query(
                "SELECT count() FROM system.named_collections WHERE source = 'SQL'"
            )
            == f"{count}\n"
        )
    finally:
        remove_file(node, "broken.sql")
        restart_if_stopped(node)
        drop_collections(node, count)


@pytest.mark.parametrize("instance_name", ["node_parallel", "node_sequential"])
def test_duplicate_collection_name_aborts_startup(cluster, instance_name):
    """Two files naming one collection fail the load with and without the pool."""
    node = cluster.instances[instance_name]

    try:
        # `a.sql` and `%61.sql` both unescape to the collection name `a`.
        node.rotate_logs()
        node.stop_clickhouse()
        write_file(node, "a.sql", "CREATE NAMED COLLECTION a AS key1 = 'one'")
        write_file(node, "%61.sql", "CREATE NAMED COLLECTION a AS key1 = 'two'")

        # Nothing else on disk can fail, so both modes report the duplicate. Which
        # error wins is unspecified only when a duplicate and some other bad file are
        # present at the same time.
        node.start_clickhouse(expected_to_fail=True)
        assert node.get_process_pid("clickhouse") is None
        assert "Found duplicate named collection `a`" in node.grep_in_log(
            "Found duplicate named collection", only_latest=True
        )

        remove_file(node, "%61.sql")
        node.start_clickhouse()
        assert (
            node.query(
                "SELECT count() FROM system.named_collections WHERE source = 'SQL'"
            )
            == "1\n"
        )
    finally:
        remove_file(node, "%61.sql")
        restart_if_stopped(node)
        node.query("DROP NAMED COLLECTION IF EXISTS a")
