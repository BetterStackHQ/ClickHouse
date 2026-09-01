#pragma once

#include <Common/CacheBase.h>
#include <Disks/DiskObjectStorage/ObjectStorages/IObjectStorage.h>

namespace DB
{

/// Process-wide cache of object storage metadata (size, ETag, last modification time), keyed by
/// the object's unique storage path identifier (connection description + object key). Consulted
/// by object storage sources instead of issuing a metadata (HEAD) request per object open.
///
/// Gated by the `use_object_metadata_cache` setting, whose contract is that the objects read
/// under it are immutable: entries are never revalidated, and leave the cache only under SLRU
/// pressure or through `remove` after an observed read error on the object.
///
/// Breaking that contract can produce stale results, not only errors. An S3 read compares the ETag
/// and total size of every response against the entry it started from and recovers from a
/// divergence, but only reads that reach S3 can: a read served from the filesystem cache issues no
/// GET, and the row count and schema inference caches validate against the cached last modification
/// time. Azure and HDFS have no equivalent check. Absence of an object is never cached.
class ObjectMetadataCache : public CacheBase<String, ObjectMetadata>
{
public:
    /// Creates the cache on the first call, fixing its size limit at the configured value.
    static ObjectMetadataCache & instance();

    /// The cache, or nullptr while no read has created it. Lets `SYSTEM DROP OBJECT METADATA CACHE`
    /// clear the cache without creating one that only it would ever have used.
    static ObjectMetadataCache * instanceIfCreated();

private:
    explicit ObjectMetadataCache(size_t max_entries);

    static std::atomic<ObjectMetadataCache *> created_instance;
};

}
