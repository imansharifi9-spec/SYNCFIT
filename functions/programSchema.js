/**
 * Validates / normalizes CoachRoutineTemplate JSON for AI-generated programs.
 * Mirrors ios/SyncFit/Models/CoachRoutineModels.swift + coachRoutineTemplatePayload.
 */

const { randomUUID } = require("crypto");

const VALID_GOALS = Object.freeze([
  "progressive_overload",
  "maintenance",
  "strength",
]);

/**
 * @param {unknown} goal
 * @returns {string}
 */
function assertValidGoal(goal) {
  if (typeof goal !== "string" || !VALID_GOALS.includes(goal)) {
    const err = new Error(
      `goal must be one of: ${VALID_GOALS.join(", ")}`
    );
    err.code = "invalid-argument";
    throw err;
  }
  return goal;
}

/**
 * Strip accidental markdown fences from model output.
 * @param {string} text
 * @returns {string}
 */
function extractJsonText(text) {
  if (typeof text !== "string") return "";
  const trimmed = text.trim();
  const fence = trimmed.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/i);
  if (fence) return fence[1].trim();
  const firstBrace = trimmed.indexOf("{");
  const lastBrace = trimmed.lastIndexOf("}");
  if (firstBrace >= 0 && lastBrace > firstBrace) {
    return trimmed.slice(firstBrace, lastBrace + 1);
  }
  return trimmed;
}

/**
 * @param {unknown} value
 * @returns {boolean}
 */
function isUuidLike(value) {
  return (
    typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      value
    )
  );
}

/**
 * @param {unknown} raw
 * @returns {{ ok: true, template: object } | { ok: false, error: string }}
 */
function parseAndValidateCoachRoutineTemplate(raw) {
  let parsed;
  try {
    const text = typeof raw === "string" ? extractJsonText(raw) : null;
    parsed = text != null ? JSON.parse(text) : raw;
  } catch (err) {
    return { ok: false, error: `JSON parse failed: ${err.message}` };
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { ok: false, error: "Root value must be a JSON object." };
  }

  // Unwrap optional { template: {...} } chat-style payload.
  if (
    parsed.template &&
    typeof parsed.template === "object" &&
    !Array.isArray(parsed.template)
  ) {
    parsed = parsed.template;
  }

  if (typeof parsed.name !== "string" || !parsed.name.trim()) {
    return { ok: false, error: "template.name is required." };
  }

  if (!Array.isArray(parsed.days) || parsed.days.length === 0) {
    return { ok: false, error: "template.days must be a non-empty array." };
  }

  if (parsed.days.length > 7) {
    return { ok: false, error: "template.days must have at most 7 entries." };
  }

  const weekdaysSeen = new Set();
  const normalizedDays = [];

  for (let i = 0; i < parsed.days.length; i++) {
    const day = parsed.days[i];
    if (!day || typeof day !== "object" || Array.isArray(day)) {
      return { ok: false, error: `days[${i}] must be an object.` };
    }

    const weekday = Number(day.weekday);
    if (!Number.isInteger(weekday) || weekday < 1 || weekday > 7) {
      return {
        ok: false,
        error: `days[${i}].weekday must be an integer 1–7 (Sun=1 … Sat=7).`,
      };
    }
    if (weekdaysSeen.has(weekday)) {
      return {
        ok: false,
        error: `Duplicate weekday ${weekday} in days[].`,
      };
    }
    weekdaysSeen.add(weekday);

    if (typeof day.dayLabel !== "string" || !day.dayLabel.trim()) {
      return { ok: false, error: `days[${i}].dayLabel is required.` };
    }

    if (!Array.isArray(day.exercises)) {
      return { ok: false, error: `days[${i}].exercises must be an array.` };
    }

    const exercises = [];
    for (let j = 0; j < day.exercises.length; j++) {
      const ex = day.exercises[j];
      if (!ex || typeof ex !== "object" || Array.isArray(ex)) {
        return {
          ok: false,
          error: `days[${i}].exercises[${j}] must be an object.`,
        };
      }
      if (typeof ex.name !== "string" || !ex.name.trim()) {
        return {
          ok: false,
          error: `days[${i}].exercises[${j}].name is required.`,
        };
      }
      if (typeof ex.muscleGroup !== "string" || !ex.muscleGroup.trim()) {
        return {
          ok: false,
          error: `days[${i}].exercises[${j}].muscleGroup is required.`,
        };
      }

      const setCount = Number(ex.setCount);
      const reps = Number(ex.reps);
      if (!Number.isInteger(setCount) || setCount < 1) {
        return {
          ok: false,
          error: `days[${i}].exercises[${j}].setCount must be an integer ≥ 1.`,
        };
      }
      if (!Number.isInteger(reps) || reps < 1) {
        return {
          ok: false,
          error: `days[${i}].exercises[${j}].reps must be an integer ≥ 1.`,
        };
      }

      /** @type {Record<string, unknown>} */
      const normalizedEx = {
        id: isUuidLike(ex.id) ? ex.id : randomUUID(),
        name: ex.name.trim(),
        muscleGroup: ex.muscleGroup.trim(),
        setCount,
        reps,
      };

      if (ex.weight != null && ex.weight !== "") {
        const weight = Number(ex.weight);
        if (!Number.isFinite(weight) || weight < 0) {
          return {
            ok: false,
            error: `days[${i}].exercises[${j}].weight must be a non-negative number.`,
          };
        }
        normalizedEx.weight = weight;
      }

      exercises.push(normalizedEx);
    }

    const isRest =
      typeof day.isRest === "boolean"
        ? day.isRest || exercises.length === 0
        : exercises.length === 0;

    normalizedDays.push({
      id: isUuidLike(day.id) ? day.id : randomUUID(),
      weekday,
      dayLabel: day.dayLabel.trim(),
      isRest,
      exercises: isRest ? [] : exercises,
    });
  }

  const nowIso = new Date().toISOString();
  const template = {
    id: isUuidLike(parsed.id) ? parsed.id : randomUUID(),
    name: parsed.name.trim(),
    days: normalizedDays,
    createdAt: nowIso,
    updatedAt: nowIso,
  };

  return { ok: true, template };
}

module.exports = {
  VALID_GOALS,
  assertValidGoal,
  extractJsonText,
  parseAndValidateCoachRoutineTemplate,
};
