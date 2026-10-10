# Request context efficiency

Question: can FX send materially less context per model request without losing the agent's ability to select tools
and complete work correctly?

Short answer: **not demonstrated**. Mock-provider runs show that request size can fall by up to 34 percent while
every mock task still passes, and by 58 percent with real failures. They cannot show whether a real model still
chooses the right tool from a smaller schema, and they say nothing about tokens, cost, latency or caching. Real
Ollama was unavailable (`ollama.com` and `registry.ollama.ai` return HTTP 403 from the egress proxy), so every
number below is mock-provider data. No production default changed.

> Update: `FX_EXPERIMENTAL_OMIT_UNEXECUTABLE_TOOLS` and the `omit_unexecutable` condition described below were removed
> by the capability-consistent change, which makes the default request omit tools and guidance the execution path
> cannot run (see `capability-consistent-requests.md`). The tables below are the measurements at commit `92d003a`.

Reproduce:

```
zig build
cd tests/e2e
bun ../../benchmarks/sequencing/run_context.ts --repeats 3   # this experiment
bun ../../benchmarks/sequencing/run.ts                       # the sequencing baseline from the previous PR
```

## 1. How a request is built

```
fx ask
  tool_projection.buildToolProjection        one place that selects what is advertised
     visible tools -> permission denies -> read-only mode -> [experimental allowlist] -> [experimental omit]
     -> advertised_names (registry)  +  advertised_functions (schemas)  +  custom_guidance (provider-executed tools)
  orchestrator: each model call
     system messages  0 base prompt (5900 B)         fixed
                      1 web_search guidance (440 B)  from custom_guidance
                      2 MCP guidance (467 B)         sent even when no server is configured: "<none />"
                      3 turn context (workspace, cwd)  4 permission-mode note  5 response-language note
     history + user message, then tool call / tool result pairs   append-only
     tools: 14 function schemas (18032 B)             same bytes on every call
  chat-completions codec: model, stream, stream_options, messages, tools, max_tokens   (tools after messages)
  provider -> stream reducer (rejects a call to any tool not in the request) -> validate -> authorize -> execute
```

Facts established from source and runs:

* **Selection already exists in one place.** `buildToolProjection` drops tools that are not model-visible, that a
  permission rule denies, that need a missing host capability (`subagent`), or that fall outside read-only mode.
  Nothing else filters per request or per phase. MCP and skill tools are advertised even when no MCP server or skill
  is configured.
* **A call to a tool that was not advertised never executes.** The stream reducer rejects the unknown name, so the
  run ends with exit 1 after that model call and zero executions (pinned by the new tests).
* **Prefix stability.** Tools and every earlier message are byte-identical from call to call; new messages are only
  appended. Key order is fixed. Anything that changes the tool set changes the prefix once, at the start of the run,
  and not between calls.
* **Provider-executed tools.** `web_search` is not a function in the chat-completions `tools` array (the codec skips
  provider-executed tools), yet its 440-byte guidance is sent, so a local model is told about a tool it cannot call.
* **Metrics available.** `ContextMeter` and the `context` trace event cover main-agent calls: count, reason,
  adapter-reported request bytes, provider-reported input and output tokens (null when unreported). Reviewer calls
  are visible through the existing `auto_review_send` trace events and are counted in the driver. The chat-completions
  codec does not read cached-token fields, so **cache read and write metrics are unavailable**, not zero.

## 2. Experimental changes (all off by default)

| Switch | Effect | Scope |
| --- | --- | --- |
| `FX_EXPERIMENTAL_TOOL_ALLOWLIST=a,b,c` | Advertise only these registry names. Names that do not exist are reported on stderr. An empty value is ignored. An allowlist that matches nothing falls back to the full set with a notice | `fx ask` only |
| `FX_EXPERIMENTAL_OMIT_UNEXECUTABLE_TOOLS=1` | Do not advertise (name or guidance) provider-executed tools when the selected provider cannot execute them | `fx ask` only |

Both feed `tool_projection.Options` (`experimental_allowlist`, `provider_executed_available`). Neither touches
validation, permissions, execution or any message; they only change what is advertised. A stderr notice is printed
whenever the allowlist is active, so nothing is removed silently.

## 3. Mock-provider results

Eight tasks, success criteria fixed in `benchmarks/sequencing/context.ts` before any comparison. The mock model is
scripted and adapts to the tools it is offered (for example it uses `shell` when `read_file` is absent). "Correct"
means the task succeeded, or the task's required tool was deliberately removed and the run failed truthfully
(non-zero exit, nothing executed).

| Condition | Tools advertised | Tasks succeeded | Correct outcomes | Requests | Total request bytes | Mean first-request bytes | vs baseline |
| --- | --- | --- | --- | --- | --- | --- | --- |
| baseline (control) | 14 (18032 B) | 8/8 | 8/8 | 18 | 477717 | 26247 | |
| omit_unexecutable | 14 (18032 B) | 8/8 | 8/8 | 18 | 469239 | 25776 | -1.8% |
| no_mcp | 12 (15712 B) | 8/8 | 8/8 | 18 | 427480 | 23456 | -10.5% |
| core6 | 6 (9529 B) | 8/8 | 8/8 | 18 | 316186 | 17273 | -33.8% |
| min4 | 4 (6043 B) | 5/8 | 6/8 | 14 | 197187 | 13787 | -58.7% |

