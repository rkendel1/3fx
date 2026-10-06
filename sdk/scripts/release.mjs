#!/usr/bin/env node
/**
 * Builds, verifies, and publishes the SDK package described by sdk/package.json.
 *
 * The publishable package needs a native addon for every supported platform,
 * so this cross-builds all four with Zig, checks the Linux addons against the
 * glibc 2.34 baseline, builds both wasm surfaces, runs the native model tests
 * on the host's addon when there is one, and assembles the package with
 * package-libfx.mjs. A version that is already on npm is skipped.
 *
 * Usage (from the repository root, with Node.js 24 and Zig on PATH):
 *   node sdk/scripts/release.mjs [--dry-run] [--provenance]
 *
 * Publishing uses inherited stdio so npm can prompt for a one-time password
 * locally; CI authenticates with NODE_AUTH_TOKEN.
 */
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, readFile, readdir, rm, symlink } from "node:fs/promises";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const outputRoot = join(repoRoot, "sdk", "dist", "release");

// package-libfx.mjs requires exactly these addon file names.
const TARGETS = [
  { platform: "linux-x64", target: "x86_64-linux-gnu.2.34" },
  { platform: "linux-arm64", target: "aarch64-linux-gnu.2.34" },
  { platform: "darwin-x64", target: "x86_64-macos" },
  { platform: "darwin-arm64", target: "aarch64-macos" },
];

const args = new Set(process.argv.slice(2));
for (const arg of args) {
  if (arg !== "--dry-run" && arg !== "--provenance") throw new Error(`Unknown argument: ${arg}`);
}

function run(command, commandArgs, options = {}) {
  console.log(`\n$ ${[command, ...commandArgs].join(" ")}`);
  const result = spawnSync(command, commandArgs, { stdio: "inherit", cwd: repoRoot, ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} ${commandArgs.join(" ")} exited with ${result.status}.`);
}

function findTool(names, extraDirs) {
  for (const dir of [...(process.env.PATH ?? "").split(delimiter), ...extraDirs]) {
    for (const name of names) if (dir && existsSync(join(dir, name))) return join(dir, name);
  }
  return undefined;
}

const [major] = process.versions.node.split(".").map(Number);
if (major < 24) throw new Error(`Releasing requires Node.js 24 or newer; running ${process.version}.`);

const { name, version } = JSON.parse(await readFile(join(repoRoot, "sdk", "package.json"), "utf8"));
const published = spawnSync("npm", ["view", `${name}@${version}`, "version"], { encoding: "utf8" });
const alreadyPublished = published.status === 0 && published.stdout.trim() === version;
if (alreadyPublished && !args.has("--dry-run")) {
  console.log(`${name}@${version} is already on npm; bump sdk/package.json to release.`);
  process.exit(0);
}

const nodeInclude = resolve(dirname(process.execPath), "..", "include", "node");
if (!existsSync(join(nodeInclude, "node_api.h"))) {
  throw new Error(`node_api.h not found under ${nodeInclude}; use a Node.js install that ships headers.`);
}
const readelf = findTool(["readelf", "llvm-readelf"], ["/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin"]);
if (readelf === undefined) {
  throw new Error("readelf or llvm-readelf is required to verify the Linux addons' glibc baseline.");
}

await rm(outputRoot, { recursive: true, force: true });
const addonsDir = join(outputRoot, "addons");
const toolsDir = join(outputRoot, "bin");
await mkdir(addonsDir, { recursive: true });
await mkdir(toolsDir, { recursive: true });
// check-linux-abi.py invokes `readelf` by that exact name.
await symlink(readelf, join(toolsDir, "readelf"));
const toolEnv = { ...process.env, PATH: `${toolsDir}${delimiter}${process.env.PATH ?? ""}` };

const addons = [];
for (const { platform, target } of TARGETS) {
  const prefix = join(outputRoot, `build-${platform}`);
  run("zig", [
    "build",
    "-Dnapi-surface=core",
    "-Doptimize=ReleaseSafe",
    `-Dtarget=${target}`,
    "-Dcpu=baseline",
    `-Dnode-include-dir=${nodeInclude}`,
    "-p",
    prefix,
  ]);
  const addon = join(addonsDir, `libfx.${platform}.node`);
  run("cp", [join(prefix, "lib", "libfx.node"), addon]);
  if (platform.startsWith("linux")) {
    run("python3", [join(repoRoot, "sdk", "scripts", "check-linux-abi.py"), addon], { env: toolEnv });
  }
  addons.push(addon);
}
run("zig", ["build", "-Dwasm-surface=core"]);
run("zig", ["build", "-Dwasm-surface=term"]);

const hostAddon = join(addonsDir, `libfx.${process.platform}-${process.arch}.node`);
if (existsSync(hostAddon)) {
  run(process.execPath, [join(repoRoot, "sdk", "tests", "test-native-model.mjs"), hostAddon]);
}

const packageDir = join(outputRoot, "package");
run(process.execPath, [join(repoRoot, "sdk", "scripts", "package-libfx.mjs"), packageDir, ...addons]);
run("npm", ["pack", "--pack-destination", outputRoot], { cwd: packageDir });
const tarball = (await readdir(outputRoot)).find((entry) => entry.endsWith(`-${version}.tgz`));
if (tarball === undefined) throw new Error(`Expected a packed ${name}@${version} tarball in ${outputRoot}.`);

// npm rejects a dry run of a published version, so a rehearsal stops after packing.
if (alreadyPublished) {
  console.log(`Dry run: ${name}@${version} is already on npm; built and verified ${tarball}.`);
  process.exit(0);
}
run("npm", [
  "publish",
  join(outputRoot, tarball),
  "--access",
  "public",
  ...(args.has("--provenance") ? ["--provenance"] : []),
  ...(args.has("--dry-run") ? ["--dry-run"] : []),
]);
console.log(`${args.has("--dry-run") ? "Dry run for" : "Published"} ${name}@${version}`);
