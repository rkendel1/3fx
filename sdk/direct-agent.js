// Agent loop for a caller-supplied model. `createFxAgent({ model })` takes this
// path when `model` is a `createFxModel()` handle (an object with `chat()` and
// `stream()`), so the configured provider is called directly: no fx core, no
// Vercel AI Gateway URL, and no gateway credential. The loop only sequences
// model calls and host tools; it adds no provider abstraction of its own.

const defaultMaxSteps = 100;
const checkpointMagic = "libfx.direct-checkpoint";
const encoder = new TextEncoder();
const decoder = new TextDecoder();

// Options that configure the gateway-backed core and mean nothing here.
// Rejecting them keeps a stale gateway setting from being silently ignored.
const gatewayOnlyOptions = ["apiKey", "gatewayChatUrl", "effort", "fast", "ultrafast", "fetch"];

export function isDirectModel(value) {
  return value !== null && typeof value === "object" &&
    typeof value.chat === "function" && typeof value.stream === "function";
}

function usageFrom(completion) {
  const usage = completion?.usage;
  const result = {};
  if (!usage) return result;
  const map = {
    inputTokens: usage.input_tokens,
    outputTokens: usage.output_tokens,
    cacheReadTokens: usage.cache_read_tokens,
    cacheWriteTokens: usage.cache_write_tokens,
    reasoningTokens: usage.reasoning_tokens,
  };
  for (const [key, value] of Object.entries(map)) if (Number.isSafeInteger(value)) result[key] = value;
  return result;
}

function addUsage(total, usage) {
  for (const [key, value] of Object.entries(usage)) total[key] = (total[key] ?? 0) + value;
}

function parseArguments(json) {
  if (json === undefined || json === null || json === "") return {};
  const value = JSON.parse(json);
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("tool arguments must be a JSON object");
  }
  return value;
}

function restoreMessages(checkpoint) {
  if (checkpoint === null) return [];
  let parsed;
  try { parsed = JSON.parse(decoder.decode(checkpoint)); } catch {
    throw new Error("checkpoint was not created by a direct-model agent");
  }
  if (parsed?.format !== checkpointMagic || !Array.isArray(parsed.messages)) {
    throw new Error("checkpoint was not created by a direct-model agent");
  }
  return parsed.messages;
}

/**
 * `helpers` supplies the SDK's shared validators so direct and gateway agents
 * accept identical tools, instructions, prompts, and checkpoints.
 */
