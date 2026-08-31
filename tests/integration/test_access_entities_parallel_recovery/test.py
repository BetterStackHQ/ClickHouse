import pytest

from helpers.cluster import ClickHouseCluster

ACCESS_PATH = "/var/lib/clickhouse/access"

MARK_PATH = f"{ACCESS_PATH}/need_rebuild_lists.mark"

NUM_USERS = 200

NUM_THREADS = 8


@pytest.fixture(scope="module")
def cluster():
    try:
        cluster = ClickHouseCluster(__file__)
        cluster.add_instance(
            "node_parallel",
            main_configs=["configs/config.d/parallel_recovery.xml"],
            stay_alive=True,
        )
        cluster.add_instance(
            "node_sequential",
            main_configs=["configs/config.d/sequential_recovery.xml"],
            stay_alive=True,
        )
        cluster.start()
        yield cluster
    finally:
        cluster.shutdown()


def create_users(node, count, batch_size=50):
    for begin in range(0, count, batch_size):
        batch = range(begin, min(begin + batch_size, count))
        node.query(
            ";".join(
                f"CREATE USER user_{i} IDENTIFIED BY 'password_{i}' "
                f"SETTINGS max_threads = {1 + i % 8}"
                for i in batch
            )
        )
        node.query(
            ";".join(f"GRANT SELECT ON db.table_{i % 7} TO user_{i}" for i in batch)
        )


def drop_users(node, count, batch_size=50):
    for begin in range(0, count, batch_size):
        node.query(
            ";".join(
                f"DROP USER IF EXISTS user_{i}"
                for i in range(begin, min(begin + batch_size, count))
            )
        )


def dump_access(node):
    return node.query(
        "SELECT name FROM system.users WHERE storage = 'local_directory' ORDER BY name"
    ) + node.query(
        "SELECT user_name, access_type, database, table FROM system.grants "
        "WHERE user_name LIKE 'user\\_%' ORDER BY user_name, database, table"
    )


def mark_lists_for_rebuild(node):
    node.exec_in_container(["bash", "-c", f"touch {MARK_PATH}"], user="root")


def mark_exists(node):
    result = node.exec_in_container(
        ["bash", "-c", f"test -e {MARK_PATH} && echo yes || echo no"], user="root"
    )
    return result.strip() == "yes"


@pytest.mark.parametrize(
    "instance_name,expected_log",
    [
        (
            "node_parallel",
            f"Reading {NUM_USERS} access entity files in {NUM_THREADS} threads",
        ),
        ("node_sequential", f"Reading {NUM_USERS} access entity files sequentially"),
    ],
)
def test_recovery_rebuilds_every_entity(cluster, instance_name, expected_log):
    """Rebuilding the `.list` files finds every entity with and without the pool."""
    node = cluster.instances[instance_name]

    try:
        create_users(node, NUM_USERS)
        expected = dump_access(node)

        # A clean shutdown writes the `.list` files and drops the mark, so plant it afterwards
        # to get the recovery a server killed mid-write would run on the next start.
        node.rotate_logs()
        node.stop_clickhouse()
        mark_lists_for_rebuild(node)
        node.start_clickhouse()

        assert expected_log in node.grep_in_log("access entity files", only_latest=True)
        assert dump_access(node) == expected
        assert not mark_exists(node)
    finally:
        drop_users(node, NUM_USERS)
