# Neutral Execution Core

**Status**: Proven independent, build-system enforced  
**Scope**: Durable/streaming model execution orchestration  
**Independence**: 100% free of auth, account, billing, and control-plane infrastructure  

---

## Overview

The neutral execution core is the language-agnostic, credentials-free heart of the fx agent orchestrator. It handles:

- **Turn coordination** — Turn identity, sequencing, cancellation, step tracking
- **Loop control** — Step and turn boundaries
- **Model execution** — Streaming request/response without credentials
- **Tool execution** — Deterministic tool dispatch
- **Recovery** — Model failure handling and retry logic

The core is designed to be **embeddable in any runtime**:
- Native fx host (current)
- Compute-backed host (future, no changes needed)
- Browser/WASM host (future, no changes needed)
- Custom distributed hosts (future, no changes needed)

This document serves as the durable specification of what the core is and what stays outside it.

---

## Core Modules

### Tier 1: Core Execution Primitives (Pristine)

**TurnCoordinator** (`src/core/agent/turn_coordinator.zig`)
- Turn identity, delivery mode (ordinary/active/continuation)
- Cancellation flag for cross-thread signal
- Step and attempt counters
- Zero provider/account/credential fields

**TurnState** (`src/core/agent/turn_state.zig`)
- Conversation-local freshness tracking
- Token usage accumulation (input/output/cache/reasoning)
- Reset behavior between turns
- Zero provider/account fields

**LoopControl** (`src/core/agent/loop_control.zig`)
- Step limit (max steps per turn)
- Turn limit (max turns per session)
- Boundary detection without orchestration knowledge
- Zero provider fields

**ModelProvider** (`src/core/agent/model_provider.zig`)
- Chat interface contract (no vendor coupling)
- Request/response/streaming types (credential-free)
- Message, Tool, ToolCall, Event types (pure data)
- EventSink for streaming (no auth in events)
- Token counting interface
- Delivery tracking (for timeout/cancellation)

### Tier 2: Turn Execution Configuration

**TurnExecutionInput** (`src/core/agent/turn_execution_input.zig`)
- Unified input to orchestrator.execute()
- Conversation messages (no auth embedded)
- Provider selection (routing, not credentials)
- Tool definitions
- Performance settings (reasoning_effort, max_output_tokens)
- Cancellation flag
- ZERO credential fields, account fields, billing fields

**ProviderSelection** (`src/core/agent/turn_execution_input.zig`)
- ProviderId enum (which provider to use)
- Model name (which model to use)
- Routing only, not authentication

### Tier 3: Model Execution Boundary

**NeutralModelRequest** (`src/core/agent/stream_provider.zig`)
- Outbound request from core
- Messages, tools, tool_choice, output tokens limit
- ZERO credential fields

**NeutralModelCompletion** (`src/core/agent/stream_provider.zig`)
- Response from model provider
- Content, tool calls, token usage, finish reason
- ZERO billing/account fields

**NeutralFailure** (`src/core/agent/stream_provider.zig`)
- Error response type
- Message and error reason
- ZERO auth fields

**NeutralEventSink** (`src/core/agent/stream_provider.zig`)
- Streaming callback interface
- NeutralEvent: content_delta or reasoning_delta
- ZERO auth in events

### Tier 4: Worker Runtime

**WorkerRuntime** (`src/core/agent/worker_runtime.zig`)
- Execution queue management
- Turn scheduling and sequencing
- ExecutionSnapshot lifecycle (borrows host state, secured cleanup)
- Now CLEAN: no credentials.zig or secret.zig imports
- All secure cleanup delegated to `execution_compatibility` seams

### Supporting Infrastructure (Neutral)

All neutral-core internal dependencies:

**Core utilities**:
- `src/core/shared/types.zig` — Shared type definitions
- `src/core/shared/debug_trace.zig` — Tracing (no auth)
- `src/core/shared/io.zig` — I/O abstraction
- `src/core/shared/history_range.zig` — Range tracking

**Configuration** (enum-based, no dynamic secrets):
- `src/core/config/model_provider.zig` — ProviderId enum
- `src/core/config/model_capabilities.zig` — Capability resolution
- `src/core/config/agent_steps.zig` — Step limit configuration

**Session codec** (neutral serialization):
- `src/core/session/session_codec.zig` — Session data encoding (no auth)

