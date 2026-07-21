/**
 * Unit tests for Claude API error classification (no emulator required).
 */

const { expect } = require("chai");
const {
  classifyClaudeApiFailure,
  callClaudeMessages,
} = require("../claudeClient");

describe("classifyClaudeApiFailure", function () {
  it("maps Anthropic credit-balance errors to failed-precondition with a clear message", function () {
    const classified = classifyClaudeApiFailure(400, {
      type: "error",
      error: {
        type: "invalid_request_error",
        message:
          "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits.",
      },
    });

    expect(classified.code).to.equal("failed-precondition");
    expect(classified.code).to.not.equal("internal");
    expect(classified.message).to.match(/billing credits/i);
  });

  it("maps 429 to resource-exhausted", function () {
    const classified = classifyClaudeApiFailure(429, {
      error: { message: "Rate limit exceeded" },
    });
    expect(classified.code).to.equal("resource-exhausted");
  });

  it("maps 5xx to unavailable", function () {
    const classified = classifyClaudeApiFailure(503, {
      error: { message: "Overloaded" },
    });
    expect(classified.code).to.equal("unavailable");
  });

  it("maps retired-model not_found_error to failed-precondition", function () {
    const classified = classifyClaudeApiFailure(404, {
      type: "error",
      error: {
        type: "not_found_error",
        message: "model: claude-sonnet-4-20250514",
      },
    });
    expect(classified.code).to.equal("failed-precondition");
    expect(classified.message).to.match(/unknown AI model/i);
    expect(classified.message).to.include("claude-sonnet-4-20250514");
  });
});

describe("callClaudeMessages error surfacing", function () {
  it("throws failed-precondition (not internal) when Anthropic reports low credits", async function () {
    const fetchImpl = async () => ({
      ok: false,
      status: 400,
      text: async () =>
        JSON.stringify({
          type: "error",
          error: {
            type: "invalid_request_error",
            message:
              "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits.",
          },
        }),
    });

    let thrown = null;
    try {
      await callClaudeMessages({
        apiKey: "test-key",
        system: "sys",
        user: "hi",
        fetchImpl,
      });
    } catch (err) {
      thrown = err;
    }

    expect(thrown).to.be.an("Error");
    expect(thrown.code).to.equal("failed-precondition");
    expect(thrown.code).to.not.equal("internal");
    expect(String(thrown.message)).to.match(/billing credits/i);
  });
});
