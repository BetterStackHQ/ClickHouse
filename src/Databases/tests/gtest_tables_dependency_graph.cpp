#include <Databases/TablesDependencyGraph.h>
#include <Interpreters/StorageID.h>

#include <gtest/gtest.h>

#include <random>

using namespace DB;

namespace
{

size_t countTables(const std::vector<std::vector<StorageID>> & split)
{
    size_t total = 0;
    for (const auto & level : split)
        total += level.size();
    return total;
}

using Replacements = std::vector<std::pair<StorageID, std::vector<StorageID>>>;

/// Replaces the dependencies of the specified tables with the specified sets, checks the whole graph for cyclic
/// dependencies, and reverts the replacements. This is what the catalog used to do for every DDL statement, and it is
/// the oracle `hasCyclicDependenciesAfterReplacing` must agree with.
bool hasCyclicDependenciesByApplying(TablesDependencyGraph & graph, const Replacements & replacements)
{
    /// The old dependencies are read before anything is changed, so that the replacements are reverted exactly
    /// even if the same table is replaced more than once.
    std::vector<std::vector<StorageID>> old_dependencies;
    old_dependencies.reserve(replacements.size());
    for (const auto & replacement : replacements)
        old_dependencies.push_back(graph.getDependencies(replacement.first));

    /// The dependencies of a table are always removed right before its new ones are added, because `addDependencies`
    /// logs a warning whenever it replaces a non-empty set of dependencies.
    for (const auto & replacement : replacements)
    {
        graph.removeDependencies(replacement.first);
        graph.addDependencies(replacement.first, replacement.second);
    }

    bool result = graph.hasCyclicDependencies();

    for (size_t i = 0; i != replacements.size(); ++i)
    {
        graph.removeDependencies(replacements[i].first);
        graph.addDependencies(replacements[i].first, old_dependencies[i]);
    }

    return result;
}

}

/// Regression test for https://github.com/ClickHouse/ClickHouse/issues/103746
///
/// Cyclic nodes get level == CYCLIC_LEVEL (std::numeric_limits<size_t>::max()).
/// The old getTablesSplitByDependencyLevel did resize(sorted_nodes.back()->level + 1),
/// which for a cyclic graph is resize(SIZE_MAX + 1) == resize(0), followed by an
/// out-of-bounds write tables_split_by_level[CYCLIC_LEVEL].emplace_back(...).
/// This aborted the server during RESTORE of backups with cyclic dependencies.
TEST(TablesDependencyGraph, SplitByDependencyLevelPureCycle)
{
    TablesDependencyGraph graph("test");

    StorageID a{"db", "a"};
    StorageID b{"db", "b"};

    /// A depends on B and B depends on A - a pure cycle.
    graph.addDependency(a, b);
    graph.addDependency(b, a);

    ASSERT_TRUE(graph.hasCyclicDependencies());

    /// Must not abort / write out of bounds.
    auto split = graph.getTablesSplitByDependencyLevel();

    /// Both cyclic tables must be present, in the trailing bucket.
    EXPECT_EQ(countTables(split), 2u);
    ASSERT_FALSE(split.empty());
    EXPECT_EQ(split.back().size(), 2u);
}

/// A mix of acyclic tables and a cycle: acyclic ordering by level must be
/// preserved, while cyclic tables are placed into the trailing bucket.
TEST(TablesDependencyGraph, SplitByDependencyLevelMixedCycle)
{
    TablesDependencyGraph graph("test");

    StorageID root{"db", "root"};   /// no dependencies -> level 0
    StorageID leaf{"db", "leaf"};   /// depends on root -> level 1
    StorageID c1{"db", "c1"};
    StorageID c2{"db", "c2"};

    graph.addDependency(leaf, root);

    /// A separate cycle c1 <-> c2.
    graph.addDependency(c1, c2);
    graph.addDependency(c2, c1);

    ASSERT_TRUE(graph.hasCyclicDependencies());

    auto split = graph.getTablesSplitByDependencyLevel();

    /// All four tables must be present.
    EXPECT_EQ(countTables(split), 4u);

    /// Levels 0 and 1 hold the acyclic tables; the trailing bucket holds the cycle.
    ASSERT_GE(split.size(), 3u);
    EXPECT_EQ(split[0].size(), 1u);
    EXPECT_EQ(split[0][0].getTableName(), "root");
    EXPECT_EQ(split[1].size(), 1u);
    EXPECT_EQ(split[1][0].getTableName(), "leaf");
    EXPECT_EQ(split.back().size(), 2u);
}