**Neutral contracts** (types only, no secrets):
- `src/core/workspace/context_contract.zig` — Context structure
- `src/core/permissions/auto_classifier_context.zig` — Classification context (no credentials)
- `src/core/permissions/permission_request.zig` — Permission query type

**Tool infrastructure** (no credentials):
- `src/core/tooling/tool_dispatch.zig` — Tool invocation
- `src/core/tooling/model_tool_schema.zig` — Schema definitions
- `src/core/tooling/file_mutation_contract.zig` — File mutation types

**Images** (no embedded credentials):
- `src/core/images/image_attachments.zig` — Image references and metadata

---

## Host Interface

The neutral core receives two things from the host:

### 1. TurnExecutionInput
```zig
pub const TurnExecutionInput = struct {
    conversation_messages: []const ModelProvider.Message,
    provider_selection: ProviderSelection,
    turn_state: *TurnState,
    turn_id: u64,
    step_limit: usize,
    tool_choice: ToolChoice,
    max_output_tokens: ?u32,
    reasoning_effort: ReasoningEffort,
    structured_output: ?StructuredOutputSchemaRef,
    cancel_flag: *std.atomic.Value(bool),
    allocator: std.mem.Allocator,
};
```

Host provides:
- Pre-validated conversation messages
- Routing decision (which provider/model)
- Tool definitions
- Performance knobs
- Pre-created turn state

Host does NOT put in:
- Credentials (host keeps separate)
- API keys (host injects during adaptation)
- Account ID (irrelevant to orchestration)
- Billing context (host tracks separately)
- Authorization scopes (host evaluates pre-turn)

### 2. ModelProvider Adapter

Host provides a `ModelProvider` implementation that handles:
- Credential injection (not in core)
- API endpoint resolution
- Authentication headers
- Billing tracking (not in core)
- Retry logic

The core calls:
```zig
completion = try provider.chat(alloc, neutral_request, event_sink);
```

The core never sees:
- The credential object
- The API key
- The endpoint URL
- The auth mechanism

---

## Explicitly Outside the Core

### Authentication & Credentials
- Credential types and storage
- OAuth flows
- Token refresh
- Credential validation
- Secret zeroing (delegated to host via seams)

**Location**: `src/core/auth/`

### Account & Billing
- Account identity
- Subscription status
- Usage tracking (billing-level)
- Rate limiting (quota-level)
- Team/organization concepts

**Location**: `src/core/account/`, `src/core/billing/`

### Session Persistence
- Session file I/O
- Transcript storage
- Checkpoint persistence
- State recovery from disk

**Location**: `src/core/session/` (only neutral codec used by core)

### Compute/PAX/AppPort/FeltDB
- Container execution
- Distributed compute
- Alternative "compute" transport
- Database operations

**Location**: `src/core/compute/`, `src/core/pax/`, `src/core/appport/`, `src/core/feltdb/`

### TUI/UI/Rendering
- Terminal rendering
- Event loop
- Input handling
- ANSI codes
- Interactive screens

**Location**: `src/ui/`

### Host Adaptation Layer
- Credential injection
- API endpoint configuration
- Transport layer (HTTP, etc.)
- Event output formatting
- Lifecycle management
- Permission checking

**Location**: `src/core/app/`, `src/gateway/`

---

## Portability

The neutral core can be extracted and recompiled for:

### Native Host (Current)
- Zig compilation to machine code
- Direct credential management
- Synchronous I/O via `std.Io`
- Same behavior as production

### Compute-Backed Host (Future)
- Wrapper in Compute container
- Credential injection via environment
- Same core binary
- Adapted container I/O

### Browser/WASM Host (Future)
- Compile to wasm32-wasi
- Credential injection via JS
- JavaScript EventSink adapter
- Same core behavior

### Embedded/Custom Host (Future)
- Link neutral core as a library
- Provide ModelProvider implementation
- Provide I/O abstraction
- Provide allocator

In all cases:
- **No changes to neutral core required**
- **Model provider interface stays the same**
- **The five seams remain clean**
- **Credential handling stays in host**

---

## Build System Proof

See `docs/neutral-core-dependency-audit.md` for:
- Detailed module classification
- Refactoring changes made
- Build-time independence proof
- Verification commands

**Key artifact**: `src/core/neutral-core.zig`

