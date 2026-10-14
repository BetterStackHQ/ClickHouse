#include <Storages/Cache/ObjectMetadataCache.h>

#include <Core/ServerSettings.h>
#include <Interpreters/Context.h>
#include <Common/CurrentMetrics.h>

namespace CurrentMetrics
{
    extern const Metric ObjectMetadataCacheEntries;
}

namespace DB
{

namespace ServerSetting
{
    extern const ServerSettingsUInt64 object_metadata_cache_max_entries;
}

std::atomic<ObjectMetadataCache *> ObjectMetadataCache::created_instance = nullptr;

ObjectMetadataCache::ObjectMetadataCache(size_t max_entries)
    // Note, it is OK to use max_size_in_bytes=max_entries since default weight is 1
    : CacheBase(CurrentMetrics::end(), CurrentMetrics::ObjectMetadataCacheEntries, /*max_size_in_bytes=*/max_entries)
{
    /// Published here rather than in `instance`, which runs on every lookup.
    created_instance.store(this, std::memory_order_release);
}

ObjectMetadataCache & ObjectMetadataCache::instance()
{
    static ObjectMetadataCache cache(
        Context::getGlobalContextInstance()->getServerSettings()[ServerSetting::object_metadata_cache_max_entries]);
    return cache;
}

ObjectMetadataCache * ObjectMetadataCache::instanceIfCreated()
{
    return created_instance.load(std::memory_order_acquire);
}

}
