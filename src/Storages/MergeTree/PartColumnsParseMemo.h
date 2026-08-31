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
/// It is deliberately not a cache. One is created for a batch of parts being loaded and released
/// with it, so nothing is retained once the load is over.
class PartColumnsParseMemo
{
public:
    /// The parsed contents of a `columns.txt`. Returns a copy, because callers go on to adjust
    /// the types per part - aggregate function versions, quantized serializations.
    NamesAndTypesList parse(const String & contents);

private:
    SharedMutex mutex;
    std::unordered_map<String, NamesAndTypesList> parsed TSA_GUARDED_BY(mutex);
};

using PartColumnsParseMemoPtr = std::shared_ptr<PartColumnsParseMemo>;

}
