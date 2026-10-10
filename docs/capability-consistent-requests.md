# Capability-consistent requests

Rule: a request advertises, and gives guidance about, only what the selected execution path can actually run. This
changes what is described to the model. It never changes what the runtime will execute: validation, permissions and
the stream validator that rejects calls to unadvertised tools are untouched.

## 1. The authoritative decision

Two facts, each read from the source that already decides execution, feed both tool projection and prompt guidance.

| Fact | Source | Used by |
| --- | --- | --- |
| The provider can execute provider-executed tools (web search) | `provider_set.select(provider).capabilities.fx_search`, the same flag the web-search dispatch backend uses (`agentFeatures().native_search` is derived from it) | Tool projection (name and guidance of provider-executed tools) |
| An MCP server could serve this request | `mcp.model_catalog.Snapshot.hasEnabledServer()`: at least one configured server that is not disabled | MCP prompt guidance (`model_catalog.render`) and tool projection (`mcp_select_tool`, `mcp_features`, and the MCP wording of `capability_search`) |

Both reach `tool_projection.Options.capabilities` (`ExecutionCapabilities { provider_executed_tools, mcp }`), whose
defaults keep every tool for callers that cannot resolve a fact. Each surface fills it from its own provider and MCP
runtime, using the same snapshot arguments that surface's prompt-context code uses:

* `fx ask` and its child agents: `AskContext.executionCapabilities`
* ACP and its child agents: `acpExecutionCapabilities`
* Interactive app and its child agents: `Runtime.executionCapabilities` (reads the MCP runtime without touching the
  change-notice baseline)

MCP has three distinguishable states, and only the third counts:

| State | Meaning here | Guidance and MCP tools |
| --- | --- | --- |
| Compiled in | Every FX binary | Not sufficient |
| Configured | A server entry exists | Not sufficient if every entry is disabled |
| Available for this request | At least one non-disabled server, including one that is connecting, needs authentication or failed (the model should see that state, and it may recover mid-run) | Included |

## 2. What changed

* `Snapshot.hasEnabledServer()` is the single MCP availability decision. `render` now returns no text when it is
  false, instead of an `<mcp_servers><none /></mcp_servers>` message, on every surface that renders it.
* `tool_projection` skips provider-executed tools (and their guidance) when the provider cannot execute them, and
  skips tools whose `executor_kind` is `mcp_select_tool` or `mcp_features` when no MCP server could serve the request.
  Matching is by executor kind, not by name.
* `capability_search` stays (it also finds skills) but advertises a skills-only schema and description when MCP is
  unavailable, through the new optional `Tool.model_schema_without_mcp`. Its normal description told the model to use
  `mcp_select_tool` and offered a `server` property, which would have contradicted the advertised tool set.
* `FX_EXPERIMENTAL_OMIT_UNEXECUTABLE_TOOLS` is removed. It existed only on the previous, unreleased commit and this
  behavior makes it redundant. `FX_EXPERIMENTAL_TOOL_ALLOWLIST` is unchanged: off by default, ignored when empty, and
  it narrows after the capability filters, so it can never re-add a tool the path cannot run.
* Unchanged on purpose: visibility, permission-deny, host-capability (`subagent`) and read-only filtering; the
  full tool set otherwise; no reduced configuration as a default.

## 3. Measurements (mock provider, deterministic)

Same eight tasks, success criteria and settings as the previous experiment. "Previous" is commit `92d003a`; "candidate"
is this change. Provider requests include reviewer calls (none occur in these eight tasks; the sequencing scenarios
below include them). Provider token and cache fields are not reported by the mock for this comparison and are
unavailable, not zero.

| Condition | Tools advertised (schema bytes) | Tasks succeeded | Requests | Total request bytes | Mean first-request bytes |
| --- | --- | --- | --- | --- | --- |
| Previous default | 14 (18032) | 8/8 | 18 | 477715 | 26247 |
| Candidate default (capability-consistent) | 12 (15343) | 8/8 | 18 | 411783 (-13.8%) | 22584 (-14.0%) |
| Previous `core6` allowlist | 6 (9529) | 8/8 | 18 | 316185 | 17273 |
| Candidate `core6` allowlist | 6 (9529) | 8/8 | 18 | 307132 | 16770 |
| Previous `min4` allowlist | 4 (6043) | 5/8 | 14 | 197187 | 13787 |
| Candidate `min4` allowlist | 4 (6043) | 5/8 | 14 | 190146 | 13284 |

Where the first request's -3,663 bytes (26188 to 22525 with the same prompt) come from:

| Component | Bytes removed |
| --- | --- |
| `mcp_select_tool` and `mcp_features` schemas | 2318 |
| Shorter `capability_search` schema (no MCP wording or `server`) | 371 |
| Web-search guidance system message | 440 |
| MCP guidance system message (`<none />`) | 467 |
| Message framing | 67 |

Unchanged: request counts, purposes (`initial`, `after_tools`, `after_failed_tools`, `reviewer`), tool executions, exit
codes and task outcomes for every task and condition. The sequencing scenarios give identical results on the candidate
(S11: 2 main calls plus 1 reviewer; S14: 3 main plus 2 reviewers; S13: invalid call, 0 reviewers; S15: stops after 1
call), with request bytes falling from 26564/27191 to 22901/23528 for S11.

The `core6` and `min4` rows are separate experiments on top of the new default and keep the same conclusions as before
(`min4` regresses two tasks because the model falls back to `shell`).

Byte counts are serialized request bodies, not tokens. Nothing here shows a latency, token-cost or cache benefit.

## 4. Real-model results

**BLOCKED.** Ollama is unreachable from the container (`ollama.com` and `registry.ollama.ai` return HTTP 403 on CONNECT),
so `qwen3-coder:latest` was never run. No tool-choice, task-completion, latency, token or cache result exists for the
baseline or the candidate. The mock confirms protocol consistency only. The missing acceptance run is the same eight
tasks, at least five repeats per condition, baseline against candidate, with equal settings.

## 5. Tests

* Unit: `Snapshot.hasEnabledServer` and `render` for every availability state; projection filters for provider
  execution and MCP; composition with permission denies and allowlists; `capability_search` variants; the provider
  capability flag for a configured provider versus the built-in gateway.
* End to end, inspecting serialized bodies (`capability-consistent requests`): no web-search tool or guidance for a
  provider that cannot run it; no MCP guidance or tools by default; a disabled MCP server does not count; an enabled
  server keeps the guidance, `mcp_select_tool`, `mcp_features` and the full `capability_search`; calling an
  unadvertised tool (`web_search`, `mcp_select_tool`, `mcp_features`) fails with a non-zero exit, zero executions and
  one request; no forbidden strings anywhere in any request; pairing and ordering unchanged.
* Existing tests that pinned the old empty-MCP message were updated to the new behavior.

## 6. Remaining gaps

* The supported web-search path is covered at the capability and projection level only. The mock harness cannot run
  the built-in gateway (the gateway-fixture end-to-end tests cannot start in the decoupled build), so no serialized
  gateway request is inspected.
* The base system prompt and other static text were scanned for web-search and MCP references in the configured-provider
  path and are clean; other providers' prompts were not audited.
* `install_skill` and `skill` are advertised even when no skills exist; they are not provider- or MCP-dependent and were
  left alone.
* MCP availability is evaluated per request. A server that becomes available between projection and prompt rendering
  in the same turn could briefly disagree; the interactive path takes both from the same runtime within one request.
* Real-model effect of any of this is unmeasured.
