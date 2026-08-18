#pragma once

#include <deque>
#include <map>
#include <memory>
#include <shared_mutex>

#include <Common/SharedMutex.h>

#include <Core/Block_fwd.h>
#include <Core/Names.h>
#include <Processors/QueryPlan/ISourceStep.h>
#include <Processors/QueryPlan/Optimizations/QueryPlanOptimizationSettings.h>
#include <Processors/QueryPlan/QueryPlan.h>

namespace DB
{

class ExpressionActions;
using ExpressionActionsPtr = std::shared_ptr<ExpressionActions>;
class IStorage;

/// Placeholder for the view-source read inside a cached materialized view select plan.
/// Present only in cached plan skeletons; before execution every marker is replaced with
/// a `ReadFromPreparedSource` over the inserted block, so it is never executed itself.
class MaterializedViewCachedSourceMarkerStep final : public ISourceStep
{
public:
    explicit MaterializedViewCachedSourceMarkerStep(SharedHeader output_header_);

    String getName() const override { return "MaterializedViewCachedSourceMarker"; }
    void initializePipeline(QueryPipelineBuilder & pipeline, const BuildQueryPipelineSettings & settings) override;
    QueryPlanStepPtr clone() const override;
};

/// Per-view cache of the analyzed and optimized select plan of a materialized view, so
/// that pushing a block does not re-run query analysis and planning (which dominates
/// insert latency for large view queries). Owned by `StorageMaterializedView`, so its
/// lifetime follows the view: `DROP`/`DETACH` frees it and a server restart starts cold.
///
/// Entries are stored per "variant": the input block structure, the changed settings,
/// the effective user and roles, and the analyzer choice of the insert context. Each
/// entry also remembers a structure hash (metadata versions of the involved tables, the
/// select query tree, resolved SQL user defined function bodies, and the effective row
/// policy of the source table); when it mismatches, e.g. after `ALTER TABLE ... MODIFY
/// QUERY`, the entry is rebuilt in place. Entries are replaced oldest-first beyond a
/// per-view variant bound; there is no other eviction.
class MaterializedViewSelectPlanCache
{
public:
    struct Entry
    {
        /// The optimized select plan with every view-source read replaced by
        /// `MaterializedViewCachedSourceMarkerStep`. Cloned per use; never executed directly.
        QueryPlan plan;
        /// Conversion of the select output to the target table structure
        /// (shared safely between concurrently running pipelines).
        ExpressionActionsPtr conversion_actions;
        /// The optimization settings the plan was optimized and is rebuilt with
        /// (fixed per variant; kept here so cache hits do not reconstruct them).
        /// Set for every cacheable entry; absent on negative entries.
        std::optional<QueryPlanOptimizationSettings> optimization_settings;
        /// Hash of everything this entry was built against (see the class comment).
        /// A mismatch means the entry is stale and must be rebuilt.
        UInt64 structure_hash = 0;
        /// A negative entry: this view select must always use the non-cached path
        /// (analysis-time volatile constructs, reads besides the view source, or a
        /// plan that cannot be cloned).
        bool cacheable = true;
    };
    using EntryPtr = std::shared_ptr<const Entry>;

    ~MaterializedViewSelectPlanCache();

    /// Returns the entry for the variant, or nullptr on miss or on structure mismatch
    /// (the stale entry is removed so the caller re-captures).
    EntryPtr get(const UInt128 & variant_key, UInt64 structure_hash);

    /// Stores an entry, replacing the oldest variant when `max_variants` is reached.
    void put(const UInt128 & variant_key, EntryPtr entry, size_t max_variants);

private:
    /// Reader-writer: the per-block hot path is `get`, which takes only a shared
    /// lock, so concurrent inserts into one view do not serialize on the cache.
    /// The exclusive lock is taken only by `put` and by stale-entry eviction,
    /// both rare (capture and invalidation events).
    SharedMutex mutex;
    std::map<UInt128, EntryPtr> entries;
    std::deque<UInt128> insertion_order;
};

/// The nodes of `plan` whose step reads from `view_source` (the `StorageValues`
/// standing in for the source table). More than one node when the view select
/// references the source table several times.
std::vector<QueryPlan::Node *> collectViewSourceNodes(QueryPlan & plan, const IStorage * view_source);

/// The marker nodes of a cloned cached plan skeleton.
std::vector<QueryPlan::Node *> collectMarkerNodes(QueryPlan & plan);

/// All leaf nodes of the plan (the sources it reads from).
std::vector<QueryPlan::Node *> collectLeafNodes(QueryPlan & plan);

/// Result of the AST-level cacheability analysis of a view select.
struct SelectPlanCacheAnalysis
{
    /// False when the select contains constructs that analysis freezes into the plan
    /// and that must stay per-block: function calls foldable into session- or
    /// time-dependent constants (`now`, `currentUser` over constant arguments),
    /// subqueries of any kind (folded scalars, `IN`, `EXISTS`), `joinGet` (holds a
    /// table lock inside the plan), executable user defined functions, and unknown
    /// function names.
    bool cacheable = true;
    /// Combined hash of the resolved SQL user defined function bodies the select
    /// calls (they are inlined during analysis, so a redefinition must invalidate).
    UInt64 udf_bodies_hash = 0;
};

SelectPlanCacheAnalysis analyzeSelectForPlanCache(const ASTPtr & select_query, const ContextPtr & context);

}