This module explicitly imports only neutral components. If someone tries to add:
```zig
const credentials = @import("../auth/credentials.zig");
```

The build fails immediately. The module is the single point of verification.

---

## Five Model-Execution Seams (Portable)

These are the boundaries between neutral core and host:

### 1. Input Configuration
```zig
TurnExecutionInput {
    messages: no auth,
    provider: routing only,
    settings: performance settings,
}
```

### 2. Provider Selection
```zig
ProviderSelection {
    provider_id: ProviderId (enum),
    model_name: []const u8,
}
```

### 3. Model Request
```zig
NeutralModelRequest {
    messages: no credentials,
    tools: schema only,
    output_tokens: limit,
}
```

### 4. Provider Interface Call
```zig
completion = try provider.chat(alloc, request, event_sink);
```

Host provides credential injection in the provider implementation, not in this call.

### 5. Model Response
```zig
NeutralModelCompletion {
    content: model output,
    tool_calls: executed tools,
    tokens: usage (not billing),
    finish_reason,
}
```

These five seams are **fully portable**. They can be implemented in WASM, distributed computing, or any other runtime without modification.

---

## Testing

The neutral core is tested via:

1. **Unit tests in source files** (e.g., `src/core/agent/turn_coordinator.zig`)
   - Tests live in source, compiled with `zig build test`
   - No external dependencies

2. **Standalone smoke test** (`tests/neutral-core-standalone.zig`)
   - Proves core compiles independently
   - Exercises key types and boundaries
   - Verifies no forbidden imports
   - Run with `zig build test-neutral-core`

3. **Integration tests in agent orchestrator** (e.g., `src/core/agent/runtime/orchestrator.zig`)
   - Real turn execution with tool calls
   - Run with full test suite

4. **E2E tests** (via `tests/e2e/`)
   - Real model invocations
   - Full host integration
   - Run with `cd tests/e2e && bun test`

---

## What This Means for Embedding

If you want to embed the neutral core in your own host:

1. Implement `ModelProvider` interface
   ```zig
   pub fn chat(
       self: *const Self,
       alloc: std.mem.Allocator,
       request: ModelProvider.ChatRequest,
       event_sink: ModelProvider.EventSink,
   ) !ModelProvider.Completion
   ```

2. Construct `TurnExecutionInput` with your messages/settings (no credentials)

3. Call the orchestrator:
   ```zig
   result = try orchestrator.execute(input, provider_impl);
   ```

4. Handle `NeutralModelCompletion` or `NeutralFailure`

5. Manage credentials, endpoints, and billing in your host layer

The neutral core handles model invocation, tool execution, and turn orchestration. Everything else is your responsibility.

---

## Not in Scope (This PR)

The following are **future work**, not part of this independence proof:

- **WASM build system integration** — How to compile to wasm32-wasi
- **JavaScript bindings** — How to call from JS
- **Distributed hosting** — How to run core across containers
- **Browser APIs** — WebSocket, fetch, etc.
- **Alternative transports** — gRPC, etc.

This PR proves the core **CAN** be embedded (dependency-free), but doesn't implement the bindings for specific targets.

---

## Maintenance

When modifying the neutral core:

1. **Do not add fields to TurnExecutionInput, NeutralModelRequest, or NeutralModelCompletion that contain:**
   - Credentials
   - API keys
   - Account IDs
   - Billing context
   - Tokens
   - Secrets

2. **Do not import from:**
   - `src/core/auth/`
   - `src/core/account/`
   - `src/core/billing/`
   - `src/ui/`
   - `src/core/compute/`
   - `src/core/pax/`
   - `src/core/appport/`
   - `src/core/feltdb/`

3. **To verify your change is neutral:**
   ```bash
   # Will fail to compile if you've accidentally imported forbidden modules
   zig build test-neutral-core
   ```

4. **If you need to track credentials:**
   - Put the field in `ExecutionSnapshot` (host-owned)
   - Use `execution_compatibility.disposeApiKey()` for cleanup
   - Never embed in neutral types

---

## Questions?

See related documentation:
- `neutral-core-dependency-audit.md` — Detailed module classification and refactoring
- `neutral-execution-boundary.md` — Five execution seams
- `message-completion-boundary.md` — Message completion lifecycle
- `orchestration-boundary.md` — Orchestrator ownership
