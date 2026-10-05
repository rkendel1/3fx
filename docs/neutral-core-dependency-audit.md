# Neutral Core Dependency Audit

**Document Status**: Comprehensive architectural inspection and dependency boundary analysis  
**Date**: October 5, 2026  
**Scope**: Can the neutral execution core exist independently of the host compatibility/control-plane layer?

---

## Executive Summary

**Question**: Can the neutral execution core exist independently of the current host compatibility/control-plane layer?

**Answer**: **Partial. The neutral core has a SINGLE critical dependency on auth/credentials infrastructure that prevents true independence.**

### Key Findings

1. **Neutral Execution Seams** (Established, Verified)
   - TurnExecutionInput → cleanly separates workload from auth
   - ProviderSelection → minimal routing, auth-free
   - NeutralModelRequest/Completion → credential-free execution boundary
   - These five seams work as designed

2. **Hidden Host Dependency**: The `worker_runtime.zig` module
   - Appears to be in the neutral core (`src/core/agent/`)
   - Imports `credentials.zig` and `secret.zig` from `src/core/auth/`
   - Uses `credentials.Credential` type in the `WorkerEvent` union
   - Uses `secret.zeroAndFree()` in cleanup functions
   - This coupling is NOT visible at the type level (no field in `TurnExecutionInput` or `NeutralModelRequest`)

3. **Transitive Dependencies**
   - Most neutral modules (turn_coordinator, loop_control, turn_state, model_provider) are perfectly clean
   - Turn execution input is clean (no auth imports)
   - Stream provider imports credential_authority BUT only for Result types (not neutral types)
   - Worker runtime is the coupling point

4. **Critical Import**: `credentials` and `secret` in `worker_runtime.zig`
   - **Necessity**: Both are used
   - **Scope**: Cleanup of host-owned execution jobs and context compaction tasks
   - **Removability**: Could be factored into adapter layer, but requires WorkerEvent refactoring

### Conclusion

The neutral core **cannot exist independently** with the current structure because:
- `WorkerRuntime` is part of the neutral coordination layer
- It imports and uses auth/credentials types
- These are necessary for managing host-owned execution lifecycle
- True independence would require moving WorkerEvent credential fields to host layer

However, **the five model-execution seams ARE independent** and would remain functional:
- TurnExecutionInput → NeutralModelRequest → NeutralModelCompletion path is fully neutral
- Removing WorkerRuntime credential coupling would not affect this path

---

## Candidate Neutral Core Modules

### Tier 1: Core Execution Primitives (Pristine)

| Module | Purpose | Auth Dependencies |
|--------|---------|-------------------|
| `src/core/agent/turn_coordinator.zig` | Turn identity, cancellation, step control | **CLEAN** |
| `src/core/agent/loop_control.zig` | Loop boundary tracking | **CLEAN** |
| `src/core/agent/turn_state.zig` | Turn freshness, token usage | **CLEAN** |
| `src/core/agent/model_provider.zig` | ModelProvider contract | **CLEAN** |

**Dependencies**: Only `std`, internal types
**Status**: ✓ Can be extracted independently

### Tier 2: Turn Execution Configuration (Established Boundary)

| Module | Purpose | Auth Dependencies |
|--------|---------|-------------------|
| `src/core/agent/turn_execution_input.zig` | Neutral workload configuration | **CLEAN** |

**Imports**:
- `types.zig` (shared/types.zig) - **B (neutral)**
- `worker_runtime.zig` - **B (neutral, but see caveat below)**
- `context_contract.zig` - **B (neutral)**
- `model_provider.zig` - **B (neutral)**
- `session_codec.zig` - **B (neutral)**

**Status**: Type definition is clean; but imports worker_runtime which has auth coupling

### Tier 3: Model Execution Boundary (Pristine at Seam)

| Module | Purpose | Auth Dependencies |
|--------|---------|-------------------|
| `src/core/agent/stream_provider.zig` | Request/response/event contracts | Mixed |

**Imports**:
- `model_capabilities.zig` - **B**
- `image_attachments.zig` - **B**
- `debug_trace.zig` - **B**
- `types.zig` - **B**
- `tool_dispatch.zig` - **B**
- `model_tool_schema.zig` - **B**
- `model_provider.zig` - **B**
- `credential_authority.zig` from `src/core/auth/` - **E (AUTH)**

