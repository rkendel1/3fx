// Prints the sequencing table.  cd tests/e2e && bun ../../benchmarks/sequencing/run.ts [--json]
import { scenarios, runScenario } from "./lib";

const results = [];
for (const s of scenarios) results.push(await runScenario(s));
if (process.argv.includes("--json")) console.log(JSON.stringify(results, null, 1));
else {
  console.log("| id | scenario | exit | model calls (init/after tools/after failed) | review calls | proposed | executed | failed/rejected | request bytes per call | messages per call | prefix stable | provider in/out |");
  console.log("|---|---|---|---|---|---|---|---|---|---|---|---|");
  for (const r of results) console.log(`| ${r.id} | ${r.title} | ${r.exit} | ${r.model_calls} (${r.reasons}) | ${r.review_calls} | ${r.proposed} | ${r.executed} | ${r.rejected_or_failed} | ${r.request_bytes.join(", ")} | ${r.messages.join(", ")} | ${r.prefix_stable} | ${r.provider_in}/${r.provider_out} |`);
  console.log(`\ntools schema bytes in first request: ${results[0].tools_bytes}; first-request messages bytes: ${results[0].first_messages_bytes}`);
  for (const r of results) console.log(`${r.id}: final="${r.output}" files=${r.files.join(",") || "-"} stderr="${r.stderr}"`);
}
