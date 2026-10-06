# Phase 6B — FX Public Model API Design

## API Shape

The FX public model API exposes the existing `ModelProvider.chat()` contract through FFI-safe JavaScript bindings.

```typescript
// Request type (FFI-safe serialization of ChatRequest)
interface FxChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content?: string;
  tool_calls?: Array<{
    id: string;
    name: string;
    arguments_json: string;  // raw JSON string
  }>;
  tool_call_id?: string;
}

interface FxChatRequest {
  messages: FxChatMessage[];
  model: string;
  tools?: Array<{
    name: string;
    description: string;
    input_schema: any;  // raw JSON object
  }>;
  tool_choice?: "auto" | "none" | "required";
  max_output_tokens?: number;
}

// Result type (FFI-safe serialization of ChatStream)
interface FxChatCompletion {
  content?: string;
  tool_calls?: Array<{
    id: string;
    name: string;
    arguments_json: string;
  }>;
  usage?: {
    input_tokens?: number;
    output_tokens?: number;
    cache_read_tokens?: number;
    cache_write_tokens?: number;
    reasoning_tokens?: number;
  };
}

interface FxChatFailure {
  kind: "invalid_request" | "unauthorized" | "forbidden" | 
        "request_too_large" | "rate_limited" | "server_error" | 
        "bad_gateway" | "unavailable" | "gateway_timeout" | "provider_error";
  detail?: string;
  retry_after_seconds?: number;
}

interface FxChatResult {
  completed?: FxChatCompletion;
  failed?: FxChatFailure;
}

// Public model interface
interface FxModel {
  chat(request: FxChatRequest, options?: {
    signal?: AbortSignal;
    onChunk?: (chunk: {delta?: string}) => void;
  }): Promise<FxChatResult>;
}

// Factory function
export async function createFxModel(config: {
  id?: string;           // provider ID (defaults to "openai-compatible")
  baseUrl: string;       // OpenAI-compatible endpoint (e.g., "http://localhost:8000")
  model: string;         // model name
  apiKeyEnv?: string;    // environment variable name for API key (defaults to "OPENAI_API_KEY")
}): Promise<FxModel>
```

## Mapping to Internal Contract

```
JavaScript FxChatRequest
    ↓ (JSON serialization)
NAPI boundary
    ↓ (native conversion)
ChatRequest (ModelProvider.zig)
    ↓
ModelProvider.chat()
    ↓
OpenAICompatibleModelProvider
    ↓
Model
```

## Implementation Plan

### Phase 6B-1: Design finalized ✓

- FFI-safe types defined
- NAPI registration pattern identified
- Memory ownership documented

### Phase 6B-2: NAPI extensions ✓

- `createModel()` NAPI callback: parses config object, creates NapiModelHandle, returns external value
- `modelChat()` NAPI callback: extracts model handle, converts request, executes provider, returns result object
- `modelHandleFinalize()`: cleanup hook for model handles
- `parseModelRequest()`: converts JavaScript request object to FxChatRequest
- `resultToJavaScript()`: converts ChatStream result back to JS object
- Memory ownership: NAPI allocator owns all strings, model handle owns config with finalizer

### Phase 6B-3: JavaScript binding ✓

- `createFxModel(config)`: factory function accepting {baseUrl, model, id?, apiKeyEnv?}
- Returns model object with `chat(request)` method
- Proper error handling and fallback to WASM

### Phase 6B-3: Verification ✓

- Deterministic OpenAI-compatible mock HTTP server
- Integration test: public API reaches real native provider
- Request mapping: user/system/assistant messages, model, usage
- Response mapping: completed content, usage tokens, error handling
- Provider failure test: failed results propagate correctly
- Memory/lifetime review: ownership verified, no leaks detected
- Boundary checker: model-provider passes, whole-agent passes
- Package export: createFxModel exported from sdk/node.js
- Documentation: implementation vs. deferred capabilities clarified

### Phase 6B-4: Deferred

- Public streaming API (currently synchronous)
- Browser/WASM model API support
- Chip integration (next phase)
- Additional error types/diagnostics

## Key Invariants

✓ No duplicate provider abstraction
✓ Credentials from environment (not persistent)
✓ ModelProvider unchanged
✓ Agent API unchanged (createFxAgent still works)
✓ Phases 2-5 fully preserved
✓ No Chip/Compute/Attn references
✓ No CLI invocation
✓ FFI-safe types only
✓ Boundary checker passes (model-provider and whole-agent)
✓ Public API exported from sdk/node.js
✓ Real provider execution through OpenAICompatibleModelProvider
✓ Deterministic test coverage with localhost mock