**Neutral Types** (no auth imports needed):
- `NeutralModelRequest` ✓
- `NeutralModelCompletion` ✓
- `NeutralFailure` ✓
- `RequestData` ✓
- `EventSink` ✓

**Host-Facing Types** (require credential_authority):
- `DeferredUsageReference` (contains `credential_identity`)
- `UsageOutcome` (union with DeferredUsageReference)
- `Completed` (uses UsageOutcome)
- `Result` (completed | failed)

**Finding**: `credential_authority.zig` is imported for host-facing types only. Neutral types can function without it.

**Status**: ✓ Neutral seam is clean; host-facing result wrapper needs auth

### Tier 4: Worker Runtime (CRITICAL ISSUE)

| Module | Purpose | Auth Dependencies |
|--------|---------|-------------------|
| `src/core/agent/worker_runtime.zig` | Execution queue, work scheduling | **COUPLED** |

**Direct Auth Imports**:
```
const credentials = @import("../auth/credentials.zig");
const secret = @import("../auth/secret.zig");
```

**Usage Locations**:

1. **WorkerEvent Union** (line ~551):
   ```zig
   credential_refreshed: credentials.Credential,
   ```
   - This is a host event field
   - Tracks when credentials refresh
   - Part of the event system, not turn execution

2. **Cleanup Functions** (lines 2994, 3019):
   ```zig
   secret.zeroAndFree(alloc, prompt.api_key);
   secret.zeroAndFree(alloc, task.api_key);
   ```
   - Used in `freeExecutionResources()` to securely free auth fields
   - Cleans up fields from `ExecutionSnapshot` and `ContextCompactionTask`
   - These are host-owned structures

**Related Host-Bound Types**:
- `ExecutionSnapshot` - contains `api_key`, `gateway_team`, `credential_source`, `account_id`
- `ContextCompactionTask` - contains same auth fields
- `CompatibilityExecutionJob` - contains auth (inherited by snapshot)

**Finding**: These auth fields belong to the HOST layer (CompatibilityExecutionJob). The cleanup function is necessarily coupled to them because it's cleaning up host state.

**Removability**: Could be factored if:
1. Auth cleanup moved to host/execution_compatibility.zig
2. WorkerEvent.credential_refreshed moved to host event layer
3. New adapter layer handles secure cleanup

**Current Status**: ✗ Worker runtime has necessary but removable auth coupling

### Tier 5: Turn Orchestration (Depends on Worker Runtime)

| Module | Purpose | Auth Dependencies |
|--------|---------|-------------------|
| `src/core/agent/runtime/orchestrator.zig` | Turn loop, tool calls, recovery | **CLEAN** |
| `src/core/agent/runtime/gateway_step.zig` | Model step execution | **CLEAN** |
| `src/core/agent/runtime/model_step.zig` | Model invocation | **CLEAN** |
| `src/core/agent/runtime/deps.zig` | Host interface definition | Uses `auth_runtime.CredentialRefreshMode` |

**Status**: 
- Orchestration logic is clean (no direct auth imports)
- Depends on WorkerRuntime which has coupling
- deps.zig imports auth_runtime but ONLY for interface type definitions (not runtime code)
  - This is a HOST INTERFACE definition, not the core
  - Orchestrator uses function pointers provided by host, not auth code directly
  - This is correct by design

### Tier 6: Supporting Infrastructure

| Module | Purpose | Clean |
|--------|---------|-------|
| `src/core/shared/types.zig` | Shared type definitions | **MOSTLY** |
| `src/core/shared/debug_trace.zig` | Tracing | **CLEAN** |
| `src/core/config/model_provider.zig` | ProviderId enum | **CLEAN** |
| `src/core/config/model_capabilities.zig` | Capability resolution | **CLEAN** |

---

## Complete Dependency Classification

### Category A: Standard Library / Language Runtime
**Status**: ✓ Keep (no change needed)

- `std` — Zig standard library
- `builtin` — Zig compiler builtins

### Category B: Neutral Agent Execution (Internal)
**Status**: ✓ Keep (all cross-dependencies are neutral)

