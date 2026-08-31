#include <Storages/MergeTree/PartColumnsParseMemo.h>

#include <IO/ReadBufferFromString.h>
#include <Common/SharedLockGuard.h>

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

    std::lock_guard lock(mutex);
    /// Another loader may have parsed the same contents meanwhile. The two results are equal, so
    /// keep whichever arrived first.
    return parsed.emplace(contents, std::move(columns)).first->second;
}

}
