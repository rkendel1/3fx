// Completes Vikunja tasks through AppPort.

/**
 * `call(capability, version, input)` sends one AppPort request and resolves
 * with the capability output, or rejects with an error whose `code` property
 * is the AppPort error code.
 *
 * Mark the task done and report `{ id, done, verified }`.
 */
export async function completeAndVerify(call, id) {
  throw new Error("not implemented");
}
