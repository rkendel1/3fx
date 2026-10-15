# AppPort effectiveness benchmark

This benchmark measures whether AppPort contract knowledge makes fx complete
more tasks correctly, complete them with less inference or lower latency, or
complete some of them without a model. It can show a regression or no benefit
as readily as an improvement.

## Configurations

Every model-driven task runs in three configurations. They use the same
binary, provider, model, permission flag, step budget, timeout, task prompt,
workspace files, and oracle. They differ only in two environment variables
read by the existing context hook in `src/core/appport/`:

| Configuration | `FX_APPPORT_MANIFEST` | `FX_APPPORT_FOCUS` | Measures |
| --- | --- | --- | --- |
| A, baseline | unset | unset | Existing fx behavior |
| B, AppPort context | both contracts | unset | Relevant application knowledge |
| C, focused context | both contracts | the task's capabilities | Targeted context |

The harness clears both variables for configuration A, so a value inherited
from your shell cannot leak into the baseline. In every configuration the
workspace contains the same two contracts under `contracts/`; B and C add only
the context fx builds from them. With a focus, fx includes the focused
capabilities and the same-application capabilities they depend on or verify
through.

## Task corpus

The Memos and Vikunja contracts are the AppPort bridge manifests recorded live
from the real applications, copied unmodified from the AppPort repository.
`fixtures/PROVENANCE.json` records their source commit, digests, the bridge
revisions, and every derived fixture.

**Discovery (D1 to D9)** asks which capability performs an operation, what it
requires and returns, what it depends on and how its effect is verified,
which capabilities a cross-application task needs, and when to refuse. D6 and
D7 are the AppPort workload's negative cases: a capability that does not exist
(`UNSUPPORTED`) and one whose contract does not declare a retry-safe update
(`INCOMPATIBLE`).

**Contract-constrained implementation (I1 to I4)** asks the agent to build a
request under the contract's input schema (I1), mark a task done and verify
the effect with the contract's declared verification and failure behavior
(I2), judge a proposed replacement contract (I3), and rewrite legacy code while
preserving documented quirks (I4, a control task that needs no contract).

**Deterministic operations (N1 to N12)** run `fx appport inspect`, `graph`,
`find`, `context`, and `coverage` on valid, incomplete, inconsistent,
malformed, and unsupported contracts and on queries with empty results. The
harness also answers D1, D4, and D6 with `fx appport` alone and grades those
answers with the same oracle as model answers.

### Oracles

A trial passes only when its oracle confirms the outcome. A model's statement
that it succeeded is never evidence.

- Discovery answers are compared field by field with expected values stated in
  `tasks.ts`. The self-tests derive each expected value from the contracts and,
  where the reference packages have a function for it, from
  `@appport/protocol` and `@appport/integration`.
- Implementation tasks run hidden `node --test` assertions written outside the
  workspace after the agent finishes, plus file checks. Contract files must be
  unchanged.
- Negative tasks have explicit expected refusals, so guessing does not score.
- A correct capability with incomplete details is `partial`, reported apart from
  `pass`.

## Run it

Build fx first. For latency numbers, use a release build; the report records
the binary's digest and build mode.

```bash
zig build -Doptimize=ReleaseSafe
cd tests/appport-effectiveness
bun install
bun run.ts --preflight       # 1. check the provider; no model requests
bun run.ts --smoke           # 2. 9 trials: D1, D6, D7 once in A, B, and C
bun run.ts --repetitions 5   # 3. the paired comparison: up to 13 x 3 x 5 = 195 trials
```

The model tier uses whatever provider `fx` resolves from your profile and
environment, the same as `fx ask`: a Vercel AI Gateway login or
`AI_GATEWAY_API_KEY`, or a custom connection in `~/.fx/settings.json`
selected with `fx provider` or `FX_PROVIDER`. The benchmark reads no
credentials itself.

### Profiles

| Profile | Command | Model trials | Purpose |
| --- | --- | --- | --- |
| Preflight | `--preflight` | 0 | Readiness only |
| Smoke | `--smoke` | 9 (3 tasks x 3 configurations x 1) | Prove every configuration reaches the provider and every trial is graded |
| Comparison | default, `--repetitions N` | up to 13 x 3 x N | The paired experiment |

Every profile prints the plan before it starts: tasks, configurations,
repetitions, and the maximum number of trials. A trial is one `fx ask` run and
can make several model requests (up to `--max-steps`) plus safety-review
requests, so the trial count is not a request count. fx does not report
provider pricing, so no cost estimate is shown; the report gives
provider-reported tokens where available.

The smoke subset is D1 (capability discovery), D6 (refuse a capability that
does not exist), and D7 (refuse a non-idempotent update), with their existing
oracles. A smoke run is a connectivity and pipeline check. Its report never
contains significance tests and is never a statement about effectiveness.

### Provider readiness

Every profile runs the preflight first, and model trials start only when it
reports `ready`. The preflight uses `fx --version`, `fx status --json`,
`fx models --json`, and `fx appport coverage`, and sends no inference request.

