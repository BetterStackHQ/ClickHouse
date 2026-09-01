#pragma once

#include <Core/NamesAndTypes.h>
#include <Common/SharedMutex.h>

#include <memory>
#include <unordered_map>

namespace DB
{

struct StorageInMemoryMetadata;
using StorageMetadataPtr = std::shared_ptr<const StorageInMemoryMetadata>;

/// Parses `columns.txt` once per distinct content while a batch of parts is being loaded.
///
/// Parts of one table almost always carry byte-identical `columns.txt`, and parsing it is the
/// largest userspace cost of loading a part: `NamesAndTypesList::readText` runs the data type
/// parser once per column, so a wide table with many parts parses the same declarations over and
/// over. The memo is keyed on the file's contents, which fully determine the result, and the map
/// compares them on lookup, so no hash collision can substitute a different schema.
///
/// What it returns is the finished list, not the raw parse. The two steps a part used to apply to
/// its own columns afterwards - the aggregate function versions and the `Quantized(...)`
/// serializations - are applied here instead, once, while the entry is being built. The second of
/// them attaches a serialization to the `IDataType` instances themselves, and those instances are
/// shared with every other part that has the same `columns.txt`, so it must not run again on a
/// list handed out from here; the entry is published only once it is complete.
///
/// It is deliberately not a cache. One is created for a batch of parts being loaded and released
/// with it, so nothing is retained once the load is over. It holds one entry per distinct schema
/// among the parts of the table being loaded - normally one - so the memory it can occupy at any
/// moment is bounded by the distinct schemas within one table's load times the number of tables
/// loading at once.
class PartColumnsParseMemo
{
public:
    /// `metadata_snapshot_` is the metadata a non-patch part of the batch would resolve for itself:
    /// a batch loads the parts of one table, and a top level part that is not a patch part takes
    /// the table's own in-memory metadata (`IMergeTreeDataPart::getMetadataSnapshot`). Taking it
    /// once here is what makes it the same for every entry, and keeps it alive for as long as the
    /// entries built from it. The active parts load runs in the table's constructor, where no
    /// `ALTER` can interleave; the outdated parts load runs in the background, where one can, and
    /// the batch then finishes with the version it started from instead of changing part way
    /// through.
    explicit PartColumnsParseMemo(StorageMetadataPtr metadata_snapshot_) : metadata_snapshot(std::move(metadata_snapshot_)) {}

    /// The finished columns of a part whose `columns.txt` holds `contents`. `is_patch` is part of
    /// the key because a patch part gets no quantized serializations and one batch can hold patch
    /// parts alongside normal ones.
    NamesAndTypesList parse(const String & contents, bool is_patch);

private:
    const StorageMetadataPtr metadata_snapshot;

    SharedMutex mutex;
    std::unordered_map<String, NamesAndTypesList> parsed_for_regular_parts TSA_GUARDED_BY(mutex);
    std::unordered_map<String, NamesAndTypesList> parsed_for_patch_parts TSA_GUARDED_BY(mutex);
};

using PartColumnsParseMemoPtr = std::shared_ptr<PartColumnsParseMemo>;

}
