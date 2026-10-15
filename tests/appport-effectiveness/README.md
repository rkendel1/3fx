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
the binary's digest and size.

```bash
zig build -Doptimize=ReleaseSafe
cd tests/appport-effectiveness
bun install
bun run.ts --repetitions 5
```

The model tier uses whatever provider `fx` resolves from your profile and
environment, the same as `fx ask`. Check it with `../../zig-out/bin/fx status` from this directory. When fx
reports no provider, the model tier is skipped and the report says why; the
deterministic tier still runs.

| Option | Default | Effect |
| --- | --- | --- |
| `--repetitions N` | 3 | Model-tier repetitions per task and configuration |
| `--det-repetitions N` | 5 | Deterministic-tier repetitions |
| `--tasks D1,I2` | all | Limit the model tier to these tasks |
| `--configs A,C` | `A,B,C` | Limit the configurations |
| `--model ID` | profile default | Sets `FX_MODEL` for every trial |
| `--permission FLAG` | `--auto` | `--auto` or `--full-access`, the same for every trial |
| `--max-steps N` | 40 | `FX_MAX_AGENT_STEPS` for every trial |
| `--timeout-ms N` | 300000 | Per-trial timeout; a timeout is a recorded failure |
| `--seed N` | 1 | Seed for task order |
| `--no-model` | off | Skip the model tier |
| `--out DIR` | `results/<timestamp>` | Output directory |
| `--keep-workspaces` | off | Keep trial workspaces for inspection |

Each trial runs in a new temporary workspace with `--no-save`, so no
configuration sees another's files, sessions, or output. Tasks run in a seeded
random order, and the configuration order rotates across tasks and
repetitions.

With `--auto`, fx may send some actions to its safety reviewer. Those calls are
counted as review calls, separately from the agent's model calls.

## Output

`results/<timestamp>/` holds three files built from the same trial records:

- `trials.json`: every trial, including failures and timeouts, with task and
  fixture digests, provider identity, limits, and the order it ran in.
- `summary.json`: per-configuration counts and distributions, paired
  comparisons, and the interpretation.
- `report.md`: the human-readable report.

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
