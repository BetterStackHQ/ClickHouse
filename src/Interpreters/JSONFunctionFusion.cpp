#include <Interpreters/ActionsDAG.h>

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
    void updateHash(SipHash & hash) const override { hash.update(index); }
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
};

}

void ActionsDAG::fuseJSONFunctions(const std::unordered_set<const Node *> & lazy_executed_nodes)
{
    /// Group the fusable calls by the node that produces their document, in the order the calls were added.
    std::unordered_map<const Node *, std::vector<FusableCall>> groups;
    NodeRawConstPtrs documents;

    for (auto & node : nodes)
    {
        /// A node with a column is a folded constant, and a lazily executed node (an argument of a
        /// short-circuit function) runs on a subset of the rows: fusing it would parse documents it skips.
        if (node.type != ActionType::FUNCTION || !node.function_base || node.column || node.children.empty()
            || lazy_executed_nodes.contains(&node))
            continue;

        const auto * fusable = dynamic_cast<const IJSONFusableFunction *>(node.function_base.get());
        if (!fusable)
            continue;

        /// A constant document is parsed once per block already (the default implementation for constants).
        const Node * document = node.children.front()->getWithoutAlias();
        if (document->column)
            continue;

        ColumnsWithTypeAndName arguments;
        arguments.reserve(node.children.size());
        for (const auto * child : node.children)
            arguments.emplace_back(child->column, child->result_type, child->result_name);

        if (!fusable->isFusable(arguments))
            continue;

        auto [it, inserted] = groups.try_emplace(document);
        if (inserted)
            documents.push_back(document);
        it->second.push_back({&node, std::move(arguments)});
    }

    for (const auto * document : documents)
    {
        auto & group = groups[document];
        if (group.size() < 2)
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
        /// not change. The former constant arguments stay in the DAG as unreferenced nodes.
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
    }
}

}