/// A dependency of a table on itself is a cycle, whether or not the table is in the graph yet.
TEST(TablesDependencyGraph, AfterReplacingSelfDependency)
{
    TablesDependencyGraph graph("test");

    StorageID a{"db", "a"};
    StorageID b{"db", "b"};
    graph.addDependency(a, b);

    StorageID new_table{"db", "new_table"};
    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing({{new_table, {new_table}}}));
    EXPECT_TRUE(hasCyclicDependenciesByApplying(graph, {{new_table, {new_table}}}));
    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing({{a, {a}}}));
    EXPECT_TRUE(hasCyclicDependenciesByApplying(graph, {{a, {a}}}));

    EXPECT_FALSE(graph.hasCyclicDependenciesAfterReplacing({{new_table, {a}}}));
    EXPECT_FALSE(hasCyclicDependenciesByApplying(graph, {{new_table, {a}}}));
    EXPECT_FALSE(graph.hasCyclicDependenciesAfterReplacing({{new_table, {}}}));
    EXPECT_FALSE(hasCyclicDependenciesByApplying(graph, {{new_table, {}}}));
}

/// Replacing the dependencies of a table closes a cycle of any length back to that table.
TEST(TablesDependencyGraph, AfterReplacingClosingACycle)
{
    TablesDependencyGraph graph("test");

    StorageID a{"db", "a"};
    StorageID b{"db", "b"};
    graph.addDependency(a, b);

    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing({{b, {a}}}));
    EXPECT_TRUE(hasCyclicDependenciesByApplying(graph, {{b, {a}}}));

    StorageID c{"db", "c"};
    StorageID d{"db", "d"};
    StorageID e{"db", "e"};
    graph.addDependency(b, c);
    graph.addDependency(c, d);
    graph.addDependency(d, e);

    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing({{e, {a}}}));
    EXPECT_TRUE(hasCyclicDependenciesByApplying(graph, {{e, {a}}}));

    /// A dependency along the existing direction closes nothing.
    EXPECT_FALSE(graph.hasCyclicDependenciesAfterReplacing({{a, {e}}}));
    EXPECT_FALSE(hasCyclicDependenciesByApplying(graph, {{a, {e}}}));
    EXPECT_FALSE(graph.hasCyclicDependenciesAfterReplacing({{e, {}}}));
    EXPECT_FALSE(hasCyclicDependenciesByApplying(graph, {{e, {}}}));
}

/// Exchanging two tables can create a cycle through the second table only.
TEST(TablesDependencyGraph, AfterReplacingExchange)
{
    TablesDependencyGraph graph("test");

    StorageID t1{"db", "t1"};
    StorageID t2{"db", "t2"};
    StorageID y{"db", "y"};

    /// "t1 -> y -> t2" is acyclic, but after the exchange "t2 -> y -> t2" is not.
    graph.addDependency(t1, y);
    graph.addDependency(y, t2);
    ASSERT_FALSE(graph.hasCyclicDependencies());

    Replacements exchange = {{t1, graph.getDependencies(t2)}, {t2, graph.getDependencies(t1)}};
    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing(exchange));
    EXPECT_TRUE(hasCyclicDependenciesByApplying(graph, exchange));

    /// An exchange of two tables with unrelated dependencies is accepted.
    StorageID u1{"db", "u1"};
    StorageID u2{"db", "u2"};
    graph.addDependency(u1, StorageID{"db", "source1"});
    graph.addDependency(u2, StorageID{"db", "source2"});

    Replacements unrelated_exchange = {{u1, graph.getDependencies(u2)}, {u2, graph.getDependencies(u1)}};
    EXPECT_FALSE(graph.hasCyclicDependenciesAfterReplacing(unrelated_exchange));
    EXPECT_FALSE(hasCyclicDependenciesByApplying(graph, unrelated_exchange));
}