| State | Meaning |
| --- | --- |
| `ready` | Authentication, provider, model, and endpoint checks passed |
| `missing_auth` | fx reports no authentication (`fx status` auth `missing`) |
| `missing_provider` | The selected provider is not configured (`UnknownConfiguredProvider`) |
| `endpoint_unreachable` | The Gateway model catalog could not be fetched, or a configured endpoint did not answer an unauthenticated `GET <endpoint>/models` |
| `unsupported_model` | `fx models` does not list the selected model |
| `preflight_error` | fx could not be run or answered unexpectedly |

`ready` is not proof that a model request will succeed. The first trial's
request is the definitive test, and a failure there is recorded as the trial's
outcome (`fx-error` or `timeout`). Diagnostics pass through a scrubber that
removes secret environment values, bearer tokens, key-shaped strings, and URL
credentials; fx itself never prints credential values.

### Options

| Option | Default | Effect |
| --- | --- | --- |
| `--preflight` | off | Check readiness and stop |
| `--smoke` | off | Run the smoke profile |
| `--repetitions N` | 3 | Comparison repetitions per task and configuration |
| `--det-repetitions N` | 5 | Deterministic-tier repetitions |
| `--tasks D1,I2` | all | Limit the comparison to these tasks |
| `--configs A,C` | `A,B,C` | Limit the comparison configurations |
| `--model ID` | profile default | Sets `FX_MODEL` for every trial, and the preflight checks it is offered |
| `--permission FLAG` | `--auto` | `--auto` or `--full-access`, the same for every trial |
| `--max-steps N` | 40 | `FX_MAX_AGENT_STEPS` for every trial |
| `--timeout-ms N` | 300000 | Per-trial timeout; a timeout is a recorded failure |
| `--seed N` | 1 | Seed for task order |
| `--no-model` | off | Skip the model tier |
| `--require-model` | off | Exit 2 when the comparison does not complete |
| `--out DIR` | `results/<timestamp>-<profile>` | Output directory |
| `--keep-workspaces` | off | Keep trial workspaces for inspection |

`--tasks`, `--configs`, and `--repetitions` apply to the comparison only.

Exit status: 0 when the requested work happened (a `ready` preflight, a passed
smoke test, or a comparison run); 2 when it did not (not ready, a failed smoke
test, or `--require-model` without a completed comparison); 1 when a
deterministic golden failed; 64 for invalid arguments. Without
`--require-model`, a blocked comparison still exits 0, as before.

Each trial runs in a new temporary workspace with `--no-save`, so no
configuration sees another's files, sessions, or output. Tasks run in a seeded
random order, and the configuration order rotates across tasks and
repetitions.

With `--auto`, fx may send some actions to its safety reviewer. Those calls are
counted as review calls, separately from the agent's model calls.

## Run it remotely

### GitHub Actions

`.github/workflows/appport-benchmark-live.yml` runs on manual dispatch only
(**Actions > AppPort benchmark (live model) > Run workflow**); nothing runs on
push or pull request. It builds fx in ReleaseSafe mode, runs the parity suite
and the benchmark self-tests, runs the preflight, and then runs the selected
profile:

- `smoke` (the default) runs 9 trials.
- `comparison` also requires the **confirm_comparison** box and takes
  **repetitions** from 1 to 20.
- `preflight` stops after readiness.

Add the credentials as repository or environment secrets:

| Provider input | Secrets |
| --- | --- |
| `gateway` | `AI_GATEWAY_API_KEY` |
| `settings` | `FX_BENCHMARK_SETTINGS_JSON`, the full `settings.json` for a custom connection whose `auth.env` is `FX_BENCHMARK_PROVIDER_TOKEN`; and `FX_BENCHMARK_PROVIDER_TOKEN` |

Secrets reach only the steps that run fx. GitHub-hosted runners can reach
public model endpoints. When the preflight is not ready, the job is marked
failed, the summary says the run was blocked, and no model trial runs.

Artifacts are uploaded even when trials or the job fail, as
`appport-benchmark-<profile>-<run id>-<attempt>` for 90 days. Download them from the run
page, or with `gh run download <run-id> --repo <owner>/<repo>`.

### A Claude Code cloud environment or another machine

The environment needs network access to your provider's endpoint and the
credential fx expects:

- **Vercel AI Gateway:** allow `ai-gateway.vercel.sh` and provide
  `AI_GATEWAY_API_KEY`.
- **Custom connection:** allow the host in its `base_url` and provide the
  token variable its `auth.env` names.

