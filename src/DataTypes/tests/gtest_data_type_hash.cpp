#include <DataTypes/DataTypeArray.h>
#include <DataTypes/DataTypeCustom.h>
#include <DataTypes/DataTypeFactory.h>
#include <DataTypes/DataTypeNullable.h>
#include <DataTypes/DataTypeString.h>
#include <DataTypes/DataTypeTuple.h>
#include <DataTypes/DataTypesNumber.h>
#include <DataTypes/IDataType.h>
#include <Common/SipHash.h>

#include <gtest/gtest.h>

#include <thread>
#include <vector>

using namespace DB;

namespace
{

DataTypePtr type(const String & name)
{
    return DataTypeFactory::instance().get(name);
}

/// The digest `getHash` must return: the bytes `updateHash` fed before the digest was cached.
UInt128 legacyDigest(const DataTypePtr & t)
{
    SipHash hash;
    if (t->hasCustomName())
    {
        hash.update(t->getCustomName()->getName().size());
        hash.update(t->getCustomName()->getName());
    }
    else
        hash.update(size_t(0));
    hash.update(t->getTypeId());
    t->updateHashImpl(hash);
    return hash.get128();
}

UInt128 viaUpdateHash(const DataTypePtr & t)
{
    SipHash hash;
    t->updateHash(hash);
    return hash.get128();
}

}

TEST(DataTypeHash, SameObjectIsStable)
{
    auto t = type("Tuple(a String, b Array(Nullable(UInt8)), c Map(String, DateTime64(3, 'UTC')))");
    EXPECT_EQ(t->getHash(), t->getHash());
    EXPECT_EQ(viaUpdateHash(t), viaUpdateHash(t));
}

TEST(DataTypeHash, StructurallyEqualObjectsAreEqual)
{
    auto a = type("Tuple(a String, b Array(Nullable(UInt8)))");
    auto b = type("Tuple(a String, b Array(Nullable(UInt8)))");
    EXPECT_NE(a.get(), b.get());
    EXPECT_EQ(a->getHash(), b->getHash());

    auto hand_built = std::make_shared<DataTypeTuple>(
        DataTypes{std::make_shared<DataTypeString>(), std::make_shared<DataTypeArray>(makeNullable(std::make_shared<DataTypeUInt8>()))},
        Strings{"a", "b"});
    EXPECT_EQ(a->getHash(), hand_built->getHash());
}

TEST(DataTypeHash, DifferentTypesDiffer)
{
    std::vector<std::pair<String, String>> pairs = {
        {"Tuple(a String)", "Tuple(b String)"},
        {"Tuple(a String)", "Tuple(String)"},
        {"Tuple(a String, b UInt8)", "Tuple(b UInt8, a String)"},
        {"String", "Nullable(String)"},
        {"String", "LowCardinality(String)"},
        {"Array(UInt8)", "Array(UInt16)"},
        {"Map(String, UInt8)", "Array(Tuple(String, UInt8))"},
        {"Decimal(10, 2)", "Decimal(10, 3)"},
        {"DateTime64(3)", "DateTime64(6)"},
        {"Enum8('a' = 1)", "Enum8('a' = 2)"},
        {"Enum8('a' = 1)", "Enum16('a' = 1)"},
        {"FixedString(4)", "FixedString(5)"},
        {"AggregateFunction(uniq, String)", "AggregateFunction(uniq, UInt64)"},
        {"AggregateFunction(quantile(0.5), UInt64)", "AggregateFunction(quantile(0.9), UInt64)"},
        {"SimpleAggregateFunction(max, UInt64)", "UInt64"},
        {"IPv4", "UInt32"},
    };
    for (const auto & [lhs, rhs] : pairs)
        EXPECT_NE(type(lhs)->getHash(), type(rhs)->getHash()) << lhs << " vs " << rhs;
}

TEST(DataTypeHash, DateTime64TimeZoneIsNotPartOfTheHash)
{
    /// equals() ignores the time zone of DateTime64, and the hash is consistent with equality.
    EXPECT_EQ(type("DateTime64(3, 'UTC')")->getHash(), type("DateTime64(3, 'Europe/Prague')")->getHash());
}