/// Renaming a table moves its dependencies to the new name, which can close a cycle through that name.
TEST(TablesDependencyGraph, AfterReplacingRename)
{
    TablesDependencyGraph graph("test");

    StorageID from{"db", "from"};
    StorageID to{"db", "to"};
    StorageID x{"db", "x"};

    /// "from" depends on a table named "to" which does not exist yet, so the rename makes "to" depend on itself.
    graph.addDependency(from, to);
    Replacements rename_onto_own_dependency = {{from, {}}, {to, graph.getDependencies(from)}};
    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing(rename_onto_own_dependency));
    EXPECT_TRUE(hasCyclicDependenciesByApplying(graph, rename_onto_own_dependency));

    TablesDependencyGraph graph2("test");
    /// "x -> to" and "from -> x", so after the rename "to -> x -> to".
    graph2.addDependency(x, to);
    graph2.addDependency(from, x);
    ASSERT_FALSE(graph2.hasCyclicDependencies());

    Replacements rename_onto_dependent = {{from, {}}, {to, graph2.getDependencies(from)}};
    EXPECT_TRUE(graph2.hasCyclicDependenciesAfterReplacing(rename_onto_dependent));
    EXPECT_TRUE(hasCyclicDependenciesByApplying(graph2, rename_onto_dependent));

    /// Renaming to a name nothing depends on is accepted.
    Replacements rename_to_fresh_name = {{x, {}}, {StorageID{"db", "fresh"}, graph2.getDependencies(x)}};
    EXPECT_FALSE(graph2.hasCyclicDependenciesAfterReplacing(rename_to_fresh_name));
    EXPECT_FALSE(hasCyclicDependenciesByApplying(graph2, rename_to_fresh_name));
}

/// Replacing the dependencies of a table which has dependents - the "CREATE OR REPLACE VIEW" shape - is accepted
/// as long as the new dependencies do not lead back to it.
TEST(TablesDependencyGraph, AfterReplacingTableWithDependents)
{
    TablesDependencyGraph graph("test");

    StorageID mv{"db", "mv"};
    StorageID view{"db", "view"};
    StorageID source{"db", "source"};
    StorageID other_source{"db", "other_source"};

    graph.addDependency(mv, view);
    graph.addDependency(view, source);
    ASSERT_FALSE(graph.hasCyclicDependencies());

    EXPECT_FALSE(graph.hasCyclicDependenciesAfterReplacing({{view, {source}}}));
    EXPECT_FALSE(hasCyclicDependenciesByApplying(graph, {{view, {source}}}));
    EXPECT_FALSE(graph.hasCyclicDependenciesAfterReplacing({{view, {other_source}}}));
    EXPECT_FALSE(hasCyclicDependenciesByApplying(graph, {{view, {other_source}}}));
    EXPECT_FALSE(graph.hasCyclicDependenciesAfterReplacing({{view, {}}}));
    EXPECT_FALSE(hasCyclicDependenciesByApplying(graph, {{view, {}}}));

    /// A dependency on a table which is not in the graph leads nowhere.
    EXPECT_FALSE(graph.hasCyclicDependenciesAfterReplacing({{view, {StorageID{"db", "absent"}}}}));
    EXPECT_FALSE(hasCyclicDependenciesByApplying(graph, {{view, {StorageID{"db", "absent"}}}}));

    /// Depending on its own dependent is a cycle.
    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing({{view, {mv}}}));
    EXPECT_TRUE(hasCyclicDependenciesByApplying(graph, {{view, {mv}}}));
}

