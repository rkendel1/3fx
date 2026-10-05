# Canonical tool argument diagnostic

The existing `ToolArgumentDiagnostic.Failure` classification distinguishes truncated JSON, scanner syntax errors, and complete syntax rejected by the parser (for example, duplicate object keys). Its meaning requires only std JSON scanning, not schema metadata, routing, authority, lifecycle, execution, provider identity, or host state.

## Mechanical move

Move the existing owning `ToolArgumentDiagnostic` definition from `core/shared/types.zig` to `core/agent/tool_argument_diagnostic.zig`. Keeping the nested enum with its existing positional payload and classifier preserves the public shape without inventing a new name or a projection. The classifier and payload definition are unchanged. There is no old public export, compatibility alias, duplicate enum, or wrapper.

The payload contains a failure tag, received byte count, and optional byte offset. It owns no argument bytes. The classifier releases the scanner nesting stack and propagates allocation failure as before. Existing pure diagnostic tests and the fuzz-capable test move with the definition. The ToolCall copy test stays with its owner. Additional tests check the exact existing enum tags and canonical ToolCall field type.

## Construction and consumption

`gateway/client.zig:appendSerializedToolArguments` diagnoses rejected serialized input before replacing its bytes with `{}`. `runtime/lifecycle.zig:prepareToolCallFromCheckpoint` diagnoses raw malformed input when it has not already been classified. Both now import the canonical owner directly; provider parsing and lifecycle behavior are unchanged.

`ToolCall.argument_diagnostic` carries the positional value. `dupeToolCall` preserves it. `tool_result_errors.zig:malformedToolArgumentsJson` consumes the tag and positions to produce existing repair feedback without quoting rejected bytes. Preparation and orchestration retain their current block, permission, and dispatch consequences. Those consequences do not define JSON scanner failure categories.

## Remaining seams

`ToolStatus` is constructed from `ToolExecutionStatus` by orchestration and carried into terminal feedback. Its success/failure labels describe a tool result, not an independent input classification, so it stays in preparation.

`Result` distinguishes terminal output from an execution candidate and owns their payloads. `ToolCallValidationResult` includes registry absence and a validation witness with MCP runtime generation. File-mutation preparation/decode/admission tags carry mutation-contract, target, or admission meaning. These are not neutral classifications under this extraction's rules.

CandidateKind, legacy target resolution, RegisteredTargetPreparation, and PreparedToolBlockKind remain rejected. ToolPreparationTerminalKind and ToolArgumentIntegrity remain canonical. No broader tool-preparation neutralization or PR3 completion is attempted.

## Validation

Validation results are recorded in the PR description. The architecture guard remains byte-for-byte unchanged; its whole-agent output remains diagnostic, not a completion claim. The known tool_host.zig allocation-failure issue, broad allocation sweep, full repository suite, and Linux/macOS CI are outside local validation claims.
