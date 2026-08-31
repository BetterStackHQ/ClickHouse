#include <Columns/ColumnLowCardinality.h>
#include <Columns/ColumnsNumber.h>

#include <DataTypes/DataTypesNumber.h>
#include <DataTypes/DataTypeLowCardinality.h>
#include <DataTypes/DataTypeNullable.h>
#include <DataTypes/DataTypeString.h>
#include <Common/Exception.h>

#include <gtest/gtest.h>

#include <optional>
#include <random>
#include <string>
#include <vector>

using namespace DB;

namespace DB::ErrorCodes
{
    extern const int PARAMETER_OUT_OF_BOUND;
}

template <typename T>
void testLowCardinalityNumberInsert(const DataTypePtr & data_type)
{
    auto low_cardinality_type = std::make_shared<DataTypeLowCardinality>(data_type);
    auto column = low_cardinality_type->createColumn();

    column->insert(static_cast<T>(15));
    column->insert(static_cast<T>(20));
    column->insert(static_cast<T>(25));

    Field value;
    column->get(0, value);
    ASSERT_EQ(value.safeGet<T>(), 15);

    column->get(1, value);
    ASSERT_EQ(value.safeGet<T>(), 20);

    column->get(2, value);
    ASSERT_EQ(value.safeGet<T>(), 25);
}

TEST(ColumnLowCardinality, Insert)
{
    testLowCardinalityNumberInsert<UInt8>(std::make_shared<DataTypeUInt8>());
    testLowCardinalityNumberInsert<UInt16>(std::make_shared<DataTypeUInt16>());
    testLowCardinalityNumberInsert<UInt32>(std::make_shared<DataTypeUInt32>());
    testLowCardinalityNumberInsert<UInt64>(std::make_shared<DataTypeUInt64>());
    testLowCardinalityNumberInsert<UInt128>(std::make_shared<DataTypeUInt128>());
    testLowCardinalityNumberInsert<UInt256>(std::make_shared<DataTypeUInt256>());

    testLowCardinalityNumberInsert<Int8>(std::make_shared<DataTypeInt8>());
    testLowCardinalityNumberInsert<Int16>(std::make_shared<DataTypeInt16>());
    testLowCardinalityNumberInsert<Int32>(std::make_shared<DataTypeInt32>());
    testLowCardinalityNumberInsert<Int64>(std::make_shared<DataTypeInt64>());
    testLowCardinalityNumberInsert<Int128>(std::make_shared<DataTypeInt128>());
    testLowCardinalityNumberInsert<Int256>(std::make_shared<DataTypeInt256>());

    testLowCardinalityNumberInsert<BFloat16>(std::make_shared<DataTypeBFloat16>());
    testLowCardinalityNumberInsert<Float32>(std::make_shared<DataTypeFloat32>());
    testLowCardinalityNumberInsert<Float64>(std::make_shared<DataTypeFloat64>());
}

TEST(ColumnLowCardinality, Clone)
{
    auto data_type = std::make_shared<DataTypeInt32>();
    auto low_cardinality_type = std::make_shared<DataTypeLowCardinality>(data_type);
    auto column = low_cardinality_type->createColumn();
    ASSERT_FALSE(assert_cast<const ColumnLowCardinality &>(*column).nestedIsNullable());

    auto nullable_column = assert_cast<const ColumnLowCardinality &>(*column).cloneNullable();

    ASSERT_TRUE(assert_cast<const ColumnLowCardinality &>(*nullable_column).nestedIsNullable());
    ASSERT_FALSE(assert_cast<const ColumnLowCardinality &>(*column).nestedIsNullable());
}

TEST(ColumnLowCardinality, CloneNullableKeepsZeroValue)
{
    auto data_type = std::make_shared<DataTypeUInt64>();
    auto low_cardinality_type = std::make_shared<DataTypeLowCardinality>(data_type);
    auto column = low_cardinality_type->createColumn();

    column->insert(static_cast<UInt64>(0));
    column->insert(static_cast<UInt64>(1));
    column->insert(static_cast<UInt64>(2));

    auto nullable_column = assert_cast<const ColumnLowCardinality &>(*column).cloneNullable();
    const auto & nullable_lc = assert_cast<const ColumnLowCardinality &>(*nullable_column);

    ASSERT_TRUE(nullable_lc.nestedIsNullable());
    ASSERT_FALSE(nullable_lc.isNullAt(0));
    ASSERT_FALSE(nullable_lc.isNullAt(1));
    ASSERT_FALSE(nullable_lc.isNullAt(2));

    Field value;
    nullable_column->get(0, value);
    ASSERT_EQ(value.safeGet<UInt64>(), 0);
    nullable_column->get(1, value);
    ASSERT_EQ(value.safeGet<UInt64>(), 1);
    nullable_column->get(2, value);
    ASSERT_EQ(value.safeGet<UInt64>(), 2);
}