/// A table can be named by its UUID or by its qualified name, and both must resolve to the same node.
TEST(TablesDependencyGraph, AfterReplacingWithUUIDs)
{
    TablesDependencyGraph graph("test");

    UUID uuid_a = UUIDHelpers::generateV4();
    StorageID a_with_uuid{"db", "a", uuid_a};
    StorageID a_by_name{"db", "a"};
    StorageID b{"db", "b"};

    /// "b -> a", where "a" is in the graph with its UUID.
    graph.addDependency(b, a_with_uuid);

    /// The table whose dependencies are replaced is named without the UUID, and its new dependency by name.
    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing({{a_by_name, {b}}}));
    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing({{a_with_uuid, {b}}}));
    EXPECT_TRUE(hasCyclicDependenciesByApplying(graph, {{a_by_name, {b}}}));

    TablesDependencyGraph graph2("test");
    UUID uuid_b = UUIDHelpers::generateV4();
    StorageID b_with_uuid{"db", "b", uuid_b};

    /// The same the other way round: the new dependency is written with a UUID and the target by name.
    graph2.addDependency(b_with_uuid, a_by_name);
    EXPECT_TRUE(graph2.hasCyclicDependenciesAfterReplacing({{a_by_name, {b_with_uuid}}}));
    EXPECT_TRUE(hasCyclicDependenciesByApplying(graph2, {{a_by_name, {b_with_uuid}}}));

    /// A different UUID is a different table, so it is not in the graph and leads nowhere.
    StorageID b_with_other_uuid{"db", "b", UUIDHelpers::generateV4()};
    EXPECT_FALSE(graph2.hasCyclicDependenciesAfterReplacing({{StorageID{"db", "c"}, {b_with_other_uuid}}}));
}

/// If a table is specified more than once only the last set of dependencies takes effect, which is what applying
/// the replacements in order would leave. The catalog never does this, but the answer must still be the right one.
TEST(TablesDependencyGraph, AfterReplacingTheSameTableTwice)
{
    TablesDependencyGraph graph("test");

    StorageID a{"db", "a"};
    StorageID b{"db", "b"};
    graph.addDependency(a, b);

    /// The second set makes "a" depend on itself, the first one alone would not.
    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing({{a, {}}, {a, {a}}}));
    EXPECT_TRUE(hasCyclicDependenciesByApplying(graph, {{a, {}}, {a, {a}}}));

    /// The other way round the last set wins as well, so there is no cycle.
    EXPECT_FALSE(graph.hasCyclicDependenciesAfterReplacing({{a, {a}}, {a, {}}}));
    EXPECT_FALSE(hasCyclicDependenciesByApplying(graph, {{a, {a}}, {a, {}}}));

    /// The same for a table which is not in the graph.
    StorageID fresh{"db", "fresh"};
    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing({{fresh, {}}, {fresh, {fresh}}}));
    EXPECT_FALSE(graph.hasCyclicDependenciesAfterReplacing({{fresh, {fresh}}, {fresh, {}}}));

    /// A table named by its UUID in one entry and by its name in another is still the same table.
    UUID uuid = UUIDHelpers::generateV4();
    StorageID c_with_uuid{"db", "c", uuid};
    StorageID c_by_name{"db", "c"};
    graph.addDependency(c_with_uuid, b);
    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing({{c_with_uuid, {}}, {c_by_name, {c_by_name}}}));
    EXPECT_TRUE(hasCyclicDependenciesByApplying(graph, {{c_with_uuid, {}}, {c_by_name, {c_by_name}}}));
}

/// The check must leave the graph exactly as it was: in particular it must not add the tables it is asked about,
/// unlike replacing the dependencies and reverting them, which leaves the added nodes behind.
TEST(TablesDependencyGraph, AfterReplacingDoesNotChangeTheGraph)
{
    TablesDependencyGraph graph("test");

    StorageID a{"db", "a"};
    StorageID b{"db", "b"};
    StorageID c{"db", "c"};
    graph.addDependency(a, b);
    graph.addDependency(b, c);

    auto sorted_before = graph.getTablesSortedByDependency();

    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing({{c, {a}}}));
    /// Neither the table whose dependencies are replaced nor its new dependency is in the graph.
    EXPECT_FALSE(graph.hasCyclicDependenciesAfterReplacing({{StorageID{"db", "absent"}, {StorageID{"db", "unknown"}}}}));

    EXPECT_EQ(graph.getNumberOfTables(), 3u);
    EXPECT_EQ(graph.getTablesSortedByDependency(), sorted_before);
    EXPECT_FALSE(graph.hasCyclicDependencies());
}