In a Claude Code cloud environment, add the host under Network access and the
key as an environment variable in the environment's settings; see
[cloud environments](https://code.claude.com/docs/en/cloud-environments#network-access).
Never paste a key into a chat or commit it. Then run the commands above.
`bun run.ts --preflight` reports `endpoint_unreachable` when the host is not
allowed.

Results go to `tests/appport-effectiveness/results/<timestamp>-<profile>/`,
which git ignores. Interrupted runs keep their artifacts: they are written after
every trial and on SIGINT or SIGTERM, with status `incomplete`.

## Output

`results/<timestamp>/` holds three files built from the same trial records:

- `trials.json`: every trial, including failures and timeouts, with task and
  fixture digests, provider identity, limits, and the order it ran in.
- `summary.json`: per-configuration counts and distributions, paired
  comparisons, and the interpretation.
- `report.md`: the human-readable report.

Each file carries the run section: run type (`preflight`, `smoke`, or
`comparison`); status; git commit and dirty-tree state; fx binary digest and
build mode; benchmark version and fixture digest; provider and model identity;
planned, scheduled, and completed trials; provider and review calls per
configuration; skipped configurations and their reasons; provider and harness
failures; oracle outcomes; token and cost availability; and whether the
results are suitable for statistical comparison.

| Status | Meaning |
| --- | --- |
| `preflight_only` | Readiness was checked; no trials were requested |
| `deterministic_only` | The model tier was disabled with `--no-model` |
| `blocked` | The model tier did not start; the reason is recorded |
| `provider_failed` | Model trials ran, but every one failed at the provider or harness |
| `incomplete` | The run stopped before every scheduled trial finished |
| `completed` | Every scheduled trial finished and was graded |

Only a `completed` comparison with every configuration reaching the provider is
suitable for statistical comparison. Other runs report outcomes and metrics
descriptively, without significance tests. When no model trial ran, the
report states that the effectiveness comparison did not run.

### Metrics

| Field | Unit and source |
| --- | --- |
| `latency_ms` | Spawn to exit of `fx ask`, measured by the harness |
| `model_ms`, `tool_ms` | Sums of provider request and tool execution durations from the fx trace |
| `model_calls`, `tool_executions` | fx trace `measurement` events |
| `review_calls` | fx trace `auto_review_send` events |
| `input_tokens`, `output_tokens` | `usage` from `fx ask --json`, as the provider reported it |
| `request_bytes_total`, `request_bytes_first` | UTF-8 bytes of the serialized provider requests, from the fx trace |
| `appport_context_bytes` | UTF-8 bytes of the context text the configuration adds, from `fx appport context` |
| `cost` | Always unavailable: fx does not report cost |
| `harness_ms` | Workspace setup, context measurement, and grading outside the fx process |

A metric fx does not expose is stored as `{ "value": null, "available": false }`
and never estimated. Every configuration enables tracing in the same way. The
first model trial of a run is marked `cold`.

### Statistics

Comparisons pair trials of the same task and repetition. Completion uses an
exact McNemar test on discordant pairs; latency, model calls, tokens, and
request bytes use a two-sided sign test on paired differences. The report gives
medians, quartiles, sample sizes, absolute and relative differences, and
task-level effects. An effect is stated only at p < 0.05; otherwise the report
says "inconclusive". Deterministic results are reported separately and never
combined with model results.

## Self-tests

```bash
cd tests/appport-effectiveness && bun install && bun test
```

The self-tests use a scripted provider through the same trial code path. They
check that:

1. With both variables unset, the request matches an ordinary fx run, even when
   the parent shell sets them.
2. AppPort context appears only in configurations B and C.
3. Focused context holds the intended capabilities and dependencies only.
4. All configurations use the same task and verification definitions.
5. Every trial starts from the same clean fixture state.
6. A confident wrong answer fails its oracle.
7. Missing token and cost data is recorded as unavailable.
8. Failed and timed-out trials stay in the results and the denominators.
9. Results record the fx version, binary digest, commit, fixture digest, and
   provider.
10. The fixtures and the AppPort package pins are unchanged, and the benchmark
    adds no other way to inject context.

`runner.test.ts` covers the runner: every preflight state, smoke runs that
pass, fail at the first provider request, time out, or meet confident wrong
answers, interrupted runs, artifacts rebuilt from the same trial records, no
secret values in any artifact even when the provider or model echoes them, and
the unchanged comparison invocation.

They also check every oracle against a reference solution and a confident wrong
answer, and every golden against the contracts and reference packages. CI runs
the self-tests, the parity suite, and the deterministic tier through
`.github/workflows/appport-benchmark.yml`, with no timing assertions.

## Limitations

- **COBOL modernization is not included.** The AppPort repository's
  legacy-migration experiment needs GnuCOBOL, network access to fetch IBM
  sources, and a JDK. Some upstream sources carry IBM restricted-materials
  headers that must not be vendored. The report lists it under "Not run".
- **Contract-level grading.** Discovery and implementation tasks are graded
  against the contracts and hidden tests, not against running Memos or Vikunja
  instances. The AppPort repository's execution-graded workload needs the apps
  running.
- **Scripted runs are not model results.** The self-tests show that the harness
  and oracles work; the report labels scripted runs as such.
- **Provider variance.** Paired, counterbalanced trials reduce but do not remove
  it. Read effects with their sample sizes and p-values.
