# Neutral turn-state slice

This change extracts production prompt-delivery semantics and turn-local counters. It does not complete PR3 or make the queued-prompt envelope and turn orchestrator vendor-neutral.

## Existing dependency

`runtime/orchestrator.zig` consumes `worker_runtime.QueuedPrompt`. That envelope carries `provider`, `api_key`, `gateway_team`, `credential_source`, and `account_id`. Its history, image, permission, and recovery fields also depend on shared legacy types. Credential refresh, recovery authority, and completion handling consume those fields in the orchestrator; CLI, TUI host composition, ACP, and subagent adapters produce them.

`runtime/agent.zig` owns the conversation history, freshness, turn token counters, and request-token calibration. History and checkpoint projection still use shared types. Token counters themselves represent measurements, not a billing ledger.

## Production changes

- Move the existing `PromptDelivery` union into `core/agent/turn_state.zig`. The worker queue uses that exact type through an alias, preserving ordinary, active-turn steering, and continuation classification. No parallel delivery implementation is introduced.
- Extract `TurnState` with freshness and the existing canonical `model_provider.TokenUsage`. It imports only the standard library and canonical model contract.
- Make `Agent` own this state. Turn start, token accumulation, history freshness, and checkpoint restore use it. Saturation and reset behavior are unchanged.
- Replace direct host reads of the old counter field with `turnUsage()`, an explicit value projection for the unchanged checkpoint/presentation format. No session storage format is changed.
- Include focused state and Agent tests in the existing test entry point.

## Limits

Queued-prompt text, model configuration, credential fields, history, and recovery remain in the legacy envelope. Conversation messages and tool results remain in the existing history types. Cancellation remains controlled by the existing orchestrator config. No neutral queued-prompt construction or cancellation migration is claimed.

The production orchestrator still consumes the legacy `QueuedPrompt`; it does not yet accept only neutral state and `ModelProvider`. Compaction, vision, recovery, auth, billing implementations, tools, skills, MCP, TUI, and storage architecture are unchanged.

## Strict guard result

The whole-agent guard is unchanged and still fails:

- Before: 1,506 violations.
- After: 1,506 violations.

No violation was removed because the extracted delivery type and token measurements were not forbidden concepts, while the shared history, checkpoint, queue envelope, and orchestration dependencies remain reachable. The slice does not satisfy the requested queued-prompt/orchestration extraction acceptance conditions.

Mutually exclusive categories, assigning each concept to the first matching category:

| Category | Count |
| --- | ---: |
| Credential/auth concepts | 697 |
| Legacy/auth imports | 232 |
| Team concepts | 175 |
| Subscription concepts | 150 |
| Upgrade concepts | 119 |
| Account concepts | 101 |
| Billing concepts | 31 |
| Vendor concepts | 1 |

The next state migration must separate the queued envelope's host configuration and convert legacy history/recovery into neutral representations at the host/provider boundary. This change does not hide those dependencies or change the guard roots, patterns, or exclusions.
