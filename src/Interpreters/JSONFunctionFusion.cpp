#include <Interpreters/JSONFunctionFusion.h>

#include <stack>

#include <Columns/ColumnConst.h>
#include <Columns/ColumnTuple.h>
#include <Common/ProfileEvents.h>
#include <Common/assert_cast.h>
#include <DataTypes/DataTypeTuple.h>
#include <Functions/JSONFunctionFusion.h>

#include <fmt/format.h>

namespace ProfileEvents
{
    extern const Event JSONFunctionsFused;
}

namespace DB
{

namespace
{

/// `(Tuple) -> element` of a fused result: the element column itself, not a copy.
class ExecutableFunctionJSONFusedElement final : public IExecutableFunction
{
public:
    explicit ExecutableFunctionJSONFusedElement(size_t index_) : index(index_) {}

    String getName() const override { return "__jsonFusedElement"; }
    bool useDefaultImplementationForConstants() const override { return true; }
    /// The element is returned as the member produced it, also when it is or contains `LowCardinality`.
    bool useDefaultImplementationForLowCardinalityColumns() const override { return false; }

    ColumnPtr executeImpl(const ColumnsWithTypeAndName & arguments, const DataTypePtr &, size_t) const override
    {
        return assert_cast<const ColumnTuple &>(*arguments[0].column).getColumnPtr(index);
    }

private:
    size_t index;
};

class FunctionBaseJSONFusedElement final : public IFunctionBase
{
public:
    FunctionBaseJSONFusedElement(const DataTypePtr & tuple_type, size_t index_)
        : argument_types{tuple_type}
        , result_type(assert_cast<const DataTypeTuple &>(*tuple_type).getElement(index_))
        , index(index_)
    {
    }

    String getName() const override { return "__jsonFusedElement"; }
    const DataTypes & getArgumentTypes() const override { return argument_types; }
    const DataTypePtr & getResultType() const override { return result_type; }
    bool isSuitableForShortCircuitArgumentsExecution(const DataTypesWithConstInfo &) const override { return true; }

    ExecutableFunctionPtr prepare(const ColumnsWithTypeAndName &) const override
    {
        return std::make_unique<ExecutableFunctionJSONFusedElement>(index);
    }

private:
    DataTypes argument_types;
    DataTypePtr result_type;
    size_t index;
};

struct FusableCall
{
    ActionsDAG::Node * node;
    ColumnsWithTypeAndName arguments;
    bool lazy_executed;
};

const ActionsDAG::Node * getFusableJSONDocument(const ActionsDAG::Node & node, ColumnsWithTypeAndName & arguments)
{
    /// A node with a column is a folded constant.
    if (node.type != ActionsDAG::ActionType::FUNCTION || !node.function_base || node.column || node.children.empty())
        return nullptr;

    const auto * fusable = dynamic_cast<const IJSONFusableFunction *>(node.function_base.get());
    if (!fusable)
        return nullptr;

    /// A constant document is parsed once per block already (the default implementation for constants).
    const ActionsDAG::Node * document = node.children.front();
    while (document->type == ActionsDAG::ActionType::ALIAS)
        document = document->children.front();
    if (document->column)
        return nullptr;

    arguments.clear();
    arguments.reserve(node.children.size());
    for (const auto * child : node.children)
        arguments.emplace_back(child->column, child->result_type, child->result_name);

    if (!fusable->isFusable(arguments))
        return nullptr;

    return document;
}

}

const ActionsDAG::Node * ActionsDAG::getFusableJSONDocument(const Node & node)
{
    ColumnsWithTypeAndName arguments;
    return DB::getFusableJSONDocument(node, arguments);
}

std::unordered_set<const ActionsDAG::Node *> getFusableJSONDocuments(const ActionsDAG::Node & root)
{
    std::unordered_set<const ActionsDAG::Node *> documents;
    std::stack<const ActionsDAG::Node *> nodes;
    nodes.push(&root);
    std::unordered_set<const ActionsDAG::Node *> visited{&root};
    while (!nodes.empty())
    {
        const auto * node = nodes.top();
        nodes.pop();

        if (const auto * document = ActionsDAG::getFusableJSONDocument(*node))
            documents.insert(document);

        for (const auto * child : node->children)
            if (visited.insert(child).second)
                nodes.push(child);
    }
    return documents;
}

bool fuseJSONFunctionsAcrossAtoms(const ExpressionActionsSettings & settings)
{
    return settings.fuse_json_functions && settings.short_circuit_function_evaluation != ShortCircuitFunctionEvaluation::DISABLE;
}

void ActionsDAG::fuseJSONFunctions(const std::unordered_set<const Node *> & lazy_executed_nodes)
{
    /// Group the fusable calls by the node that produces their document, in the order the calls were added.
    std::unordered_map<const Node *, std::vector<FusableCall>> groups;
    NodeRawConstPtrs documents;

    for (auto & node : nodes)
    {
        ColumnsWithTypeAndName arguments;
        const Node * document = DB::getFusableJSONDocument(node, arguments);
        if (!document)
            continue;

        auto [it, inserted] = groups.try_emplace(document);
        if (inserted)
            documents.push_back(document);
        it->second.push_back({&node, std::move(arguments), lazy_executed_nodes.contains(&node)});
    }

    bool fused_any = false;
    for (const auto * document : documents)
    {
        auto & group = groups[document];
        if (group.size() < 2)
            continue;

        /// A lazily executed call (an argument of a short-circuit function) runs on a subset of the rows:
        /// a group of such calls alone would parse the documents they skip. Next to a call that runs on
        /// every row the document is parsed for every row anyway, so the lazily executed call joins the
        /// group: only its extraction runs on more rows, which is cheap next to the parse and cannot throw.
        /// Its node stays lazily executed and takes the element of the fused result on the rows it is
        /// asked for.
        if (std::ranges::all_of(group, [](const auto & call) { return call.lazy_executed; }))
            continue;

        const bool uses_simdjson = dynamic_cast<const IJSONFusableFunction &>(*group.front().node->function_base).usesSimdJSON();
        bool same_parser = true;
        for (const auto & call : group)
            same_parser &= dynamic_cast<const IJSONFusableFunction &>(*call.node->function_base).usesSimdJSON() == uses_simdjson;
        if (!same_parser)
            continue;

        std::vector<JSONFusedMemberCall> members;
        members.reserve(group.size());
        for (auto & call : group)
            members.push_back({call.node->function_base, std::move(call.arguments)});

        const Node & fused_node = addFunction(
            createFusedJSONFunction(std::move(members)), {document}, fmt::format("__jsonFused({})", document->result_name));

        /// Each member is rewritten in place into the element of the fused result that its `Impl` produced,
        /// so every pointer to it (outputs, other nodes' children) stays valid; its result name and type do
        /// not change.
        ColumnsWithTypeAndName fused_arguments;
        fused_arguments.emplace_back(fused_node.column, fused_node.result_type, fused_node.result_name);
        for (size_t i = 0; i < group.size(); ++i)
        {
            auto element = std::make_shared<FunctionBaseJSONFusedElement>(fused_node.result_type, i);
            Node & node = *group[i].node;
            node.function = element->prepare(fused_arguments);
            node.function_base = std::move(element);
            node.children = {&fused_node};
        }

        ProfileEvents::increment(ProfileEvents::JSONFunctionsFused, group.size());
        fused_any = true;
    }

    /// The former constant arguments of the members are unreferenced now; every node left in the DAG is
    /// still executed, so drop them, as `compileExpressions` does after compilation.
    if (fused_any)
        removeUnusedActions(/*allow_remove_inputs = */ false);
}

}