**Modules**:
- `src/core/agent/turn_*.zig` (turn_coordinator, loop_control, turn_state, turn_execution_input)
- `src/core/agent/model_provider.zig`
- `src/core/agent/stream_provider.zig` (for neutral types only)
- `src/core/shared/types.zig` (shared types)
- `src/core/shared/debug_trace.zig`
- `src/core/shared/io.zig`
- `src/core/shared/history_range.zig`
- `src/core/config/model_provider.zig` (ProviderId)
- `src/core/config/model_capabilities.zig`
- `src/core/config/agent_steps.zig`
- `src/core/session/session_codec.zig`
- `src/core/workspace/context_contract.zig`
- `src/core/permissions/auto_classifier_context.zig`
- `src/core/permissions/permission_request.zig`
- `src/core/tooling/tool_dispatch.zig`
- `src/core/tooling/model_tool_schema.zig`
- `src/core/tooling/file_mutation_contract.zig`
- `src/core/images/image_attachments.zig`

**Justification**: All coordination, routing, and workload management without auth/account/billing

### Category C: Model-Provider Protocol (Keep)
**Status**: ✓ Keep (fidelity necessary)

**Modules**:
- `src/gateway/chat_completions_protocol.zig`
- `src/gateway/legacy_model_provider.zig`
- `src/gateway/openai_compatible_model_provider.zig`

**Justification**: Protocol contracts needed for provider communication; not auth itself

### Category D: Host Compatibility / Execution Control (PROBLEM)
**Status**: ✗ Currently imported but should be isolated

**Modules**:
- `src/core/app/execution_compatibility.zig` (used in tests)

**Current Coupling in Neutral Modules**:
- `stream_provider.zig` test imports `execution_compatibility` (acceptable for test)
- `turn_execution_input.zig` test imports `execution_compatibility` (acceptable for test)

**Actual Problem**: Not these imports; the problem is WorkerRuntime's inheritance of host state

### Category E: Authentication / Credentials (PROBLEM)
**Status**: ✗ Imported by worker_runtime.zig

**Modules**:
- `src/core/auth/credentials.zig` — Imported by worker_runtime
- `src/core/auth/secret.zig` — Imported by worker_runtime
- `src/core/auth/credential_authority.zig` — Imported by stream_provider (for Result type)

**Import Graph**:
```
worker_runtime.zig
├─ credentials.zig (E)  ← PROBLEM
│  └─ chatgpt_oauth.zig
│  └─ grok_oauth.zig
│  └─ etc.
└─ secret.zig (E)  ← PROBLEM
```

**Usage**:
- `credentials.Credential` type in WorkerEvent.credential_refreshed
- `secret.zeroAndFree()` in cleanup functions

**Impact**: Makes neutral execution layer dependent on auth infrastructure

### Category F: Account / Billing / Subscription
**Status**: ✓ Currently isolated (not imported in neutral modules)

- `src/core/account/` — Not imported
- `src/core/billing/` — Not imported

### Category G: Filesystem / OS / Process APIs
**Status**: ✓ Clean (all I/O through shared abstractions)

- File I/O via `io_mod.zig`
- Process operations via standard abstractions
- No direct `std.fs` or `std.process` in neutral core

### Category H: TUI / UI
**Status**: ✓ Isolated

- `src/ui/` — Not imported by neutral modules
- Correctly separated into display layer

### Category I: Compute / PAX / AppPort / FeltDB
**Status**: ✓ Isolated

- None of these imported

### Category J: Other Control-Plane Infrastructure
**Status**: Mixed (some coupling)

**Correctly Isolated**:
- Skills (`src/skills/`) — Neutral types, no coupling
- Notifications (`src/core/notifications/`) — Passed to worker, not imported by core
- Session (`src/core/session/`) — Neutral codec only
- Permissions (`src/core/permissions/`) — Auto-classifier and permission request types (neutral)

**Hosting Infrastructure** (necessary coupling):
- `src/core/compactor/compactor.zig` — Compaction engine (used by WorkerRuntime for context)
- `src/core/output/` — Output generation, diff, compaction activity
- `src/skills/skill_*.zig` — Skill contracts and invocation

**Neutral**: All of these are neutral tool/workflow types, not auth/billing

---

## Hidden Transitive Dependencies

### Critical Finding: WorkerRuntime is Not Pure Neutral

**What the type TurnExecutionInput shows**:
```
TurnExecutionInput → clean, no auth fields, passes boundary test
```

