/**
 * Anthropic Messages API client for workout program generation.
 * API key is injected — never hardcode secrets.
 */

const DEFAULT_MODEL = "claude-sonnet-4-6";
/** Structured program generation — keep on Sonnet (shared by generateWorkoutProgram + generateCoachRoutineDraft). */
const PROGRAM_MODEL = DEFAULT_MODEL;
/** Casual AI Coach chat — Haiku 4.5 (~3× cheaper than Sonnet for this use case). */
const COMPANION_CHAT_MODEL = "claude-haiku-4-5-20251001";
const DEFAULT_MAX_TOKENS = 4096;

/**
 * Map Anthropic HTTP / error payloads to Firebase-callable-safe codes.
 * Never use "internal" for provider failures — Firebase strips those messages
 * from the client and only shows a bare INTERNAL.
 *
 * @param {number} status
 * @param {object|null} body
 * @returns {{ code: string, message: string }}
 */
function classifyClaudeApiFailure(status, body) {
  const providerMessage =
    (body && body.error && typeof body.error.message === "string" && body.error.message) ||
    (body && typeof body.message === "string" && body.message) ||
    "";
  const lower = providerMessage.toLowerCase();
  const errorType =
    (body && body.error && typeof body.error.type === "string" && body.error.type) || "";

  if (
    lower.includes("credit balance") ||
    lower.includes("billing") ||
    lower.includes("purchase credits") ||
    lower.includes("too low to access")
  ) {
    return {
      code: "failed-precondition",
      message:
        "AI Coach is temporarily unavailable: the AI provider account needs billing credits. Please try again after credits are added.",
    };
  }

  if (status === 401 || status === 403 || lower.includes("invalid api key") || lower.includes("authentication")) {
    return {
      code: "failed-precondition",
      message: "AI Coach is misconfigured (AI provider authentication failed).",
    };
  }

  if (status >= 500) {
    return {
      code: "unavailable",
      message: "AI Coach’s AI provider is temporarily unavailable. Please try again shortly.",
    };
  }

  if (status === 429 || lower.includes("rate limit") || lower.includes("overloaded")) {
    return {
      code: "resource-exhausted",
      message: "AI Coach is busy right now. Please wait a moment and try again.",
    };
  }

  // Retired / unknown model IDs come back as not_found_error with message like
  // "model: claude-sonnet-4-20250514" (status often 404).
  if (
    errorType === "not_found_error" ||
    status === 404 ||
    (lower.startsWith("model:") && lower.includes("claude"))
  ) {
    return {
      code: "failed-precondition",
      message: providerMessage
        ? `AI Coach is misconfigured (unknown AI model): ${providerMessage}`
        : "AI Coach is misconfigured (unknown AI model).",
    };
  }

  if (status === 400 || (body && body.error && body.error.type === "invalid_request_error")) {
    return {
      code: "failed-precondition",
      message: providerMessage
        ? `AI Coach request was rejected by the AI provider: ${providerMessage}`
        : "AI Coach request was rejected by the AI provider.",
    };
  }

  return {
    code: "unavailable",
    message: providerMessage
      ? `AI Coach couldn’t reach the AI provider: ${providerMessage}`
      : `AI Coach couldn’t reach the AI provider (HTTP ${status}).`,
  };
}

/**
 * @param {object} params
 * @param {string} params.apiKey
 * @param {string} params.system
 * @param {string} [params.user]
 * @param {{ role: "user"|"assistant", content: string }[]} [params.messages]
 * @param {string} [params.model]
 * @param {number} [params.maxTokens]
 * @param {typeof fetch} [params.fetchImpl]
 * @returns {Promise<string>} Raw assistant text content
 */
