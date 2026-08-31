#include <Storages/MergeTree/PartColumnsParseMemo.h>

#include <DataTypes/DataTypeAggregateFunction.h>
#include <IO/ReadBufferFromString.h>
#include <Storages/ColumnsDescription.h>
#include <Storages/StorageInMemoryMetadata.h>
#include <Common/SharedLockGuard.h>

namespace DB
{

NamesAndTypesList PartColumnsParseMemo::parse(const String & contents, bool is_patch)
{
    {
        SharedLockGuard lock(mutex);
        const auto & entries = is_patch ? parsed_for_patch_parts : parsed_for_regular_parts;
        if (auto it = entries.find(contents); it != entries.end())
            return it->second;
    }

    NamesAndTypesList columns;
    ReadBufferFromString in(contents);
    columns.readText(in);

    /// Finish the list here rather than in each part that receives it: the types are shared with
    /// every part of the batch whose `columns.txt` is the same, and attaching a serialization
    /// writes to the type itself.
    for (auto & column : columns)
        setVersionToAggregateFunctions(column.type, true);

    /// As in `IMergeTreeDataPart::loadColumns`: a patch part carries no quantized serializations.
    if (!is_patch)
        attachQuantizeSerializations(columns, metadata_snapshot->getColumns());

    std::lock_guard lock(mutex);
    auto & entries = is_patch ? parsed_for_patch_parts : parsed_for_regular_parts;
    /// Another loader may have parsed the same contents meanwhile. The two results are equal, so
    /// keep whichever arrived first.
    return entries.emplace(contents, std::move(columns)).first->second;
}

}
