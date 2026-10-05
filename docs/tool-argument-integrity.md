# Canonical tool argument integrity

The existing `ToolArgumentIntegrity` qualifies as a pure semantic. It distinguishes complete serialized JSON (`valid`), parse failure (`malformed_json`), and a complete non-object function-input root (`non_object_json`). It says nothing about schema validity, target applicability, permission, lifecycle, routing or execution success.

## Canonical move

The real enum moves from `core/shared/types.zig` to `core/agent/tool_argument_integrity.zig`, importing only std. Its existing `classifySerialized` and `classifyFunctionInput` methods move intact, including JSON parsing, duplicate/trailing-input behavior, object-root check, parser allocation-error propagation and temporary parsed-value cleanup. There is no new classifier, duplicate enum, old-name export alias or projection layer.

`ToolCall.argument_integrity`, protocol accumulators/classified argument fields, and other existing owners reference this canonical type directly. Consumers that previously used `types.ToolArgumentIntegrity` import the neutral module instead. Session/protocol files change only imports and type references: storage schemas and provider implementations are not redesigned.

## Producer and consumer classification

Construction uses the std JSON parser and, for function input, a root-object check. It does not inspect tool registry, schema metadata, filesystem/project state, authority, provider identity, accounts, workers, history or results.

Protocol readers and replay/session decoding retain their existing classification calls. Tool preparation, lifecycle, permission/error presentation, tool batching, retry handling and history serialization consume the semantic, but do not define or alter its meanings. Those downstream consequences do not turn a JSON-integrity label into a permission or lifecycle decision.

The surrounding `ToolArgumentDiagnostic`, raw serialized arguments, tool names/IDs, schemas, registry metadata, preparation/admission/permission structures, route/vision/lifecycle blocks, execution/results, history/replay and provider transport remain outside. Classification owns no payload. Its unchanged parser methods allocate temporary std JSON state and release it exactly as before.

## Verification and limits

Existing integrity tests move alongside the canonical type: complete object/non-object roots, malformed/truncated/trailing/duplicate-key JSON and allocation-error propagation. The independent neutral module also verifies the exact three enum tags. Existing argument/preparation/tool/parallel/permission/orchestrator/Agent/worker coverage remains in its original execution tests.

The unchanged whole-agent guard remains diagnostic. Moving this type does not remove the broader shared-types/worker/orchestrator/host closure. No guard roots, patterns, exclusions or categories are changed.

The known broad allocation-sweep abort at unchanged tool_host.zig:938 remains out of scope. No full repository suite, broad allocation sweep or exact Linux/macOS CI success is claimed. fx and PR3 are not fully neutral.

Observed validation: Debug build, 53 configured-provider tests, 801 focused argument/preparation/tool/parallel/orchestrator/Agent/worker tests (including canonical-owner and existing permission coverage), five independent integrity tests, formatting/whitespace/public-surface/compactor checks, and real-binary PTY smoke passed. One fuzz-capable test was discovered; no separate fuzz campaign is claimed. Guard is byte-for-byte unchanged at 1,509 → 1,509. Required CI remains unverified.
