#include <Storages/MaterializedView/MVSelectPlanCache.h>

#include <AggregateFunctions/AggregateFunctionFactory.h>
#include <Common/CurrentMetrics.h>
#include <Functions/FunctionFactory.h>
#include <Functions/UserDefined/UserDefinedSQLFunctionFactory.h>
#include <Parsers/ASTCreateSQLFunctionQuery.h>
#include <Parsers/ASTFunction.h>
#include <Parsers/ASTLiteral.h>
#include <Processors/QueryPlan/ReadFromPreparedSource.h>
#include <Storages/IStorage.h>

namespace CurrentMetrics
{
    extern const Metric MVSelectPlanCacheEntries;
}

namespace DB
{

namespace ErrorCodes
{
    extern const int LOGICAL_ERROR;
}

MVCachedSourceMarkerStep::MVCachedSourceMarkerStep(SharedHeader output_header_)
    : ISourceStep(std::move(output_header_))
{
}

void MVCachedSourceMarkerStep::initializePipeline(QueryPipelineBuilder &, const BuildQueryPipelineSettings &)
{
    throw Exception(ErrorCodes::LOGICAL_ERROR,
        "MVCachedSourceMarkerStep must be replaced with a real source before execution");
}

QueryPlanStepPtr MVCachedSourceMarkerStep::clone() const
{
    return std::make_unique<MVCachedSourceMarkerStep>(getOutputHeader());
}

MVSelectPlanCache::EntryPtr MVSelectPlanCache::get(const UInt128 & variant_key, UInt64 structure_hash)
{
    std::lock_guard lock(mutex);
    auto it = entries.find(variant_key);
    if (it == entries.end())
        return nullptr;
    if (it->second->structure_hash != structure_hash)
    {
        /// Stale after a metadata or query change: drop so the caller re-captures.
        entries.erase(it);
        std::erase(insertion_order, variant_key);
        CurrentMetrics::sub(CurrentMetrics::MVSelectPlanCacheEntries);
        return nullptr;
    }
    return it->second;
}

void MVSelectPlanCache::put(const UInt128 & variant_key, EntryPtr entry, size_t max_variants)
{
    std::lock_guard lock(mutex);
    auto [it, inserted] = entries.try_emplace(variant_key, entry);
    if (!inserted)
    {
        /// Concurrent capture of the same variant, or a rebuild: replace.
        it->second = std::move(entry);
        return;
    }
    CurrentMetrics::add(CurrentMetrics::MVSelectPlanCacheEntries);
    insertion_order.push_back(variant_key);
    while (insertion_order.size() > max_variants)
    {
        entries.erase(insertion_order.front());
        insertion_order.pop_front();
        CurrentMetrics::sub(CurrentMetrics::MVSelectPlanCacheEntries);
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
        return typeid_cast<const MVCachedSourceMarkerStep *>(node->step.get()) != nullptr;
    });
}

static bool allArgumentsAreLiterals(const ASTFunction & function)
{
    if (!function.arguments)
        return true;
    for (const auto & argument : function.arguments->children)
        if (!argument->as<ASTLiteral>())
            return false;
    return true;
}

static bool containsVolatileConstants(const IAST * root, const ContextPtr & context, NameSet & visited_udfs)
{
    std::vector<const IAST *> stack{root};
    while (!stack.empty())
    {
        const auto * ast = stack.back();
        stack.pop_back();
        for (const auto & child : ast->children)
            stack.push_back(child.get());

        const auto * function = ast->as<ASTFunction>();
        if (!function)
            continue;
        /// Structural pseudo-functions; the calls inside them are scanned as children.
        if (function->name == "lambda" || function->name == "grouping" || function->name == "untuple")
            continue;
        if (AggregateFunctionFactory::instance().isAggregateFunctionName(function->name))
            continue;
        if (auto resolver = FunctionFactory::instance().tryGet(function->name, context))
        {
            /// Only calls that analysis can fold matter: a non-deterministic function
            /// over non-constant arguments is executed per row by the cached plan
            /// exactly as by a freshly planned one.
            if (!resolver->isDeterministic() && allArgumentsAreLiterals(*function))
                return true;
            continue;
        }
        /// SQL user defined functions are inlined during analysis: scan the body with
        /// the same rule (cycle-guarded). Anything else — executable user defined
        /// functions, unknown names — is conservatively treated as volatile.
        if (auto create_function_query = UserDefinedSQLFunctionFactory::instance().tryGet(function->name))
        {
            if (!visited_udfs.emplace(function->name).second)
                continue;
            const auto * create_function = create_function_query->as<ASTCreateSQLFunctionQuery>();
            if (!create_function || !create_function->function_core
                || containsVolatileConstants(create_function->function_core.get(), context, visited_udfs))
                return true;
            continue;
        }
        return true;
    }
    return false;
}

bool selectContainsAnalysisTimeVolatileConstants(const ASTPtr & select_query, const ContextPtr & context)
{
    NameSet visited_udfs;
    return containsVolatileConstants(select_query.get(), context, visited_udfs);
}

}
