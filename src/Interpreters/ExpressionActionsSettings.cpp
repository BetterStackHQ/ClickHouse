#include <Interpreters/ExpressionActionsSettings.h>

#include <Core/Settings.h>
#include <Interpreters/Context.h>

namespace DB
{
namespace Setting
{
    extern const SettingsBool compile_expressions;
    extern const SettingsShortCircuitFunctionEvaluation short_circuit_function_evaluation;
    extern const SettingsUInt64 max_temporary_columns;
    extern const SettingsUInt64 max_temporary_non_const_columns;
    extern const SettingsUInt64 min_count_to_compile_expression;
    extern const SettingsBool enable_lazy_columns_replication;
    extern const SettingsBool fuse_json_functions;
}

ExpressionActionsSettings::ExpressionActionsSettings(const Settings & from, CompileExpressions compile_expressions_)
{
    can_compile_expressions = from[Setting::compile_expressions];
    min_count_to_compile_expression = from[Setting::min_count_to_compile_expression];
    max_temporary_columns = from[Setting::max_temporary_columns];
    max_temporary_non_const_columns = from[Setting::max_temporary_non_const_columns];
    compile_expressions = compile_expressions_;
    short_circuit_function_evaluation = from[Setting::short_circuit_function_evaluation];
    enable_lazy_columns_replication = from[Setting::enable_lazy_columns_replication];
    /// Like compilation, only in the actions that execute a query: the actions of a storage (a sorting key,
    /// an index, a TTL) are read back as a DAG by the index analysis and must keep their original nodes.
    /// `ReadFromMergeTree` sets it for its `PREWHERE` actions on its own.
    fuse_json_functions = compile_expressions_ == CompileExpressions::yes && from[Setting::fuse_json_functions];
}

ExpressionActionsSettings::ExpressionActionsSettings(ContextPtr from, CompileExpressions compile_expressions_)
    : ExpressionActionsSettings(from->getSettingsRef(), compile_expressions_)
{
}

}
