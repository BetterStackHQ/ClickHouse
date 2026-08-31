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
/// under it are immutable: entries are never revalidated and leave the cache only under LRU
/// pressure or through `invalidate` after an observed read error on the object (an in-place
/// overwrite surfaces as an error via `s3_validate_etag_on_read` rather than as stale data).
/// Absence of an object is never cached.
class ObjectMetadataCache : public CacheBase<String, ObjectMetadata>
{
public:
    static ObjectMetadataCache & instance();

private:
    explicit ObjectMetadataCache(size_t max_entries);
};

}