/// A cycle which does not go through the tables being changed is not reported. This is deliberately narrower than
/// `hasCyclicDependencies`, which reports any cycle in the graph and so rejects unrelated statements as well.
/// Such a cycle can only come from metadata written by a server which did not perform these checks.
TEST(TablesDependencyGraph, AfterReplacingWithPreExistingUnrelatedCycle)
{
    TablesDependencyGraph graph("test");

    StorageID c1{"db", "c1"};
    StorageID c2{"db", "c2"};
    StorageID a{"db", "a"};
    StorageID b{"db", "b"};

    graph.addDependency(c1, c2);
    graph.addDependency(c2, c1);
    graph.addDependency(a, b);

    ASSERT_TRUE(graph.hasCyclicDependencies());

    EXPECT_TRUE(hasCyclicDependenciesByApplying(graph, {{b, {}}}));
    EXPECT_FALSE(graph.hasCyclicDependenciesAfterReplacing({{b, {}}}));

    /// A cycle through the changed table is still reported.
    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing({{b, {a}}}));

    /// The search walks into the pre-existing cycle when a new dependency leads to it, and must terminate there.
    StorageID d{"db", "d"};
    graph.addDependency(b, c1);
    EXPECT_FALSE(graph.hasCyclicDependenciesAfterReplacing({{d, {b}}}));
    EXPECT_TRUE(hasCyclicDependenciesByApplying(graph, {{d, {b}}}));

    /// Walking through the pre-existing cycle does not hide a cycle through the changed table: "c2 -> a -> b -> c1 -> c2".
    EXPECT_TRUE(graph.hasCyclicDependenciesAfterReplacing({{c2, {a}}}));
}

namespace
{

/// Returns the same table named without its UUID half of the time, so that both ways of naming a table are exercised.
StorageID nameSometimesWithoutUUID(std::mt19937_64 & random, const StorageID & table_id)
{
    if (table_id.hasUUID() && (random() % 2))
        return StorageID{table_id.database_name, table_id.table_name};
    return table_id;
}

String describeReplacements(const Replacements & replacements)
{
    String res;
    for (const auto & replacement : replacements)
    {
        if (!res.empty())
            res += "; ";
        res += replacement.first.getNameForLogs();
        res += " -> [";
        for (size_t i = 0; i != replacement.second.size(); ++i)
        {
            if (i)
                res += ", ";
            res += replacement.second[i].getNameForLogs();
        }
        res += "]";
    }
    return res;
}

/// Fills the graph with a random acyclic set of dependencies. A dependency always goes to a table with a smaller index,
/// so the graph is acyclic by construction. Roughly half of the tables get a UUID, and some dependencies are on tables
/// which are not in the graph otherwise.
void makeRandomAcyclicGraph(std::mt19937_64 & random, size_t num_tables, TablesDependencyGraph & graph, std::vector<StorageID> & table_ids)
{
    for (size_t i = 0; i != num_tables; ++i)
    {
        String name = "t" + std::to_string(i);
        if (random() % 2)
            table_ids.emplace_back("db", name, UUIDHelpers::generateV4());
        else
            table_ids.emplace_back("db", name);
    }

    for (size_t i = 0; i != num_tables; ++i)
    {
        /// A table can be put into the graph by its name only and re-keyed with its UUID when it is added by its full
        /// identifier later, which is what happens when a table is created after something already depends on it.
        if (table_ids[i].hasUUID() && (random() % 2))
            graph.addDependencies(StorageID{table_ids[i].database_name, table_ids[i].table_name}, std::vector<StorageID>{});

        std::vector<StorageID> dependencies;
        size_t num_dependencies = random() % 4;
        for (size_t j = 0; j != num_dependencies; ++j)
        {
            if ((i == 0) || (random() % 8 == 0))
                dependencies.emplace_back("db", "unreferenced" + std::to_string(random() % 8));
            else
                dependencies.push_back(nameSometimesWithoutUUID(random, table_ids[random() % i]));
        }
        graph.addDependencies(table_ids[i], dependencies);
    }
}

}

