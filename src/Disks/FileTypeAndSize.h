#pragma once

#include <base/types.h>

namespace DB
{

/// What a single metadata lookup can tell about an entry: whether it is a directory, and how big
/// it is when it is not. `size` is meaningful only when `is_directory` is `false`.
struct FileTypeAndSize
{
    bool is_directory = false;
    UInt64 size = 0;
};

}
