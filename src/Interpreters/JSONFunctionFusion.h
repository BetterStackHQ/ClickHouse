#pragma once

#include <Interpreters/ActionsDAG.h>
#include <Interpreters/ExpressionActionsSettings.h>

#include <unordered_set>

namespace DB
{

/// The nodes that produce the documents of the `JSON*` calls under `root` that `ActionsDAG::fuseJSONFunctions` fuses.
std::unordered_set<const ActionsDAG::Node *> getFusableJSONDocuments(const ActionsDAG::Node & root);

/// Whether the atoms of a conjunction that read one JSON document are kept in one expression, where
/// `ActionsDAG::fuseJSONFunctions` parses the document once for them (`fuse_json_functions`). Only with
/// short-circuit evaluation: `and` then evaluates every atom after the first on the rows the atoms in
/// front of it passed, which the split of a conjunction into one filter per atom is there to guarantee
/// (`guard(x) AND throwing(x)`); with it disabled, one expression would evaluate every atom on every row.
bool fuseJSONFunctionsAcrossAtoms(const ExpressionActionsSettings & settings);

}