Request counts are identical for the first four conditions, with the same purposes per task
(`initial`, `after_tools`, `after_failed_tools`; C4's reviewer path is covered by the sequencing scenarios). Wall
time per task shows no consistent direction: across two full runs C2 took 61 to 74 ms at baseline and 56 to 66 ms
with core6, with the sign of the difference flipping between runs. The mock answers instantly, so this is noise, not
evidence about real latency in either direction.

`min4` failures, which are the useful finding:

* **C3 and C8 fail** although the mock model adapts: with `grep_files` and `glob_files` gone it falls back to
  `shell`, and `shell` needs approval in the default permission mode, so the run stops (exit 1) before the task is
  done. Dedicated read-only tools are not only schema weight; they are the path that needs no approval.
* **C7 fails truthfully**: a model that calls `grep_files` when it is absent ends the run with exit 1, zero
  executions and no "Found." claim. That is the correct outcome for a missing tool, and it is why the "correct"
  column counts it.

Tool-selection accuracy cannot be measured with a scripted model. What the data does show is structural: every
condition except `min4` keeps both similar tools (C8: `glob_files` beside `grep_files`) and the mock picks the
intended one.

## 4. Real-model results

**BLOCKED.** Ollama is not installed in the container and cannot be installed or given a model: the egress proxy
denies `ollama.com` and `registry.ollama.ai` (HTTP 403 on CONNECT) and `huggingface.co` is unreachable. No real-model
run, token count, cache metric or latency distribution exists for any candidate. The acceptance test that is missing
is the same eight tasks, repeated at least five times per condition against `qwen3-coder:latest`, comparing task
success, tool choice, request count and provider-reported tokens.

## 5. Candidates and recommendations

| Candidate | Intended benefit | Failure modes | Detection | Recommendation |
| --- | --- | --- | --- | --- |
| A. Full schema (control) | none | 26 KB per call | | **Keep as the default** |
| B1. `no_mcp`: drop `mcp_select_tool`, `mcp_features` | -2.3 KB schemas; capability-preserving only when no MCP server is configured | MCP servers added later in a run lose their tools; as an allowlist it also drops `web_search` guidance, so 471 B of its saving is candidate C | `<mcp_servers><none />` is already visible in the prompt; unit test of projection | **Retain as experimental.** Making it automatic needs the "no MCP configured" signal wired into the projection (not done) and a real-model check |
| B2. `core6` | -34% bytes in the mock | Removes skills, MCP, `web_fetch`, `ask_user_question`, `read_tool_result`; capability loss the mock cannot see | Task success on tasks that need those tools | **Reject as a default.** Acceptable only as an explicit opt-in for users who never use them |
| B3. `min4` | -59% bytes | Two of eight tasks regress (shell fallback needs approval); a third fails by design | C3, C8 | **Reject** |
| C. omit unexecutable provider tools | Stops telling a local model about `web_search` it cannot call; -471 B per call | A provider that can execute it must report `native_search` correctly (it does for the gateway) | `omit_unexecutable` condition, unit test, e2e equality of schemas | **Retain as experimental; adopt after one real-model run**, since it is capability-preserving and fixes a misleading prompt |
| D. MCP guidance when no server is configured | Component sizes only: guidance message 467 B plus two MCP schemas 2.3 KB (about 10.7% of the first request) | Same as B1 | Not implemented | **Backlog**: derive both from configuration instead of an allowlist |

Not attempted, by instruction: compaction, observation deduplication, evidence reuse, prompt rewriting. Selecting
schemas per task or phase would need a relevance signal FX does not have; keyword rules would be a guess, so only
static, configuration-derived selection is a defensible next step.

## 6. The decision

Can FX send materially less context per request without hurting tool selection and task completion? **Only the
capability-preserving reductions are safe by construction, and they are small**: about 10 percent of request bytes
at most (B1 plus C, and D if implemented), with no token, cost or latency figure behind them. Larger reductions
remove tools; the mock already shows one such reduction (`min4`) breaking tasks, and `core6` passes only because
the mock tasks do not need the removed tools. Without a real-model run that measures tool choice and task success,
the production default stays as it is.

## 7. Accounting invariants (tested)

* Server-side provider requests equal main-agent calls plus reviewer calls, each counted once; the number of
  `auto_review_send` events equals the reviewer requests received.
* Request purposes (`initial`, `after_tools`, `after_failed_tools`, `reviewer`) agree with what was admitted and sent.
* A reported usage of zero is shown as zero; an unreported count stays `null`.
* Each condition runs the same task, settings and first user message; only the tool selection and the guidance for
  removed tools differ.
