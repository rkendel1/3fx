// Prints the baseline-versus-candidate table.  cd tests/e2e && bun ../../benchmarks/sequencing/run_context.ts [--repeats N] [--json]
import { CONDITIONS, tasks, runTask, outcomeCorrect } from "./context";

const repeats = Number(process.argv[process.argv.indexOf("--repeats") + 1]) || 3;
const rows: any[] = [];
for (const cond of Object.keys(CONDITIONS)) {
  for (const t of tasks) {
    const runs = [];
    for (let i = 0; i < repeats; i++) runs.push(await runTask(t, cond));
    const r = runs[0];
    const correct = runs.every(x => outcomeCorrect(t, x));
    const wall = runs.map(x => x.wall_ms).sort((a, b) => a - b);
    rows.push({
      cond, id: t.id, title: t.title, success: runs.every(x => x.success), correct, exit: r.exit, total_requests: r.total_requests, reviewer: r.review_calls,
      purposes: r.requests.map((q: any) => q.purpose).join(","), bytes_total: r.requests.reduce((a: number, q: any) => a + q.bytes, 0),
      first_bytes: r.requests[0].bytes, tools_count: r.tools_count, tools_bytes: r.requests[0].tools_bytes, instr_bytes: r.requests[0].instruction_bytes,
      tools_used: r.tools_used.join(","), tool_ms: r.tool_ms, model_ms: r.model_ms, wall_min: wall[0], wall_med: wall[Math.floor(wall.length / 2)], wall_max: wall.at(-1),
      deterministic: runs.every(x => x.total_requests === r.total_requests && x.requests.every((q: any, k: number) => q.bytes === r.requests[k].bytes || Math.abs(q.bytes - r.requests[k].bytes) < 8)),
      stderr: r.stderr,
    });
  }
}
if (process.argv.includes("--json")) console.log(JSON.stringify(rows, null, 1));
else {
  console.log("| condition | task | success | correct outcome | exit | requests (purposes) | request bytes total | first request bytes | tools (count / bytes) | tools used | wall ms min/med/max |");
  console.log("|---|---|---|---|---|---|---|---|---|---|---|");
  for (const x of rows) console.log(`| ${x.cond} | ${x.id} ${x.title} | ${x.success} | ${x.correct} | ${x.exit} | ${x.total_requests} (${x.purposes}) | ${x.bytes_total} | ${x.first_bytes} | ${x.tools_count} / ${x.tools_bytes} | ${x.tools_used || "-"} | ${x.wall_min}/${x.wall_med}/${x.wall_max} |`);
  console.log("\n| condition | tasks succeeded | correct outcomes | total requests | total request bytes | mean first-request bytes |");
  console.log("|---|---|---|---|---|");
  for (const cond of Object.keys(CONDITIONS)) {
    const xs = rows.filter(x => x.cond === cond);
    console.log(`| ${cond} | ${xs.filter(x => x.success).length}/${xs.length} | ${xs.filter(x => x.correct).length}/${xs.length} | ${xs.reduce((a, x) => a + x.total_requests, 0)} | ${xs.reduce((a, x) => a + x.bytes_total, 0)} | ${Math.round(xs.reduce((a, x) => a + x.first_bytes, 0) / xs.length)} |`);
  }
}