TEST(DataTypeHash, DigestMatchesTheBytesUpdateHashFeeds)
{
    for (const auto & name : {"UInt8", "String", "Nullable(String)", "LowCardinality(Nullable(String))",
                              "Tuple(a String, b Array(Tuple(c UInt8, d Map(String, String))))",
                              "DateTime64(3, 'UTC')", "AggregateFunction(uniq, String)", "SimpleAggregateFunction(max, UInt64)",
                              "IPv4", "Enum8('a' = 1, 'b' = 2)", "JSON(max_dynamic_paths = 8, a.b UInt32)", "Dynamic", "Variant(String, UInt8)"})
    {
        auto t = type(name);
        EXPECT_EQ(t->getHash(), legacyDigest(t)) << name;
        EXPECT_EQ(viaUpdateHash(t), legacyDigest(t)) << name;
        /// The cached path returns the same digest.
        EXPECT_EQ(t->getHash(), legacyDigest(t)) << name;
    }
}

TEST(DataTypeHash, CustomNameSetBeforeTheFirstHash)
{
    auto plain = std::make_shared<DataTypeString>();
    auto named = std::make_shared<DataTypeString>();
    named->setCustomization(std::make_unique<DataTypeCustomDesc>(std::make_unique<DataTypeCustomFixedName>("Named")));
    auto named_again = std::make_shared<DataTypeString>();
    named_again->setCustomization(std::make_unique<DataTypeCustomDesc>(std::make_unique<DataTypeCustomFixedName>("Named")));

    EXPECT_NE(plain->getHash(), named->getHash());
    EXPECT_EQ(named->getHash(), named_again->getHash());
    EXPECT_EQ(named->getHash(), legacyDigest(named));
}

#if defined(DEBUG_OR_SANITIZER_BUILD)
TEST(DataTypeHash, CustomNameAfterTheFirstHashIsAProgrammingError)
{
    /// unit_tests_dbms is multi-threaded; fork-style death tests need the threadsafe mode.
    ::testing::FLAGS_gtest_death_test_style = "threadsafe";
    auto t = std::make_shared<DataTypeString>();
    t->getHash();
    EXPECT_DEATH(
        t->setCustomization(std::make_unique<DataTypeCustomDesc>(std::make_unique<DataTypeCustomFixedName>("Late"))), "hash_cached");
}
#endif

TEST(DataTypeHash, SerializationOnlyCustomizationKeepsTheDigest)
{
    auto t = std::make_shared<DataTypeString>();
    auto before = t->getHash();
    t->setCustomization(std::make_unique<DataTypeCustomDesc>(nullptr, t->getDefaultSerialization()));
    EXPECT_EQ(before, t->getHash());
    EXPECT_EQ(before, type("String")->getHash());
}

TEST(DataTypeHash, NestedTypesAreReadThroughTheParent)
{
    auto shared_inner = type("Tuple(x String, y UInt8)");
    auto parent_shared = std::make_shared<DataTypeTuple>(
        DataTypes{std::make_shared<DataTypeArray>(shared_inner), shared_inner}, Strings{"a", "b"});
    auto parent_distinct = std::make_shared<DataTypeTuple>(
        DataTypes{std::make_shared<DataTypeArray>(type("Tuple(x String, y UInt8)")), type("Tuple(x String, y UInt8)")}, Strings{"a", "b"});
    auto parent_other = std::make_shared<DataTypeTuple>(
        DataTypes{std::make_shared<DataTypeArray>(type("Tuple(x String, y UInt16)")), type("Tuple(x String, y UInt8)")}, Strings{"a", "b"});

    EXPECT_EQ(parent_shared->getHash(), parent_distinct->getHash());
    EXPECT_NE(parent_shared->getHash(), parent_other->getHash());
    EXPECT_EQ(parent_shared->getHash(), legacyDigest(parent_shared));
}

TEST(DataTypeHash, ConcurrentFirstCallsAgree)
{
    auto t = type("Tuple(a String, b Array(Tuple(c UInt8, d Map(String, Array(Nullable(String))))))");
    const size_t threads = 16;
    std::vector<UInt128> results(threads);
    std::vector<std::thread> pool;
    for (size_t i = 0; i < threads; ++i)
        pool.emplace_back([&, i] { results[i] = t->getHash(); });
    for (auto & th : pool)
        th.join();
    for (size_t i = 1; i < threads; ++i)
        EXPECT_EQ(results[0], results[i]);
    EXPECT_EQ(results[0], legacyDigest(t));
}
