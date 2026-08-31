#include <Storages/Cache/ObjectMetadataCache.h>

#include <Interpreters/Context.h>
#include <Common/CurrentMetrics.h>

namespace CurrentMetrics
{
    extern const Metric ObjectMetadataCacheBytes;
    extern const Metric ObjectMetadataCacheEntries;
}

namespace DB
{

static constexpr size_t DEFAULT_OBJECT_METADATA_CACHE_MAX_ENTRIES = 100000;

ObjectMetadataCache::ObjectMetadataCache(size_t max_entries)
    : CacheBase(
          CurrentMetrics::ObjectMetadataCacheBytes,
          CurrentMetrics::ObjectMetadataCacheEntries,
          /* max_size_in_bytes */ max_entries,
          /* max_count */ max_entries)
{
}

ObjectMetadataCache & ObjectMetadataCache::instance()
{
    static ObjectMetadataCache cache(
        Context::getGlobalContextInstance()->getConfigRef().getUInt(
            "object_metadata_cache_max_entries", DEFAULT_OBJECT_METADATA_CACHE_MAX_ENTRIES));
    return cache;
}

}