TEST(ColumnLowCardinality, EmptyDictionaryEmptyIndexes)
{
    /// Test edge case: empty dictionary (size=0) with empty indexes (num_rows=0)
    /// This should not throw an error, as empty indexes are always valid
    /// Regression test for bug where check was: if (max_position >= limit)
    /// When num_rows=0, max_position stays 0, and with limit=0, this incorrectly threw
    
    auto data_type = std::make_shared<DataTypeUInt32>();
    auto low_cardinality_type = std::make_shared<DataTypeLowCardinality>(data_type);
    auto column = low_cardinality_type->createColumn();
    auto & lc_column = assert_cast<ColumnLowCardinality &>(*column);
    
    // Create empty keys and indexes columns
    auto empty_keys = ColumnUInt32::create();
    auto empty_indexes = ColumnUInt8::create();
    
    // This should NOT throw an exception
    ASSERT_NO_THROW(lc_column.insertRangeFromDictionaryEncodedColumn(*empty_keys, *empty_indexes));
    
    ASSERT_EQ(column->size(), 0);
}

namespace
{
    void assertOutOfBound(IColumn & destination, const IColumn & source, size_t start, size_t length)
    {
        try
        {
            destination.insertRangeFrom(source, start, length);
        }
        catch (const Exception & e)
        {
            ASSERT_EQ(e.code(), ErrorCodes::PARAMETER_OUT_OF_BOUND);
            return;
        }
        FAIL() << "insertRangeFrom(" << start << ", " << length << ") was expected to throw";
    }
}

TEST(ColumnLowCardinality, InsertRangeFromOutOfBound)
{
    auto low_cardinality_type = std::make_shared<DataTypeLowCardinality>(std::make_shared<DataTypeUInt64>());

    auto source = low_cardinality_type->createColumn();
    source->insert(static_cast<UInt64>(1));
    source->insert(static_cast<UInt64>(2));
    source->insert(static_cast<UInt64>(3));

    auto destination = low_cardinality_type->createColumn();

    /// A range running past the end of the source has to be reported rather than read out of
    /// bounds, on both branches: short ranges are translated element by element through the memo,
    /// longer ones go through the bulk path, and a source sharing the destination's dictionary
    /// takes neither.
    assertOutOfBound(*destination, *source, 0, 4);
    assertOutOfBound(*destination, *source, 3, 1);
    assertOutOfBound(*destination, *source, 4, 0);
    assertOutOfBound(*destination, *source, 1, 3);
    assertOutOfBound(*destination, *source, 0, 1024);
    assertOutOfBound(*source, *source, 0, 4);
    ASSERT_EQ(destination->size(), 0);

    /// The ranges that do fit, including the empty one at the end.
    ASSERT_NO_THROW(destination->insertRangeFrom(*source, 1, 2));
    ASSERT_NO_THROW(destination->insertRangeFrom(*source, 3, 0));
    ASSERT_NO_THROW(destination->insertRangeFrom(*source, 0, 3));
    ASSERT_EQ(destination->size(), 5);
}

namespace
{
    DataTypePtr lowCardinalityNullableString()
    {
        return std::make_shared<DataTypeLowCardinality>(std::make_shared<DataTypeNullable>(std::make_shared<DataTypeString>()));
    }

    /// A LowCardinality column over its own dictionary, holding `values` in order; an empty optional
    /// is a NULL.
    ColumnPtr makeSource(const DataTypePtr & type, const std::vector<std::optional<String>> & values)
    {
        auto column = type->createColumn();

        for (const auto & value : values)
        {
            if (value)
                column->insert(Field(*value));
            else
                column->insert(Field());
        }

        return std::move(column);
    }
}

