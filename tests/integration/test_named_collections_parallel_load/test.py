import pytest

from helpers.cluster import ClickHouseCluster

NAMED_COLLECTIONS_PATH = "/var/lib/clickhouse/named_collections"

NUM_COLLECTIONS = 500


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
            f"Loading {NUM_COLLECTIONS} named collections in 8 threads"
        )
        assert not sequential.contains_in_log("named collections in")

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
    """An unparsable metadata file fails the load the same way with and without the pool."""
    node = cluster.instances[instance_name]
    count = 20

    try:
        create_collections(node, count)
        node.stop_clickhouse()
        node.exec_in_container(
            [
                "bash",
                "-c",
                f"echo 'not a create query' > {NAMED_COLLECTIONS_PATH}/broken.sql",
            ],
            user="root",
        )

        node.start_clickhouse(expected_to_fail=True)
        assert node.contains_in_log("Syntax error")

        node.exec_in_container(
            ["bash", "-c", f"rm {NAMED_COLLECTIONS_PATH}/broken.sql"], user="root"
        )
        node.start_clickhouse()
        assert (
            node.query(
                "SELECT count() FROM system.named_collections WHERE source = 'SQL'"
            )
            == f"{count}\n"
        )
    finally:
        drop_collections(node, count)
