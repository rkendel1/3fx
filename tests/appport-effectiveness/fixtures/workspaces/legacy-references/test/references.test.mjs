import { test } from "node:test";
import assert from "node:assert/strict";
import { extractTaskRefs } from "../src/references.mjs";

test("returns references in order", () => {
  assert.deepEqual(extractTaskRefs("do vikunja-task:3 then vikunja-task:1"), [3, 1]);
});

test("returns nothing without references", () => {
  assert.deepEqual(extractTaskRefs("nothing here"), []);
});
