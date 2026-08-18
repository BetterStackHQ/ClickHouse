#pragma once

#include <deque>
#include <map>
#include <memory>
#include <mutex>

#include <Core/Block_fwd.h>
#include <Processors/QueryPlan/ISourceStep.h>
#include <Processors/QueryPlan/QueryPlan.h>

namespace DB
{

class ExpressionActions;
using ExpressionActionsPtr = std::shared_ptr<ExpressionActions>;
class IStorage;

/// Placeholder for the view-source read inside a cached materialized view select plan.
/// Present only in cached plan skeletons; before execution every marker is replaced with
/// a `ReadFromPreparedSource` over the inserted block, so it is never executed itself.
class MVCachedSourceMarkerStep final : public ISourceStep
{
public:
    explicit MVCachedSourceMarkerStep(SharedHeader output_header_);

    String getName() const override { return "MVCachedSourceMarker"; }
    void initializePipeline(QueryPipelineBuilder & pipeline, const BuildQueryPipelineSettings & settings) override;
    QueryPlanStepPtr clone() const override;
};

/// Per-view cache of the analysed and optimized select plan of a materialized view, so
/// that pushing a block does not re-run query analysis and planning (which dominates
/// insert latency for large view queries). Owned by `StorageMaterializedView`, so its
/// lifetime follows the view: `DROP`/`DETACH` frees it and a server restart starts cold.
///
/// Entries are stored per "variant": the input block structure, the changed settings,
/// the effective user and roles, and the analyzer choice of the insert context. Each
/// entry also remembers a structure hash (metadata versions of the involved tables and
/// the select query tree); when it mismatches — e.g. after `ALTER TABLE ... MODIFY QUERY`
/// — the entry is rebuilt in place. There is no eviction policy, only a bound on the
/// number of variants to guard against pathological churn.
class MVSelectPlanCache
{
public:
    struct Entry
    {
        /// The optimized select plan with every view-source read replaced by
        /// `MVCachedSourceMarkerStep`. Cloned per use; never executed directly.
        QueryPlan plan;
        /// Conversion of the select output to the target table structure
        /// (shared safely between concurrently running pipelines).
        ExpressionActionsPtr conversion_actions;
        /// Hash of the metadata versions and the select query this entry was built
        /// against. A mismatch means the entry is stale and must be rebuilt.
        UInt64 structure_hash = 0;
        /// A negative entry: this view select must always use the non-cached path
        /// (analysis-time volatile constants, or a plan that cannot be cloned).
        bool cacheable = true;
    };
    using EntryPtr = std::shared_ptr<const Entry>;

    /// Returns the entry for the variant, or nullptr on miss or on structure mismatch
    /// (the stale entry is removed so the caller re-captures).
    EntryPtr get(const UInt128 & variant_key, UInt64 structure_hash);

    /// Stores an entry, replacing the oldest variant when `max_variants` is reached.
    void put(const UInt128 & variant_key, EntryPtr entry, size_t max_variants);

private:
    std::mutex mutex;
    std::map<UInt128, EntryPtr> entries;
    std::deque<UInt128> insertion_order;
};

/// The nodes of `plan` whose step reads from `view_source` (the `StorageValues`
/// standing in for the source table). More than one node when the view select
/// references the source table several times.
std::vector<QueryPlan::Node *> collectViewSourceNodes(QueryPlan & plan, const IStorage * view_source);

/// The marker nodes of a cloned cached plan skeleton.
std::vector<QueryPlan::Node *> collectMarkerNodes(QueryPlan & plan);

/// Whether the select query contains a function call that query analysis may fold into
/// a constant whose value depends on the moment or session of analysis (`now`,
/// `currentUser`, `getSetting` over literals, ...). Such view selects must not be
/// cached, because the cached plan would freeze the folded value. Unknown functions
/// (e.g. executable user defined functions) are conservatively treated as volatile.
bool selectContainsAnalysisTimeVolatileConstants(const ASTPtr & select_query, const ContextPtr & context);

}