export function createDirectAgent(options, helpers) {
  for (const name of gatewayOnlyOptions) {
    if (Object.hasOwn(options, name) && options[name] !== undefined) {
      throw new TypeError(`${name} does not apply when model is a createFxModel() handle; configure the provider on the model`);
    }
  }
  const model = options.model;
  const maxSteps = options.maxSteps ?? defaultMaxSteps;
  if (options.maxOutputTokens !== undefined && (!Number.isSafeInteger(options.maxOutputTokens) || options.maxOutputTokens < 1)) {
    throw new TypeError("maxOutputTokens must be a positive integer");
  }
  if (!Number.isSafeInteger(maxSteps) || maxSteps < 1) throw new TypeError("maxSteps must be a positive integer");
  const hostTools = helpers.normalizeHostTools(options.tools);
  if (hostTools.descriptors.some((tool) => tool.providerExecuted)) {
    throw new TypeError("provider-executed tools require the Vercel AI Gateway agent");
  }
  const instructions = helpers.normalizeInstructions(options.instructions);
  const messages = restoreMessages(helpers.checkpointBytes(options.checkpoint));
  const toolSpecs = hostTools.descriptors.map((tool) => ({
    name: tool.name,
    description: tool.description,
    input_schema: tool.inputSchema,
  }));
  const onEvent = (event) => { try { options.onEvent?.({ ...event, timestamp: performance.now() }); } catch {} };

  let activeTurn = null;
  let closed = false;

  async function runTool(call, signal) {
    let input;
    try { input = parseArguments(call.arguments_json); } catch (error) {
      return { content: `invalid arguments for ${call.name}: ${error.message}`, isError: true, input: {} };
    }
    const execute = hostTools.executors.get(call.name);
    if (!execute) return { content: `unknown host tool: ${call.name}`, isError: true, input };
    try {
      const value = await execute(input, { signal });
      const normalized = helpers.hostToolContent(value);
      // A typed result carries images the text-only model API cannot take, so
      // only its text reaches the model.
      const content = normalized.rich ? JSON.parse(normalized.content).text : normalized.content;
      return { content, isError: normalized.isError === true, input };
    } catch (error) {
      const text = error?.toolResult?.type === "libfx.tool-result" ? error.toolResult.text : undefined;
      return { content: text ?? (error instanceof Error ? error.message : String(error)), isError: true, input };
    }
  }

  async function* drive(turn, signal) {
    const usage = {};
    let steps = 0;
    const drainSteering = () => {
      const events = [];
      for (const text of turn.steering.splice(0)) {
        messages.push({ role: "user", content: text });
        events.push({ type: "user_message", text });
      }
      return events;
    };
    while (true) {
      if (signal.aborted) return { stopReason: "cancelled", usage };
      yield* drainSteering();
      if (steps >= maxSteps) return { stopReason: "max_turn_requests", usage };
      steps += 1;
      const request = {
        messages: [...(instructions ? [{ role: "system", content: instructions }] : []), ...messages],
        ...(toolSpecs.length ? { tools: toolSpecs } : {}),
        ...(options.maxOutputTokens === undefined ? {} : { max_output_tokens: options.maxOutputTokens }),
      };
      let completion;
      let failure;
      onEvent({ type: "model.request", step: steps, messages: request.messages.length });
      const iterator = model.stream(request, { signal })[Symbol.asyncIterator]();
      try {
        for (let next = await iterator.next(); !next.done; next = await iterator.next()) {
          const event = next.value;
          if (event.type === "text_delta") yield { type: "text_delta", delta: event.text };
          else if (event.type === "reasoning_delta") yield { type: "reasoning_delta", delta: event.text };
          else if (event.type === "completion") completion = event.completion;
          else if (event.type === "failure") failure = event.failure;
        }
      } catch (error) {
        if (signal.aborted) return { stopReason: "cancelled", usage };
        throw error;
      } finally {
        await iterator.return?.();
      }
      if (signal.aborted) return { stopReason: "cancelled", usage };
      if (failure) {
        const error = new Error(`model request failed: ${failure.kind}${failure.detail ? `: ${failure.detail}` : ""}`);
        error.code = "LIBFX_MODEL_FAILED";
        error.kind = failure.kind;
        throw error;
      }
      if (!completion) throw new Error("model stream ended without a completion");
      onEvent({ type: "model.response", step: steps, finishReason: completion.finish_reason ?? null, toolCalls: (completion.tool_calls ?? []).length });
      addUsage(usage, usageFrom(completion));
      const calls = completion.tool_calls ?? [];
      messages.push({
        role: "assistant",
        content: completion.content ?? null,
        ...(calls.length ? { tool_calls: calls } : {}),
      });
      if (calls.length === 0) {
        if (completion.finish_reason === "length") return { stopReason: "max_tokens", usage };
        if (completion.finish_reason === "content_filter") return { stopReason: "refused", usage };
        return { stopReason: "end_turn", usage };
      }
      for (const call of calls) {
        if (signal.aborted) return { stopReason: "cancelled", usage };
        let preview = {};
        try { preview = { input: parseArguments(call.arguments_json) }; } catch {}
        yield { type: "tool_start", id: call.id, name: call.name, ...preview };
        const result = await runTool(call, signal);
        // A cancelled turn leaves history without a dangling tool call.
        messages.push({ role: "tool", tool_call_id: call.id, content: result.content });
        yield { type: "tool_end", id: call.id, name: call.name, content: result.content, isError: result.isError };
      }
    }
  }

  return {
    prompt(input, promptOptions = {}) {
      if (closed) throw new Error("fx agent is closed");
      if (activeTurn) throw new Error("a prompt is already in progress for this session");
      const blocks = helpers.normalizePromptInput(input);
      if (blocks.some((block) => block.type === "image")) {
        throw new TypeError("image prompts are not supported with a createFxModel() handle");
      }
      const text = blocks.map((block) => block.type === "text" ? block.text : block.resource?.text ?? "").join("\n");
      const controller = new AbortController();
      const turn = { steering: [], controller, finished: false, taken: false, started: false };
      activeTurn = turn;
      const outerSignal = promptOptions.signal;
      const abort = () => cancel();
      let resolveResult;
      let rejectResult;
      const result = new Promise((resolve, reject) => { resolveResult = resolve; rejectResult = reject; });
      void result.catch(() => {});
      // Exactly one of these runs, whichever way the turn ends: completion,
      // failure, cancel(), an early `break` out of the event loop, or close().
      const settle = (outcome, error) => {
        if (turn.finished) return;
        turn.finished = true;
        outerSignal?.removeEventListener("abort", abort);
        if (activeTurn === turn) activeTurn = null;
        if (error) rejectResult(error);
        else resolveResult(outcome);
      };
      // A turn that has not started has no history to undo and no generator
      // to unwind, so it settles immediately.
      function cancel() {
        controller.abort();
        if (!turn.started) settle({ stopReason: "cancelled", usage: {} });
      }
      turn.cancel = cancel;
      turn.settled = result;
      if (outerSignal?.aborted) cancel();
      else outerSignal?.addEventListener("abort", abort, { once: true });
      const run = async function* () {
        if (turn.finished) return;
        turn.started = true;
        // An already-aborted prompt changes no history.
        if (controller.signal.aborted) { settle({ stopReason: "cancelled", usage: {} }); return; }
        const rollback = messages.length;
        messages.push({ role: "user", content: text });
        try {
          const outcome = yield* drive(turn, controller.signal);
          // A cancelled turn is dropped whole so history never holds a tool
          // call without its result.
          if (outcome.stopReason === "cancelled") messages.length = rollback;
          settle(outcome);
        } catch (error) {
          messages.length = rollback;
          settle(undefined, error);
          throw error;
        } finally {
          if (!turn.finished) {
            controller.abort();
            messages.length = rollback;
            settle({ stopReason: "cancelled", usage: {} });
          }
        }
      };
      const source = run();
      // Awaiting only `result` must still run the turn, so the first `then`
      // drains the events when nobody has taken the iterator.
      const drainUnread = () => {
        if (turn.taken) return;
        turn.taken = true;
        void (async () => { try { for await (const _ of source) {} } catch {} })();
      };
      const lazyResult = {
        then(onFulfilled, onRejected) { drainUnread(); return result.then(onFulfilled, onRejected); },
        catch(onRejected) { return lazyResult.then(undefined, onRejected); },
        finally(onFinally) { drainUnread(); return result.finally(onFinally); },
      };
      return {
        cancel,
        steer(steerInput) {
          if (turn.finished) return Promise.reject(new Error("no prompt is running"));
          const steerBlocks = helpers.normalizePromptInput(steerInput);
          if (steerBlocks.some((block) => block.type !== "text")) {
            return Promise.reject(new TypeError("steering accepts only text blocks"));
          }
          turn.steering.push(steerBlocks.map((block) => block.text).join("\n"));
          return Promise.resolve();
        },
        [Symbol.asyncIterator]() {
          if (turn.taken) throw new Error("a turn has only one event consumer");
          turn.taken = true;
          return {
            next: () => source.next(),
            return: (value) => { cancel(); return source.return(value); },
            throw: (error) => { cancel(); return source.throw(error); },
            [Symbol.asyncIterator]() { return this; },
          };
        },
        result: lazyResult,
      };
    },
    async checkpoint() {
      if (closed) throw new Error("fx agent is closed");
      // Mid-turn history can hold a tool call without its result.
      if (activeTurn) throw new Error("a checkpoint cannot be taken while a prompt is in progress");
      return encoder.encode(JSON.stringify({ format: checkpointMagic, messages }));
    },
    async close() {
      if (closed) return;
      const turn = activeTurn;
      closed = true;
      if (turn) {
        turn.cancel();
        await turn.settled.catch(() => {});
      }
    },
  };
}
