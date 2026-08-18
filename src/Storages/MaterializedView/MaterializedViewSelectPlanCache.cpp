#include <Storages/MaterializedView/MaterializedViewSelectPlanCache.h>

#include <AggregateFunctions/AggregateFunctionFactory.h>
#include <Common/CurrentMetrics.h>
#include <Functions/FunctionFactory.h>
#include <Functions/UserDefined/UserDefinedSQLFunctionFactory.h>
#include <Common/ProfileEvents.h>
#include <Common/SipHash.h>
#include <Parsers/ASTCreateSQLFunctionQuery.h>
#include <Parsers/ASTFunction.h>
#include <Parsers/ASTLiteral.h>
#include <Parsers/ASTSubquery.h>
#include <Parsers/ASTTablesInSelectQuery.h>
#include <unordered_set>
#include <Processors/QueryPlan/ReadFromPreparedSource.h>
#include <Storages/IStorage.h>

namespace CurrentMetrics
{
    extern const Metric MaterializedViewSelectPlanCacheEntries;
}

namespace ProfileEvents
{
    extern const Event MaterializedViewSelectPlanCacheRebuilds;
}

namespace DB
{

namespace ErrorCodes
{
    extern const int LOGICAL_ERROR;
}

MaterializedViewCachedSourceMarkerStep::MaterializedViewCachedSourceMarkerStep(SharedHeader output_header_)
    : ISourceStep(std::move(output_header_))
{
}

void MaterializedViewCachedSourceMarkerStep::initializePipeline(QueryPipelineBuilder &, const BuildQueryPipelineSettings &)
{
    throw Exception(ErrorCodes::LOGICAL_ERROR,
        "MaterializedViewCachedSourceMarkerStep must be replaced with a real source before execution");
}

QueryPlanStepPtr MaterializedViewCachedSourceMarkerStep::clone() const
{
    return std::make_unique<MaterializedViewCachedSourceMarkerStep>(getOutputHeader());
}

MaterializedViewSelectPlanCache::~MaterializedViewSelectPlanCache()
{
    CurrentMetrics::sub(CurrentMetrics::MaterializedViewSelectPlanCacheEntries, entries.size());
}

MaterializedViewSelectPlanCache::EntryPtr MaterializedViewSelectPlanCache::get(const UInt128 & variant_key, UInt64 structure_hash)
{
    {
        std::shared_lock lock(mutex);
        auto it = entries.find(variant_key);
        if (it == entries.end())
            return nullptr;
        if (it->second->structure_hash == structure_hash)
            return it->second;
    }

    /// Stale after a metadata, query, UDF, or row policy change: drop so the
    /// caller re-captures. Re-check under the exclusive lock — another thread
    /// may have already dropped or replaced the entry.
    std::lock_guard lock(mutex);
    auto it = entries.find(variant_key);
    if (it == entries.end())
        return nullptr;
    if (it->second->structure_hash == structure_hash)
        return it->second;
    ProfileEvents::increment(ProfileEvents::MaterializedViewSelectPlanCacheRebuilds);
    entries.erase(it);
    std::erase(insertion_order, variant_key);
    CurrentMetrics::sub(CurrentMetrics::MaterializedViewSelectPlanCacheEntries);
    return nullptr;
}

void MaterializedViewSelectPlanCache::put(const UInt128 & variant_key, EntryPtr entry, size_t max_variants)
{
    /// A zero bound would make every put evict its own insertion, turning the cache
    /// into pure capture overhead.
    max_variants = std::max<size_t>(1, max_variants);
    std::lock_guard lock(mutex);
    auto [it, inserted] = entries.try_emplace(variant_key, entry);
    if (!inserted)
    {
        /// Concurrent capture of the same variant, or a rebuild: replace.
        it->second = std::move(entry);
        return;
    }
    CurrentMetrics::add(CurrentMetrics::MaterializedViewSelectPlanCacheEntries);
    insertion_order.push_back(variant_key);
    while (insertion_order.size() > max_variants)
    {
        entries.erase(insertion_order.front());
        insertion_order.pop_front();
        CurrentMetrics::sub(CurrentMetrics::MaterializedViewSelectPlanCacheEntries);
    }
}

template <typename Predicate>
static std::vector<QueryPlan::Node *> collectNodes(QueryPlan & plan, Predicate predicate)
{
    std::vector<QueryPlan::Node *> result;
    std::vector<QueryPlan::Node *> stack{plan.getRootNode()};
    while (!stack.empty())
    {
        auto * node = stack.back();
        stack.pop_back();
        if (predicate(node))
            result.push_back(node);
        for (auto * child : node->children)
            stack.push_back(child);
    }
    return result;
}

std::vector<QueryPlan::Node *> collectViewSourceNodes(QueryPlan & plan, const IStorage * view_source)
{
    return collectNodes(plan, [&](QueryPlan::Node * node)
    {
        const auto * read_from_storage = typeid_cast<const ReadFromStorageStep *>(node->step.get());
        return read_from_storage && read_from_storage->getStorage().get() == view_source;
    });
}

std::vector<QueryPlan::Node *> collectMarkerNodes(QueryPlan & plan)
{
    return collectNodes(plan, [](QueryPlan::Node * node)
    {
        return typeid_cast<const MaterializedViewCachedSourceMarkerStep *>(node->step.get()) != nullptr;
    });
}

std::vector<QueryPlan::Node *> collectLeafNodes(QueryPlan & plan)
{
    return collectNodes(plan, [](QueryPlan::Node * node) { return node->children.empty(); });
}

/// Whether every argument is fixed at analysis time: a literal, or a function over
/// such arguments (the function's own volatility is judged at its own visit).
static bool argumentsAreAnalysisTimeConstants(const ASTFunction & function)
{
    if (!function.arguments)
        return true;
    std::vector<const IAST *> stack;
    for (const auto & argument : function.arguments->children)
        stack.push_back(argument.get());
    while (!stack.empty())
    {
        const auto * ast = stack.back();
        stack.pop_back();
        if (ast->as<ASTLiteral>())
            continue;
        const auto * nested = ast->as<ASTFunction>();
        if (!nested)
            return false;
        if (nested->arguments)
            for (const auto & argument : nested->arguments->children)
                stack.push_back(argument.get());
    }
    return true;
}

static void analyzeImpl(const IAST * root, const ContextPtr & context, NameSet & visited_udfs, SelectPlanCacheAnalysis & result, SipHash & udf_hash)
{
    /// Subqueries in the FROM clause are plain table expressions over whatever they
    /// read (the plan-level foreign-reads check vets that); they are exempted below.
    std::unordered_set<const IAST *> from_subqueries;

    std::vector<const IAST *> stack{root};
    while (!stack.empty() && result.cacheable)
    {
        const auto * ast = stack.back();
        stack.pop_back();

        if (const auto * table_expression = ast->as<ASTTableExpression>())
            if (table_expression->subquery)
                from_subqueries.insert(table_expression->subquery.get());

        /// Expression-position subqueries are executed or folded during analysis and
        /// would be frozen by the cached plan (scalar subqueries become literals; the
        /// tables read by `IN`/`EXISTS` subqueries are captured without invalidation).
        if (ast->as<ASTSubquery>() && !from_subqueries.contains(ast))
        {
            result.cacheable = false;
            return;
        }

        for (const auto & child : ast->children)
            stack.push_back(child.get());

        const auto * function = ast->as<ASTFunction>();
        if (!function)
            continue;
        /// Structural pseudo-functions; the calls inside them are scanned as children.
        if (function->name == "lambda" || function->name == "grouping" || function->name == "untuple")
            continue;
        /// `joinGet` resolves the Join table and takes a shared table lock at analysis
        /// time; a cached plan would hold that lock for the entry's lifetime.
        if (function->name == "joinGet" || function->name == "joinGetOrNull")
        {
            result.cacheable = false;
            return;
        }
        if (AggregateFunctionFactory::instance().isAggregateFunctionName(function->name))
            continue;
        if (auto resolver = FunctionFactory::instance().tryGet(function->name, context))
        {
            /// Only calls that analysis can fold matter: a non-deterministic function
            /// over non-constant arguments is executed per row by the cached plan
            /// exactly as by a freshly planned one.
            if (!resolver->isDeterministic() && argumentsAreAnalysisTimeConstants(*function))
            {
                result.cacheable = false;
                return;
            }
            continue;
        }
        /// SQL user defined functions are inlined during analysis: scan the body with
        /// the same rules (cycle-guarded) and hash it, so a redefinition invalidates.
        /// Anything else (executable user defined functions, unknown names) is
        /// conservatively treated as volatile.
        if (auto create_function_query = UserDefinedSQLFunctionFactory::instance().tryGet(function->name))
        {
            if (!visited_udfs.emplace(function->name).second)
                continue;
            const auto * create_function = create_function_query->as<ASTCreateSQLFunctionQuery>();
            if (!create_function || !create_function->function_core)
            {
                result.cacheable = false;
                return;
            }
            udf_hash.update(function->name);
            const auto body_hash = create_function->function_core->getTreeHash(/*ignore_aliases=*/ false);
            udf_hash.update(body_hash.low64);
            udf_hash.update(body_hash.high64);
            analyzeImpl(create_function->function_core.get(), context, visited_udfs, result, udf_hash);
            continue;
        }
        result.cacheable = false;
        return;
    }
}

SelectPlanCacheAnalysis analyzeSelectForPlanCache(const ASTPtr & select_query, const ContextPtr & context)
{
    SelectPlanCacheAnalysis result;
    NameSet visited_udfs;
    SipHash udf_hash;
    analyzeImpl(select_query.get(), context, visited_udfs, result, udf_hash);
    result.udf_bodies_hash = udf_hash.get64();
    return result;
}

}
