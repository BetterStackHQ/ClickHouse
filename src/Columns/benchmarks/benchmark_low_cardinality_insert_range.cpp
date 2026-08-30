#include <cstddef>
#include <Columns/IColumn.h>
#include <Core/Field.h>
#include <DataTypes/DataTypeFactory.h>
#include <DataTypes/IDataType.h>
#include <base/types.h>
#include <benchmark/benchmark.h>
#include <pcg_random.hpp>

using namespace DB;

/// One source column stands for one merged part's column, one destination column for one output
/// block: `insertRangeFrom` is called with a short range per output row, as a row-at-a-time insert
/// of an Array, Map or Tuple of LowCardinality does through `ColumnArray::insertFrom`.
static constexpr size_t ROWS = 8192;

static ColumnPtr makeSource(const DataTypePtr & type, size_t dictionary_size)
{
    auto column = type->createColumn();
    pcg64 rng(0);
    for (size_t i = 0; i < ROWS; ++i)
    {
        String value = "value_" + std::to_string(rng() % dictionary_size);
        column->insert(value);
    }
    return std::move(column);
}

template <const String & str_type>
static void BM_insertRangeFrom(benchmark::State & state)
{
    const size_t length = static_cast<size_t>(state.range(0));
    const size_t dictionary_size = static_cast<size_t>(state.range(1));

    auto type = DataTypeFactory::instance().get(str_type);
    auto src = makeSource(type, dictionary_size);
    const size_t ranges = ROWS / length;

    for (auto _ : state)
    {
        auto dst = type->createColumn();
        for (size_t i = 0; i < ranges; ++i)
            dst->insertRangeFrom(*src, i * length, length);
        benchmark::DoNotOptimize(dst);
    }

    state.SetItemsProcessed(static_cast<Int64>(state.iterations() * ranges * length));
}

static const String type_lc_string = "LowCardinality(String)";
static const String type_lc_nullable_string = "LowCardinality(Nullable(String))";

BENCHMARK(BM_insertRangeFrom<type_lc_string>)
    ->ArgsProduct({{1, 2, 3, 4, 8, 16, 32, 64, 128}, {8, 30, 256, 8192}});
BENCHMARK(BM_insertRangeFrom<type_lc_nullable_string>)
    ->ArgsProduct({{1, 2, 3, 4, 8, 16, 32, 64, 128}, {8, 30, 256, 8192}});

BENCHMARK_MAIN();