TEST(ColumnLowCardinality, InsertFromInstallsTranslation)
{
    auto type = lowCardinalityNullableString();

    auto source = makeSource(type, {"a", "b", std::nullopt, "", "b"});
    const auto & lc_source = assert_cast<const ColumnLowCardinality &>(*source);

    /// An installed entry holds a reference to the source dictionary for as long as it lives, so it
    /// is visible from outside the column in that dictionary's reference count. Nothing but
    /// `insertFrom` touches the memo here, which is what makes this an assertion that the scalar arm
    /// translates through it rather than probing the destination dictionary per row.
    const auto references_before = lc_source.getDictionaryPtr()->use_count();

    {
        auto destination = type->createColumn();
        auto & lc_destination = assert_cast<ColumnLowCardinality &>(*destination);

        lc_destination.insertFrom(*source, 0);
        const auto references_installed = lc_source.getDictionaryPtr()->use_count();
        ASSERT_GT(references_installed, references_before);

        /// One entry per source dictionary, not one per row.
        for (size_t row = 1; row < source->size(); ++row)
            lc_destination.insertFrom(*source, row);
        ASSERT_EQ(lc_source.getDictionaryPtr()->use_count(), references_installed);

        ASSERT_EQ(destination->size(), source->size());
        for (size_t row = 0; row < destination->size(); ++row)
        {
            ASSERT_EQ(lc_destination.isNullAt(row), lc_source.isNullAt(row)) << "at row " << row;
            if (!lc_destination.isNullAt(row))
                ASSERT_EQ(lc_destination.getDataAt(row), lc_source.getDataAt(row)) << "at row " << row;
        }
    }

    /// The entry, and the reference it held, go with the column that owned the memo.
    ASSERT_EQ(lc_source.getDictionaryPtr()->use_count(), references_before);
}

TEST(ColumnLowCardinality, InsertFromCrossDictionaryMatchesUniqueInsertFrom)
{
    auto type = lowCardinalityNullableString();

    /// More sources than the memo holds entries for, so both of its answers are exercised: the first
    /// sources get an entry each and the rest are declined and translated the unmemoized way.
    constexpr size_t num_sources = 20;
    constexpr size_t rows_per_source = 64;
    /// More distinct values than an index of one byte can address, so the destination widens its
    /// index type while the memo is live.
    constexpr size_t num_values = 400;

    std::vector<ColumnPtr> sources;
    std::minstd_rand random(20260831);

    for (size_t source_index = 0; source_index < num_sources; ++source_index)
    {
        std::vector<std::optional<String>> values;
        values.reserve(rows_per_source);

        for (size_t row = 0; row < rows_per_source; ++row)
        {
            const size_t value = random() % num_values;
            if (value % 37 == 0)
                values.emplace_back(std::nullopt);
            else if (value % 41 == 0)
                values.emplace_back("");
            else
                values.emplace_back("v" + std::to_string(value));
        }

        sources.push_back(makeSource(type, values));
    }

    auto memoized_column = type->createColumn();
    auto reference_column = type->createColumn();
    auto & memoized = assert_cast<ColumnLowCardinality &>(*memoized_column);
    auto & reference = assert_cast<ColumnLowCardinality &>(*reference_column);

    /// `insertFrom` translates through the memo; `insertFromFullColumn` on the source's own nested
    /// column is the `uniqueInsertFrom` that the unmemoized branch of `insertFrom` makes, so the two
    /// destinations must come out identical - down to their indexes, because both dictionaries are
    /// filled by the same calls in the same order. Coverage of the memo's execution rests on this
    /// test being compiled with the memo present: with it, every row below goes through it.
    for (size_t row = 0; row < rows_per_source; ++row)
    {
        /// Interleaved, so that consecutive calls ask the memo for different entries.
        for (const auto & source : sources)
        {
            const auto & lc_source = assert_cast<const ColumnLowCardinality &>(*source);
            memoized.insertFrom(*source, row);
            reference.insertFromFullColumn(*lc_source.getDictionary().getNestedColumn(), lc_source.getIndexAt(row));
        }
    }

    ASSERT_EQ(memoized.size(), num_sources * rows_per_source);
    ASSERT_EQ(memoized.size(), reference.size());
    ASSERT_EQ(memoized.getDictionary().size(), reference.getDictionary().size());
    /// The point of `num_values`: a one-byte index could not have addressed this dictionary.
    ASSERT_GT(memoized.getDictionary().size(), size_t{255});

    for (size_t row = 0; row < memoized.size(); ++row)
    {
        ASSERT_EQ(memoized.getIndexAt(row), reference.getIndexAt(row)) << "at row " << row;
        ASSERT_EQ(memoized.isNullAt(row), reference.isNullAt(row)) << "at row " << row;
        if (!memoized.isNullAt(row))
            ASSERT_EQ(memoized.getDataAt(row), reference.getDataAt(row)) << "at row " << row;
    }
}
