#pragma once

#include <Core/NamesAndTypes.h>
#include <Common/SharedMutex.h>

#include <memory>
#include <unordered_map>

namespace DB
{

/// Parses `columns.txt` once per distinct content while a batch of parts is being loaded.
///
/// Parts of one table almost always carry byte-identical `columns.txt`, and parsing it is the
/// largest userspace cost of loading a part: `NamesAndTypesList::readText` runs the data type
/// parser once per column, so a wide table with many parts parses the same declarations over and
/// over. The memo is keyed on the file's contents, which fully determine the result, and the map
/// compares them on lookup, so no hash collision can substitute a different schema.
///
/// What it returns is the finished list, not the raw parse. The step a part used to apply to its
/// own columns afterwards - the aggregate function versions - is applied here instead, once,
/// while the entry is being built, so that it too costs once per schema rather than once per
/// part. The entry is published only once it is complete.
///
/// It is deliberately not a cache. One is created for a batch of parts being loaded and released
/// with it, so nothing is retained once the load is over. It holds one entry per distinct schema
/// among the parts of the table being loaded - normally one - so the memory it can occupy at any
/// moment is bounded by the distinct schemas within one table's load times the number of tables
/// loading at once.
class PartColumnsParseMemo
{
public:
    /// The finished columns of a part whose `columns.txt` holds `contents`.
    NamesAndTypesList parse(const String & contents);

private:
    SharedMutex mutex;
    std::unordered_map<String, NamesAndTypesList> parsed TSA_GUARDED_BY(mutex);
};

using PartColumnsParseMemoPtr = std::shared_ptr<PartColumnsParseMemo>;

}
