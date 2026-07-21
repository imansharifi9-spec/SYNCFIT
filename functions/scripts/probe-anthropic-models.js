#!/usr/bin/env node
/**
 * Probe Anthropic model IDs without printing the API key.
 * Usage: gcloud secrets versions access latest --secret=ANTHROPIC_API_KEY --project=syncfit-8441f \
 *   | node functions/scripts/probe-anthropic-models.js
 */
const models = [
  "claude-sonnet-4-20250514", // retired — expect not_found
  "claude-sonnet-4-6", // PROGRAM_MODEL replacement
  "claude-haiku-4-5-20251001", // companion / insights (known working)
];

async function probe(apiKey, model) {
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model,
      max_tokens: 16,
      messages: [{ role: "user", content: "Reply with OK only." }],
    }),
  });
  const text = await response.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    body = { raw: text.slice(0, 200) };
  }
  return {
    model,
    httpStatus: response.status,
    errorType: body?.error?.type || null,
    errorMessage: body?.error?.message || null,
    ok: response.ok,
    replyPreview: response.ok
      ? (body?.content || [])
          .filter((b) => b.type === "text")
          .map((b) => b.text)
          .join("")
          .slice(0, 40)
      : null,
  };
}

async function main() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const apiKey = Buffer.concat(chunks).toString("utf8").trim();
  if (!apiKey) {
    console.error("No API key on stdin.");
    process.exit(1);
  }

  const results = [];
  for (const model of models) {
    results.push(await probe(apiKey, model));
  }
  console.log(JSON.stringify(results, null, 2));
}

main().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