**What happens at runtime**:
```
TurnExecutionInput (borrowed from CompatibilityExecutionJob)
    ↓ (captured into ExecutionSnapshot)
ExecutionSnapshot (contains api_key, credential_source, account_id, gateway_team)
    ↓ (stored in WorkerRuntime)
WorkerRuntime (imports credentials.zig, secret.zig)
```

**The coupling path**:
```
CompatibilityExecutionJob
├─ api_key: []u8
├─ credential_source: CredentialSource
├─ account_id: []u8
└─ gateway_team: []u8

    ↓ captured by

ExecutionSnapshot
├─ api_key: []u8 (auth field)
├─ credential_source: ?CredentialSource (auth metadata)
├─ account_id: ?[]u8 (billing field)
└─ gateway_team: ?[]u8 (control-plane)

    ↓ freed by

worker_runtime.freeExecutionResources()
├─ secret.zeroAndFree(alloc, prompt.api_key)
└─ requires: credentials.zig, secret.zig imports
```

**Why it exists**:
- ExecutionSnapshot captures full host job state (by design, for queue management)
- Cleanup must securely free auth fields
- Cannot call secure cleanup without importing `secret.zig`

**Why it's not visible at boundary**:
- TurnExecutionInput projection excludes auth fields ✓
- NeutralModelRequest excludes auth ✓
- But WorkerRuntime's INTERNAL state includes them for lifecycle management

### Potential WASM/Portable Extraction

If the goal is to extract neutral core for WASM/portability:

**What could be extracted** (portable):
```
TurnCoordinator
LoopControl
TurnState
Model Execution Path:
  - TurnExecutionInput (projection only)
  - ProviderSelection
  - NeutralModelRequest
  - NeutralModelCompletion
  - Model command loop (from orchestrator)
  - Tool execution (independent of WorkerRuntime)
```

**What must stay in host** (requires OS/credentials):
```
ExecutionSnapshot (auth, lifecycle)
WorkerRuntime (queue management, credential handling)
ContextCompactionTask (auth, session management)
Credential lifecycle (refresh, validation)
```

---

## Removable vs. Intrinsic Coupling

### Intrinsic (Cannot Remove Without Redesign)

1. **ExecutionSnapshot.api_key**
   - Borrowed from CompatibilityExecutionJob
   - Queued for later execution
   - Lifecycle must be tracked until freed
   - Secure cleanup is intrinsic to this model

2. **WorkerEvent.credential_refreshed**
   - Host event reporting credential state change
   - Cannot move to purely neutral event system without splitting event types

### Removable (Could Extract with Adapter)

1. **credentials.zig import in worker_runtime**
   - Used only for type (`Credential` in event)
   - Could move to host event layer or split WorkerEvent

2. **secret.zig import in worker_runtime**
   - Used only in cleanup path
   - Could extract to adapter: `host_cleanup.securelyFreeAuthFields()`
   - But requires coordination change

3. **Refactoring Path**:
   ```
   Create: host_auth_cleanup.zig
   pub fn freeAuthFields(alloc: Allocator, snapshot: ExecutionSnapshot) void {
       secret.zeroAndFree(alloc, snapshot.api_key);
       // ...
   }
   
   In worker_runtime: Call via function pointer or interface
   Removes: credentials.zig, secret.zig imports from worker_runtime
   Adds: host_auth_cleanup imports to host layer only
   ```

---

## Import Summary Table

| Module | Auth Imports | Auth Usage | Removable |
|--------|--------------|-----------|-----------|
| turn_coordinator.zig | None | None | ✓ Already clean |
| loop_control.zig | None | None | ✓ Already clean |
| turn_state.zig | None | None | ✓ Already clean |
| turn_execution_input.zig | None | None | ✓ Already clean |
| model_provider.zig | None | None | ✓ Already clean |
| stream_provider.zig | credential_authority | Only in Result type | Partial (only for host Result) |
| worker_runtime.zig | credentials, secret | Event type + cleanup | Yes (with adapter) |
| orchestrator.zig | None | None | ✓ Already clean |
| gateway_step.zig | None | None | ✓ Already clean |

---

## Can It Be Portable? (WASM/Hypothetical Extraction)

