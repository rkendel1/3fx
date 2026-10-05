# Canonical preparation terminal reason

Inspection found the existing pure `tool_preparation.TerminalKind` classification. It denotes a terminal preparation reason made before permission, visible lifecycle, or execution: `idempotent_skip`, `validation_failure`, `availability_failure`, `unsupported`, or `file_mutation_failure`.

The enum moves to `core/agent/tool_preparation_terminal_kind.zig` as `ToolPreparationTerminalKind`. The old enum and public old name are removed; `Terminal.kind` and the existing callback conversion use the new canonical type directly. There is no second source of truth or alias to the former enum. The neutral module imports only std and has no payload or ownership methods.

This type reports the reason preparation ended. It does not grant authority, classify parallel groups, report execution success, or prescribe lifecycle/finalization. Permission decisions, CandidateKind (including legacy target applicability), PreparedToolBlockKind (lifecycle/vision routing reasons), and payload-bearing preparation/admission results are deliberately not extracted.

`Terminal.model_output` remains its owned optional output; `Terminal.status`, candidate target paths, call IDs/names/arguments, registry metadata, permission/grant/admission structures, scheduler extent and execution/result/history data remain unchanged. Callback preparation retains exactly its old ordering, conversion and status rules. No projection method is necessary because consumers already access the pure kind directly.

Production orchestrator consumers keep their existing inferred-tag switches and comparisons. Only the canonical field type changes; no algorithm or branch mapping changes. Tests in tool_preparation use the new canonical name for expectations.

Tests verify the exact enum surface/tags, unchanged output pointer/content across classifications, single-owner deinit, and existing preparation/parallel/tool/orchestrator/Agent/worker behavior. The neutral module compiles independently without provider, auth, permission, lifecycle, history or queue dependencies.

The whole-agent guard is unchanged. Existing preparation/worker/orchestrator/shared-type/provider/history/recovery/control-plane closures remain reachable; this enum extraction is not tool-system neutralization or completed PR3. The known broader allocation sweep abort at unchanged tool_host.zig:938 remains outside scope. No full repository suite, broad allocation sweep or exact Linux/macOS CI success is claimed.

Observed validation: Debug build, 53 configured-provider tests, 679 focused preparation/parallel/tool/orchestrator/Agent/worker tests, standalone enum test, formatting/whitespace/public-surface/compactor checks and real-binary PTY smoke passed. Guard is byte-for-byte unchanged at 1,509 → 1,509. Required CI remains unverified.