/// The bounded check must give the same answer as replacing the dependencies, sorting the whole graph and reverting,
/// for every shape of change the catalog makes. The graph and the edits are seeded, so that a failure is reproducible
/// (the generated UUID values differ between runs, but the answers do not depend on them).
TEST(TablesDependencyGraph, AfterReplacingMatchesTheFullCheck)
{
    for (size_t num_tables : {20, 60, 200})
    {
        const uint64_t seed = 20260908 + num_tables;
        std::mt19937_64 random{seed};

        TablesDependencyGraph graph("test");
        std::vector<StorageID> table_ids;
        makeRandomAcyclicGraph(random, num_tables, graph, table_ids);
        ASSERT_FALSE(graph.hasCyclicDependencies()) << "seed " << seed;

        for (size_t iteration = 0; iteration != 800; ++iteration)
        {
            Replacements replacements;

            switch (iteration % 4)
            {
                case 0:
                {
                    /// Replace the dependencies of one table, which is sometimes not in the graph yet.
                    StorageID table_id = (random() % 4 == 0)
                        ? StorageID{"db", "created" + std::to_string(iteration)}
                        : nameSometimesWithoutUUID(random, table_ids[random() % num_tables]);

                    std::vector<StorageID> new_dependencies;
                    size_t num_dependencies = random() % 4;
                    for (size_t j = 0; j != num_dependencies; ++j)
                    {
                        if (random() % 8 == 0)
                            new_dependencies.emplace_back("db", "unknown" + std::to_string(iteration));
                        else
                            new_dependencies.push_back(nameSometimesWithoutUUID(random, table_ids[random() % num_tables]));
                    }
                    replacements.emplace_back(table_id, std::move(new_dependencies));
                    break;
                }
                case 1:
                {
                    /// Move the dependencies of one table to another name, which is sometimes already in the graph.
                    size_t from_index = random() % num_tables;
                    StorageID from_table_id = nameSometimesWithoutUUID(random, table_ids[from_index]);

                    size_t to_index = random() % num_tables;
                    StorageID to_table_id = (random() % 2)
                        ? StorageID{"db", "renamed" + std::to_string(iteration)}
                        : nameSometimesWithoutUUID(random, table_ids[to_index]);

                    replacements.emplace_back(from_table_id, std::vector<StorageID>{});
                    replacements.emplace_back(to_table_id, graph.getDependencies(from_table_id));
                    break;
                }
                case 2:
                {
                    /// Swap the dependencies of two tables, which are occasionally the same table.
                    StorageID table_id_1 = nameSometimesWithoutUUID(random, table_ids[random() % num_tables]);
                    StorageID table_id_2 = nameSometimesWithoutUUID(random, table_ids[random() % num_tables]);

                    replacements.emplace_back(table_id_1, graph.getDependencies(table_id_2));
                    replacements.emplace_back(table_id_2, graph.getDependencies(table_id_1));
                    break;
                }
                default:
                {
                    /// Replace the dependencies of one table twice, spelled differently each time. The catalog never
                    /// does this, but the last set must be the one which takes effect.
                    size_t index = random() % num_tables;

                    std::vector<std::vector<StorageID>> new_dependencies(2);
                    for (auto & dependencies : new_dependencies)
                    {
                        size_t num_dependencies = random() % 3;
                        for (size_t j = 0; j != num_dependencies; ++j)
                            dependencies.push_back(nameSometimesWithoutUUID(random, table_ids[random() % num_tables]));
                    }

                    for (auto & dependencies : new_dependencies)
                        replacements.emplace_back(nameSometimesWithoutUUID(random, table_ids[index]), std::move(dependencies));
                    break;
                }
            }

            bool bounded_check = graph.hasCyclicDependenciesAfterReplacing(replacements);
            bool full_check = hasCyclicDependenciesByApplying(graph, replacements);
            ASSERT_EQ(bounded_check, full_check)
                << "seed " << seed << ", iteration " << iteration << ", replacements: " << describeReplacements(replacements);

            /// Reverting the replacements must leave the graph acyclic, otherwise the next iteration tests nothing.
            ASSERT_FALSE(graph.hasCyclicDependencies()) << "seed " << seed << ", iteration " << iteration;
        }
    }
}
