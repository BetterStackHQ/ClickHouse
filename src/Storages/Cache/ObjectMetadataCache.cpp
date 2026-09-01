#include <Storages/Cache/ObjectMetadataCache.h>

#include <Interpreters/Context.h>
#include <Common/CurrentMetrics.h>

namespace CurrentMetrics
{
    extern const Metric ObjectMetadataCacheEntries;
}

namespace DB
{

static constexpr size_t DEFAULT_OBJECT_METADATA_CACHE_MAX_ENTRIES = 100000;

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
        Context::getGlobalContextInstance()->getConfigRef().getUInt(
            "object_metadata_cache_max_entries", DEFAULT_OBJECT_METADATA_CACHE_MAX_ENTRIES));
    return cache;
}

ObjectMetadataCache * ObjectMetadataCache::instanceIfCreated()
{
    return created_instance.load(std::memory_order_acquire);
}

}
