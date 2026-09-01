#include <Storages/MergeTree/PartColumnsParseMemo.h>

#include <DataTypes/DataTypeAggregateFunction.h>
#include <IO/ReadBufferFromString.h>
#include <Common/SharedLockGuard.h>

#include <mutex>

namespace DB
{

NamesAndTypesList PartColumnsParseMemo::parse(const String & contents)
{
    {
        SharedLockGuard lock(mutex);
        if (auto it = parsed.find(contents); it != parsed.end())
            return it->second;
    }

    NamesAndTypesList columns;
    ReadBufferFromString in(contents);
    columns.readText(in);

    /// Finish the list here rather than in each part that receives it, so that it runs once for
    /// the batch instead of once for every part, and every part is handed the same finished list.
    for (auto & column : columns)
        setVersionToAggregateFunctions(column.type, true);

    std::lock_guard lock(mutex);
    /// Another loader may have parsed the same contents meanwhile. The two results are equal, so
    /// keep whichever arrived first.
    return parsed.emplace(contents, std::move(columns)).first->second;
}

}
