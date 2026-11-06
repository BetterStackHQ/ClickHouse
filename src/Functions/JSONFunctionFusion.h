#pragma once

#include <Core/ColumnsWithTypeAndName.h>
#include <Functions/IFunction.h>

namespace DB
{

/** A `JSON*` function (`JSONExtract`, `JSONExtractString`, `JSONHas`, ...) whose calls over one document
  * column can be executed with a single parse of each document, see `ActionsDAG::fuseJSONFunctions`.
  * Implemented by the function bases that `FunctionsJSON.cpp` builds.
  */
class IJSONFusableFunction
{
public:
    virtual ~IJSONFusableFunction() = default;

    /// Whether a call with these arguments (constants carry their values) can be a member of a fused group
    /// with a result identical to the standalone call: a plain `String` document, constant keys and indices,
    /// nothing `Nullable` or `LowCardinality` in the signature.
    virtual bool isFusable(const ColumnsWithTypeAndName & arguments) const = 0;

    /// The members of one group must parse with the same parser.
    virtual bool usesSimdJSON() const = 0;
};

/// One member of a fused group: a `JSON*` function base and the arguments it was resolved for.
struct JSONFusedMemberCall
{
    FunctionBasePtr function;
    ColumnsWithTypeAndName arguments;
};

/// A function `(String) -> Tuple(result types of the members)` that parses each document once and runs
/// every member on it. Each member must be an `IJSONFusableFunction` that accepts its arguments, and all
/// members must agree on `usesSimdJSON`.
FunctionBasePtr createFusedJSONFunction(std::vector<JSONFusedMemberCall> members);

}
