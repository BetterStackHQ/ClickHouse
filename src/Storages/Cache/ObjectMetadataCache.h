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
/// Breaking that contract can produce stale results, not only errors. `s3_validate_etag_on_read`
/// turns an in-place overwrite into an error only for reads that reach S3: a read served from the
/// filesystem cache issues no GET, and the row count and schema inference caches validate against
/// the cached last modification time. Azure and HDFS have no equivalent check. What the error path
/// does guarantee is recovery: it removes the entry, so the next query fetches the metadata again.
/// Absence of an object is never cached.
class ObjectMetadataCache : public CacheBase<String, ObjectMetadata>
{
public:
    static ObjectMetadataCache & instance();

private:
    explicit ObjectMetadataCache(size_t max_entries);
};

}
