# Canonical final tool identity

The existing `FinalToolIdentity` qualifies as a pure identity-value classification. Its four existing tags are `valid`, `absent`, `empty`, and `wrong_type`. They describe presence and string shape, not whether a tool exists, a call matches an earlier call, an action is authorized, or a result succeeded.

## Definition, construction, and consumption

Move the real enum definition from `core/shared/types.zig` into `core/agent/final_tool_identity.zig` unchanged. The enum has no payload, methods, allocations, or existing standalone pure tests. A module test verifies its existing tag names and integer values. A ToolCall field-type test verifies the canonical owner. Existing integration tests remain with their consumers.

The unchanged gateway helper `finalToolIdentity` classifies an optional std JSON value: absence produces `absent`, a non-string produces `wrong_type`, an empty string produces `empty`, and a nonempty string produces `valid`. The gateway retains this helper and all control flow. Its diff consists only of the canonical import and type-reference substitutions.

`authoritativeToolAdmission` also labels a whitespace-only call ID `empty` using std string trimming. This is an existing construction of the value classification, not a claim that the call is admitted. The same function performs separate uniqueness, storable-length/UTF-8, provenance, argument, and result checks. A `valid` identity can fail any of those checks.

Gateway consumers use the classification before matching or reconciling calls and results. `ToolCall` carries it; `dupeToolCall` preserves it. `ConversationToolCall` references the canonical type directly, with no session schema or persistence behavior change. Orchestration consumes admission results as before. Matching, admission, provider, lifecycle, history, and execution consequences remain in their existing owners.

There is no old public export, alias, wrapper, projection, duplicate enum, or compatibility layer. All payload ownership and allocation behavior remain unchanged. ToolPreparationTerminalKind, ToolArgumentIntegrity, and ToolArgumentDiagnostic are untouched.

## Rejected surrounding classifications

- `ToolStatus` and `ToolExecutionStatus` describe result success/failure.
- `Result` and `PreparedToolCall` distinguish preparation/execution/lifecycle paths and own their payloads.
- `ToolCallValidationResult` encodes registry absence and a witness with runtime generation.
- `ToolOutputClassification` encodes structured execution, legacy failure, and adapter failure meanings.
- `ToolExecutionProvenance` and `ProviderResultIdentityFailure` encode execution origin and result reconciliation, not string shape.
- `ConversationIdentity.Failure` includes a 256-byte storable-identity policy; its size boundary is not a general string-integrity fact.
- `ToolArgumentSource` distinguishes final input from streamed fallback. `FinalToolInputState` participates in provider final-input reconstruction; moving its classifier would also exceed the gateway import/type-only rule.
- CandidateKind, target applicability, RegisteredTargetPreparation, and PreparedToolBlockKind retain their previously rejected meanings.

No replacement abstractions are introduced. The remaining seams continue to require examination of existing semantics, rather than broad preparation neutralization.

## Validation limits

Local validation passed: Debug build, 278 focused tests, 53 configured-provider e2e tests, one independent enum test, formatting/whitespace/public-surface/compactor checks, and the neutral model boundary. Guard SHA-256 remains 365d5a1d8fb69bffca1cca3b3c849bab9caf95fd4b589241cb1a512447128bce, with 1,509 whole-agent diagnostic violations. PTY smoke exercised a healthy configured-provider request and adapter rejection of an empty call ID; it did not exercise the canonical final-identity classifier directly. Architecture guard rules remain unchanged. No full repository suite, broad allocation sweep, Linux/macOS CI, ship-gate success, PR3 completion, or full tool-preparation neutrality is claimed. The previously reproduced app_render_runtime lifecycle baseline failure and tool_host.zig allocation-failure issue are not modified.