async function callClaudeMessages({
  apiKey,
  system,
  user,
  messages,
  model = DEFAULT_MODEL,
  maxTokens = DEFAULT_MAX_TOKENS,
  fetchImpl = globalThis.fetch,
}) {
  if (!apiKey) {
    const err = new Error("ANTHROPIC_API_KEY is not configured.");
    err.code = "failed-precondition";
    throw err;
  }
  if (typeof fetchImpl !== "function") {
    const err = new Error("fetch is not available in this runtime.");
    err.code = "unavailable";
    throw err;
  }

  const requestMessages = Array.isArray(messages) && messages.length > 0
    ? messages
    : [{ role: "user", content: user }];

  const response = await fetchImpl("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model,
      max_tokens: maxTokens,
      system,
      messages: requestMessages,
    }),
  });

  const bodyText = await response.text();
  let body;
  try {
    body = JSON.parse(bodyText);
  } catch {
    const err = new Error(
      `AI Coach couldn’t parse the AI provider response (HTTP ${response.status}).`
    );
    err.code = "unavailable";
    err.raw = bodyText;
    throw err;
  }

  if (!response.ok) {
    const classified = classifyClaudeApiFailure(response.status, body);
    const err = new Error(classified.message);
    err.code = classified.code;
    err.raw = bodyText;
    err.providerMessage =
      (body && body.error && body.error.message) || classified.message;
    throw err;
  }

  const blocks = Array.isArray(body.content) ? body.content : [];
  const text = blocks
    .filter((b) => b && b.type === "text" && typeof b.text === "string")
    .map((b) => b.text)
    .join("\n")
    .trim();

  if (!text) {
    const err = new Error("AI Coach received an empty reply from the AI provider.");
    err.code = "unavailable";
    err.raw = bodyText;
    throw err;
  }

  return text;
}

/**
 * @param {object} args
 * @param {string} args.goal
 * @param {object} args.trainingSummary
 * @returns {{ system: string, user: string }}
 */
function buildProgramPrompt({ goal, trainingSummary }) {
  const system = [
    "You are SyncFit's programming coach.",
    "Respond ONLY with a single valid JSON object — no markdown, no prose, no code fences.",
    "The JSON must match this exact CoachRoutineTemplate schema used by SyncFit:",
    "{",
    '  "id": "<uuid>",',
    '  "name": "<program name>",',
    '  "createdAt": "<ISO-8601>",',
    '  "updatedAt": "<ISO-8601>",',
    '  "days": [',
    "    {",
    '      "id": "<uuid>",',
    '      "weekday": <1-7 Sun=1 Sat=7>,',
    '      "dayLabel": "<string>",',
    '      "isRest": <boolean>,',
    '      "exercises": [',
    "        {",
    '          "id": "<uuid>",',
    '          "name": "<exercise name>",',
    '          "muscleGroup": "<string>",',
    '          "setCount": <int >= 1>,',
    '          "reps": <int >= 1>,',
    '          "weight": <optional number>',
    "        }",
    "      ]",
    "    }",
    "  ]",
    "}",
    "Include exactly 7 days covering weekdays 1–7 with unique weekday values.",
    "Rest days: isRest true and exercises [].",
    "Do NOT include restSeconds, tempo, rpe, or any fields outside this schema.",
    "Use realistic compound/accessory pairings for the selected goal.",
  ].join("\n");

  const user = [
    `Selected goal: ${goal}`,
    "",
    "Athlete training/nutrition context (last ~30 days from SyncFit logs):",
    JSON.stringify(trainingSummary, null, 2),
    "",
    "Counting note: workoutSessionCount/workoutCount are DISTINCT sessions (not per-exercise documents).",
    "muscleGroupFrequency values are session tallies. Prefer those over exerciseEntryCount.",
    "",
    "Generate a weekly CoachRoutineTemplate JSON program tailored to this athlete and goal.",
  ].join("\n");

  return { system, user };
}

module.exports = {
  DEFAULT_MODEL,
  PROGRAM_MODEL,
  COMPANION_CHAT_MODEL,
  DEFAULT_MAX_TOKENS,
  callClaudeMessages,
  buildProgramPrompt,
  classifyClaudeApiFailure,
};