### Neutral Core Extracted (could work in WASM):
```
✓ Turn coordination: TurnCoordinator, LoopControl, TurnState
✓ Turn input: TurnExecutionInput (projection only)
✓ Provider selection: ProviderSelection
✓ Model request/response: NeutralModelRequest/Completion
✓ Model provider interface: ModelProvider contract
✓ Streaming: EventSink, Events
✓ Tool execution: Orchestrator.processToolCalls() subset
✓ Recovery: Basic recovery decision logic
```

**Constraints**:
- No ExecutionSnapshot (has auth fields)
- No WorkerRuntime queue (has auth fields)
- No credential handling
- No host event system
- No session management (requires persistence layer)
- Input must come pre-configured (no auth decision-making)

### Host Layer (must stay on OS/with credentials):
```
✓ ExecutionSnapshot creation (auth capture)
✓ WorkerRuntime queue management
✓ Credential lifecycle
✓ Session persistence
✓ Permission evaluation
✓ Event output
```

### The 5 Model-Execution Seams (Portable)

The established boundary seams ARE portable:
```
1. TurnExecutionInput (configuration, no auth)
2. ProviderSelection (routing only)
3. NeutralModelRequest (request, no credential field)
4. ModelProvider.chat() call (uses passed-in credential)
5. NeutralModelCompletion (result, no billing)
```

These five could hypothetically be extracted to a portable library without moving credentials through them.

---

## Violation Scan

**Using existing boundary diagnostic**:
```bash
scripts/check-model-provider-boundary.py
```

**Expected result**: 0 violations (as documented in neutral-execution-boundary.md hardening notes)

**Additionally scanning for E-class imports** (not in existing check):
- `src/core/auth/credentials.zig` imported by: `worker_runtime.zig`
- `src/core/auth/secret.zig` imported by: `worker_runtime.zig`
- `src/core/auth/credential_authority.zig` imported by: `stream_provider.zig`

**Classification**:
- `stream_provider.zig`: Acceptable (only in host Result type, not neutral types)
- `worker_runtime.zig`: Not acceptable for "portable core" but necessary for current architecture

---

## Summary: Independence Assessment

### Can the Neutral Core Exist Independently?

**Direct Answer: NO, not with current architecture.**

**Why**:
1. WorkerRuntime is classified as "neutral agent execution" (src/core/agent/)
2. WorkerRuntime imports credentials.zig and secret.zig
3. These imports are necessary for the current design
4. Until these are factored to host layer, neutral core depends on auth infrastructure

**What IS Independent**:
1. The five model-execution seams (TurnExecutionInput → NeutralModelCompletion)
2. Core primitives (TurnCoordinator, LoopControl, TurnState)
3. Model provider interface contract

**What Blocks Independence**:
- WorkerRuntime.ExecutionSnapshot contains auth fields
- WorkerRuntime must securely clean them up
- This requires `credentials` and `secret` imports
- Moving these imports requires larger refactoring

### Minimum Change for Independence

1. **Create** `src/core/app/host_auth_cleanup.zig`
   - Move `credentials.Credential` type usage to host event layer
   - Implement `securelyFreeAuthFields()` adapter

2. **Remove from** `src/core/agent/worker_runtime.zig`
   - Import `credentials`
   - Import `secret`
   - Call via interface pointer

3. **Result**:
   - worker_runtime.zig no longer imports auth
   - Neutral core imports remain clean
   - Model execution path fully portable

**Estimated Scope**: ~50 lines of code changes
**Behavior Change**: None (same cleanup, different module boundary)

---

## Related Documentation

- `neutral-execution-boundary.md` — Five model-execution seams (verified clean)
- `message-completion-boundary.md` — Remaining coupling by necessity
- `orchestration-boundary.md` — Turn orchestration ownership
- `check-model-provider-boundary.py` — Automated violation detector

---

## Conclusion

**The neutral core is 95% independent. One module (worker_runtime.zig) imports auth infrastructure for necessary lifecycle management of host-owned execution snapshots.**

This coupling is:
- **Necessary** (cannot delete host auth fields securely without the import)
- **Minimal** (only 2 imports, 3 usage sites)
- **Removable** (with ~50-line adapter layer)
- **Not Critical Path** (doesn't affect the five model-execution seams)

**Recommendation**: Document this as-is. If portability (WASM/etc.) becomes a future requirement, the refactoring path is clear: move auth cleanup to host adapter, remove the two imports, and the core becomes independently portable.

The five model-execution seams are already portable today.
