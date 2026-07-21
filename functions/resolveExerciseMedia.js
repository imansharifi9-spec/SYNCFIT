/**
 * Resolve ExerciseDB demo GIF URLs by exercise name, with Firestore caching.
 *
 * Cache: exerciseMedia/{normalizedName}
 * External API: https://oss.exercisedb.dev/api/v1/exercises?name=...
 *
 * Resolution order:
 * 1. Hardcoded EXERCISE_MEDIA_OVERRIDES (canonical exerciseId) — checked first
 * 2. Firestore cache (with self-heal for weak historical matches)
 * 3. ExerciseDB name search + strict scorer (MIN_REASONABLE_SCORE)
 *
 * Matching is intentionally strict: weak token overlap (e.g. "face pull" →
 * "barbell rack pull" via shared "pull") must return not_found, never a bad GIF.
 */

const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { HttpsError } = require("firebase-functions/v2/https");

const EXERCISEDB_BASE = "https://oss.exercisedb.dev/api/v1/exercises";
const STATIC_GIF_BASE = "https://static.exercisedb.dev/media";
const CACHE_COLLECTION = "exerciseMedia";

/**
 * Bump when matching/self-heal logic changes. Returned by callables so we can
 * verify the live deploy matches this repo (not an old cached build).
 */
const MEDIA_LOGIC_VERSION = "2026-07-16-overrides-v5";

/** Minimum score to accept a non-exact match (phrase containment / full-token). */
const MIN_REASONABLE_SCORE = 500;

/**
 * Manual canonical ExerciseDB IDs for SyncFit library names.
 * Keys = normalizeExerciseName(app name). Checked before cache/API fuzzy search.
 * Verified against static.exercisedb.dev GIF frames (2026-07-16).
 *
 * @type {Record<string, { exerciseId: string, matchedName: string, targetMuscles?: string[] }>}
 */
const EXERCISE_MEDIA_OVERRIDES = {
  // Wrong fuzzy matches → canonical
  squat: {
    exerciseId: "qXTaZnJ",
    matchedName: "barbell full squat",
    targetMuscles: ["glutes"],
  },
  "push up": {
    exerciseId: "I4hDWkc",
    matchedName: "push-up",
    targetMuscles: ["pectorals"],
  },
  deadlift: {
    exerciseId: "ila4NZS",
    matchedName: "barbell deadlift",
    targetMuscles: ["glutes"],
  },
  "overhead press": {
    exerciseId: "wdRZISl",
    matchedName: "barbell standing close grip military press",
    targetMuscles: ["delts"],
  },
  "barbell row": {
    exerciseId: "eZyBC3j",
    matchedName: "barbell bent over row",
    targetMuscles: ["upper back"],
  },
  "bench press": {
    exerciseId: "EIeI8Vf",
    matchedName: "barbell bench press",
    targetMuscles: ["pectorals"],
  },
  "incline bench press": {
    exerciseId: "3TZduzM",
    matchedName: "barbell incline bench press",
    targetMuscles: ["pectorals"],
  },
  "lateral raise": {
    exerciseId: "DsgkuIt",
    matchedName: "dumbbell lateral raise",
    targetMuscles: ["delts"],
  },
  "leg press": {
    exerciseId: "10Z2DXU",
    matchedName: "sled 45° leg press",
    targetMuscles: ["glutes"],
  },
  "calf raise": {
    exerciseId: "ykUOVze",
    matchedName: "lever standing calf raise",
    targetMuscles: ["calves"],
  },
  plank: {
    exerciseId: "VBAWRPG",
    matchedName: "weighted front plank",
    targetMuscles: ["abs"],
  },
  "pull up": {
    exerciseId: "Qqi7bko",
    matchedName: "wide grip pull-up",
    targetMuscles: ["lats"],
  },
  "lat pulldown": {
    exerciseId: "qdRxqCj",
    matchedName: "cable pulldown (pro lat bar)",
    targetMuscles: ["lats"],
  },
  "cable fly": {
    exerciseId: "xLYSdtg",
    matchedName: "cable middle fly",
    targetMuscles: ["pectorals"],
  },

  // Missing / not_found under strict search → canonical
  "seated cable row": {
    exerciseId: "fUBheHs",
    matchedName: "cable seated row",
    targetMuscles: ["upper back"],
  },
  "dumbbell row": {
    exerciseId: "BJ0Hz5L",
    matchedName: "dumbbell bent over row",
    targetMuscles: ["upper back"],
  },
  "leg extension": {
    exerciseId: "my33uHU",
    matchedName: "lever leg extension",
    targetMuscles: ["quads"],
  },
  "dumbbell shoulder press": {
    exerciseId: "znQUdHY",
    matchedName: "dumbbell seated shoulder press",
    targetMuscles: ["delts"],
  },
  "cable crunch": {
    exerciseId: "WW95auq",
    matchedName: "cable kneeling crunch",
    targetMuscles: ["abs"],
  },
  "ab wheel rollout": {
    exerciseId: "NAgVB3t",
    matchedName: "wheel rollerout",
    targetMuscles: ["abs"],
  },
  // ExerciseDB has no "face pull"; rope high-pulley rear-delt row is the visual match
  "face pull": {
    exerciseId: "wqNPGCg",
    matchedName: "cable rear delt row (with rope)",
    targetMuscles: ["delts"],
  },
  "treadmill run": {
    exerciseId: "oLrKqDH",
    matchedName: "run",
    targetMuscles: ["cardiovascular system"],
  },
  "stair climber": {
    exerciseId: "j9Q5crt",
    matchedName: "walking on stepmill",
    targetMuscles: ["cardiovascular system"],
  },
  "tricep pushdown": {
    exerciseId: "3ZflifB",
    matchedName: "cable pushdown",
    targetMuscles: ["triceps"],
  },
  "dumbbell curl": {
    exerciseId: "NbVPDMW",
    matchedName: "dumbbell biceps curl",
    targetMuscles: ["biceps"],
  },

  // Catalog expansion (approved 2026-07-16; excludes Bulgarian Split Squat)
  "decline bench press": {
    exerciseId: "GrO65fd",
    matchedName: "barbell decline bench press",
    targetMuscles: ["pectorals"],
  },
  "close grip bench press": {
    exerciseId: "da4cXST",
    matchedName: "ez-bar close-grip bench press",
    targetMuscles: ["triceps"],
  },
  "dumbbell fly": {
    exerciseId: "yz9nUhF",
    matchedName: "dumbbell fly",
    targetMuscles: ["pectorals"],
  },
  "chest dip": {
    exerciseId: "9WTm7dq",
    matchedName: "chest dip",
    targetMuscles: ["pectorals"],
  },
  "chin up": {
    exerciseId: "T2mxWqc",
    matchedName: "chin-up",
    targetMuscles: ["lats"],
  },
  "t bar row": {
    exerciseId: "BgljGjd",
    matchedName: "lever reverse t-bar row",
    targetMuscles: ["upper back"],
  },
  "straight arm pulldown": {
    exerciseId: "x69MAlq",
    matchedName: "cable straight arm pulldown",
    targetMuscles: ["lats"],
  },
  "dumbbell pullover": {
    exerciseId: "9XjtHvS",
    matchedName: "dumbbell pullover",
    targetMuscles: ["lats"],
  },
  "inverted row": {
    exerciseId: "bZGHsAZ",
    matchedName: "inverted row",
    targetMuscles: ["upper back"],
  },
  "arnold press": {
    exerciseId: "Xy4jlWA",
    matchedName: "dumbbell arnold press",
    targetMuscles: ["delts"],
  },
  "front raise": {
    exerciseId: "3eGE2JC",
    matchedName: "dumbbell front raise",
    targetMuscles: ["delts"],
  },
  "rear delt fly": {
    exerciseId: "8DiFDVA",
    matchedName: "dumbbell rear fly",
    targetMuscles: ["delts"],
  },
  "upright row": {
    exerciseId: "cALKspW",
    matchedName: "cable upright row",
    targetMuscles: ["delts"],
  },
  shrug: {
    exerciseId: "dG7tG5y",
    matchedName: "barbell shrug",
    targetMuscles: ["traps"],
  },
  "preacher curl": {
    exerciseId: "b6hQYMb",
    matchedName: "lever preacher curl",
    targetMuscles: ["biceps"],
  },
  "concentration curl": {
    exerciseId: "gvsWLQw",
    matchedName: "dumbbell concentration curl",
    targetMuscles: ["biceps"],
  },
  "overhead tricep extension": {
    exerciseId: "5uFK1xr",
    matchedName: "barbell seated overhead triceps extension",
    targetMuscles: ["triceps"],
  },
  "tricep dip": {
    exerciseId: "7aVz15j",
    matchedName: "triceps dips floor",
    targetMuscles: ["triceps"],
  },
  "close grip push up": {
    exerciseId: "x6KpKpq",
    matchedName: "close-grip push-up",
    targetMuscles: ["triceps"],
  },
  "goblet squat": {
    exerciseId: "yn8yg1r",
    matchedName: "dumbbell goblet squat",
    targetMuscles: ["quads"],
  },
  "good morning": {
    exerciseId: "XlZ4lAC",
    matchedName: "barbell good morning",
    targetMuscles: ["hamstrings"],
  },
  "hack squat": {
    exerciseId: "Qa55kX1",
    matchedName: "sled hack squat",
    targetMuscles: ["glutes"],
  },
  "sumo deadlift": {
    exerciseId: "KgI0tqW",
    matchedName: "barbell sumo deadlift",
    targetMuscles: ["glutes"],
  },
  "step up": {
    exerciseId: "aXtJhlg",
    matchedName: "dumbbell step-up",
    targetMuscles: ["glutes"],
  },
  "sit up": {
    exerciseId: "6ZCiYWQ",
    matchedName: "sit-up with arms on chest",
    targetMuscles: ["abs"],
  },
  "decline crunch": {
    exerciseId: "9Ap7miY",
    matchedName: "decline crunch",
    targetMuscles: ["abs"],
  },
  "russian twist": {
    exerciseId: "XVDdcoj",
    matchedName: "russian twist",
    targetMuscles: ["abs"],
  },
  "hanging knee raise": {
    exerciseId: "03lzqwk",
    matchedName: "assisted hanging knee raise",
    targetMuscles: ["abs"],
  },
  "dead bug": {
    exerciseId: "iny3m5y",
    matchedName: "dead bug",
    targetMuscles: ["abs"],
  },
  "jump rope": {
    exerciseId: "e1e76I2",
    matchedName: "jump rope",
    targetMuscles: ["cardiovascular system"],
  },
  burpee: {
    exerciseId: "dK9394r",
    matchedName: "burpee",
    targetMuscles: ["cardiovascular system"],
  },
  elliptical: {
    exerciseId: "rjtuP6X",
    matchedName: "walk elliptical cross trainer",
    targetMuscles: ["cardiovascular system"],
  },

  // Candidate only — NOT in ExerciseLibrary until GIF is manually approved.
  // Closest ExerciseDB match for "Bulgarian Split Squat".
  "bulgarian split squat": {
    exerciseId: "qx4fgX7",
    matchedName: "dumbbell single leg split squat",
    targetMuscles: ["quads"],
  },
};

/**
 * @param {string} normalizedName
 * @returns {{ exerciseId: string, matchedName: string, targetMuscles: string[] }|null}
 */
function lookupExerciseMediaOverride(normalizedName) {
  const hit = EXERCISE_MEDIA_OVERRIDES[normalizedName];
  if (!hit || typeof hit.exerciseId !== "string" || !hit.exerciseId.trim()) {
    return null;
  }
  return {
    exerciseId: hit.exerciseId.trim(),
    matchedName: String(hit.matchedName || hit.exerciseId),
    targetMuscles: Array.isArray(hit.targetMuscles)
      ? hit.targetMuscles.map(String)
      : [],
  };
}

/**
 * Normalize an exercise name for cache keys and matching.
 * @param {unknown} name
 * @returns {string}
 */
function normalizeExerciseName(name) {
  return String(name || "")
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9\s]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Firestore-safe document id from a normalized name.
 * @param {string} normalized
 * @returns {string}
 */
function cacheDocId(normalized) {
  return normalized.replace(/\s+/g, "_");
}

/**
 * @param {string} normalized
 * @returns {string[]}
 */
function tokensOf(normalized) {
  return normalized.split(" ").filter(Boolean);
}

/**
 * Score how well a candidate name matches the query.
 * Higher is better; exact match wins. Returns -1 when the match is too weak.
 *
 * Rules:
 * 1. Exact normalized equality → 1000
 * 2. Candidate contains the full query as a contiguous phrase → 700–800
 * 3. Otherwise every query token must appear as an exact token in the candidate
 *    (100% coverage). Partial overlap like face+pull vs rack+pull is rejected.
 * 4. Query-contains-candidate is only allowed when the candidate is nearly as
 *    long as the query (avoids matching "press" into everything).
 *
 * @param {string} queryNormalized
 * @param {string} candidateName
 * @returns {number}
 */
function scoreNameMatch(queryNormalized, candidateName) {
  const candidate = normalizeExerciseName(candidateName);
  if (!queryNormalized || !candidate) return -1;
  if (queryNormalized === candidate) return 1000;

  const qTokens = tokensOf(queryNormalized);
  const cTokens = tokensOf(candidate);
  if (qTokens.length === 0 || cTokens.length === 0) return -1;

  // Contiguous phrase containment: "face pull" in "cable face pull".
  if (candidate.includes(queryNormalized)) {
    const lengthPenalty = Math.min(
      100,
      Math.abs(candidate.length - queryNormalized.length) * 2
    );
    return 800 - lengthPenalty;
  }

  // Rare: query contains a long candidate ("barbell bench press" contains
  // "bench press" only via the reverse path above). Avoid short-candidate traps.
  if (
    queryNormalized.includes(candidate) &&
    candidate.length >= Math.ceil(queryNormalized.length * 0.75)
  ) {
    return 650;
  }

  // Strict token overlap: ALL query tokens must appear as exact candidate tokens.
  const cSet = new Set(cTokens);
  const missing = qTokens.filter((t) => !cSet.has(t));
  if (missing.length > 0) return -1;

  // Prefer candidates that aren't overloaded with extra noise tokens.
  const extra = cTokens.length - qTokens.length;
  const lengthPenalty = Math.min(120, Math.abs(candidate.length - queryNormalized.length));
  return 600 - extra * 25 - lengthPenalty;
}

/**
 * True when a cached matchedName is too dissimilar from the query to trust.
 * Used for self-heal on read and for one-time cache purge.
 * @param {string} queryName
 * @param {string|null|undefined} matchedName
 * @returns {boolean}
 */
function isWeakOrMismatchedCache(queryName, matchedName) {
  const query = normalizeExerciseName(queryName);
  if (!query) return true;
  if (!matchedName || typeof matchedName !== "string") return true;
  return scoreNameMatch(query, matchedName) < MIN_REASONABLE_SCORE;
}

/**
 * Pick the best match from API results.
 * @param {string} queryNormalized
 * @param {Array<object>} exercises
 * @returns {object|null}
 */
function pickBestMatch(queryNormalized, exercises) {
  if (!Array.isArray(exercises) || exercises.length === 0) return null;

  let best = null;
  let bestScore = -1;
  for (const exercise of exercises) {
    const score = scoreNameMatch(queryNormalized, exercise && exercise.name);
    if (score > bestScore) {
      bestScore = score;
      best = exercise;
    }
  }

  if (!best || bestScore < MIN_REASONABLE_SCORE) return null;
  return { exercise: best, score: bestScore };
}

/**
 * Build a stable gif URL from an exercise payload.
 * @param {object} exercise
 * @returns {string|null}
 */
function gifUrlForExercise(exercise) {
  if (!exercise) return null;
  if (typeof exercise.gifUrl === "string" && exercise.gifUrl.startsWith("http")) {
    return exercise.gifUrl;
  }
  const id = exercise.exerciseId;
  if (typeof id === "string" && id.trim()) {
    return `${STATIC_GIF_BASE}/${id.trim()}.gif`;
  }
  return null;
}

/**
 * Default ExerciseDB fetch — injectable in tests.
 * @param {string} nameQuery
 * @returns {Promise<object[]>}
 */
async function defaultFetchExercisesByName(nameQuery) {
  const url = new URL(EXERCISEDB_BASE);
  url.searchParams.set("name", nameQuery);
  url.searchParams.set("limit", "25");

  const response = await fetch(url.toString(), {
    method: "GET",
    headers: { Accept: "application/json" },
  });

  if (!response.ok) {
    throw new HttpsError(
      "unavailable",
      `ExerciseDB request failed (${response.status}).`
    );
  }

  const payload = await response.json();
  return Array.isArray(payload && payload.data) ? payload.data : [];
}

/**
 * Resolve media for an exercise name (cache → API → cache write).
 *
 * @param {string} exerciseName
 * @param {object} [deps]
 * @param {FirebaseFirestore.Firestore} [deps.db]
 * @param {(name: string) => Promise<object[]>} [deps.fetchExercisesByName]
 * @returns {Promise<{
 *   status: "found"|"not_found",
 *   gifUrl: string|null,
 *   matchedName: string|null,
 *   targetMuscles: string[],
 *   cached: boolean,
 *   normalizedName: string
 * }>}
 */
async function resolveExerciseMediaForName(exerciseName, deps = {}) {
  const normalizedName = normalizeExerciseName(exerciseName);
  if (!normalizedName) {
    throw new HttpsError("invalid-argument", "exerciseName is required.");
  }

  const db = deps.db || getFirestore();
  const fetchExercisesByName =
    deps.fetchExercisesByName || defaultFetchExercisesByName;

  const docRef = db.collection(CACHE_COLLECTION).doc(cacheDocId(normalizedName));

  // 1) Manual override wins over cache + fuzzy search (fixes bad historical cache).
  const override = lookupExerciseMediaOverride(normalizedName);
  if (override) {
    const gifUrl = `${STATIC_GIF_BASE}/${override.exerciseId}.gif`;
    await docRef.set({
      status: "found",
      queryName: normalizedName,
      gifUrl,
      matchedName: override.matchedName,
      targetMuscles: override.targetMuscles,
      exerciseId: override.exerciseId,
      matchScore: 10000,
      matchSource: "override",
      updatedAt: FieldValue.serverTimestamp(),
    });
    return {
      status: "found",
      gifUrl,
      matchedName: override.matchedName,
      targetMuscles: override.targetMuscles,
      cached: false,
      normalizedName,
      matchSource: "override",
      exerciseId: override.exerciseId,
    };
  }

  const existing = await docRef.get();

  if (existing.exists) {
    const data = existing.data() || {};
    if (data.status === "not_found") {
      return {
        status: "not_found",
        gifUrl: null,
        matchedName: null,
        targetMuscles: [],
        cached: true,
        normalizedName,
      };
    }

    // Self-heal: purge weak historical matches (e.g. face pull → rack pull).
    // Skip when the cache was written from a manual override.
    if (
      data.matchSource !== "override" &&
      isWeakOrMismatchedCache(normalizedName, data.matchedName)
    ) {
      await docRef.delete().catch(() => {});
    } else {
      return {
        status: "found",
        gifUrl: typeof data.gifUrl === "string" ? data.gifUrl : null,
        matchedName:
          typeof data.matchedName === "string" ? data.matchedName : null,
        targetMuscles: Array.isArray(data.targetMuscles)
          ? data.targetMuscles
          : [],
        cached: true,
        normalizedName,
      };
    }
  }

  const results = await fetchExercisesByName(normalizedName);
  const picked = pickBestMatch(normalizedName, results);

  if (!picked) {
    await docRef.set({
      status: "not_found",
      queryName: normalizedName,
      gifUrl: null,
      matchedName: null,
      targetMuscles: [],
      updatedAt: FieldValue.serverTimestamp(),
    });
    return {
      status: "not_found",
      gifUrl: null,
      matchedName: null,
      targetMuscles: [],
      cached: false,
      normalizedName,
    };
  }

  const gifUrl = gifUrlForExercise(picked.exercise);
  const matchedName = String(picked.exercise.name || "");
  const targetMuscles = Array.isArray(picked.exercise.targetMuscles)
    ? picked.exercise.targetMuscles.map(String)
    : [];

  await docRef.set({
    status: "found",
    queryName: normalizedName,
    gifUrl,
    matchedName,
    targetMuscles,
    exerciseId: picked.exercise.exerciseId || null,
    matchScore: picked.score,
    matchSource: "fuzzy",
    updatedAt: FieldValue.serverTimestamp(),
  });

  return {
    status: "found",
    gifUrl,
    matchedName,
    targetMuscles,
    cached: false,
    normalizedName,
    matchSource: "fuzzy",
  };
}

/**
 * One-time / ops helper: delete or rewrite cache docs whose matchedName is
 * too dissimilar from the query (strict scorer).
 *
 * @param {object} [deps]
 * @param {FirebaseFirestore.Firestore} [deps.db]
 * @returns {Promise<{ scanned: number, purged: number, kept: number, purgedIds: string[] }>}
 */
async function cleanupMismatchedExerciseMediaCache(deps = {}) {
  const db = deps.db || getFirestore();
  const snap = await db.collection(CACHE_COLLECTION).get();

  let purged = 0;
  let kept = 0;
  const purgedIds = [];

  for (const doc of snap.docs) {
    const data = doc.data() || {};
    const queryName =
      (typeof data.queryName === "string" && data.queryName) ||
      doc.id.replace(/_/g, " ");

    if (data.status === "not_found") {
      kept += 1;
      continue;
    }

    // Never purge manual overrides (matchedName may score low vs short app names).
    if (
      data.matchSource === "override" ||
      lookupExerciseMediaOverride(normalizeExerciseName(queryName))
    ) {
      kept += 1;
      continue;
    }

    if (isWeakOrMismatchedCache(queryName, data.matchedName)) {
      await doc.ref.delete();
      purged += 1;
      purgedIds.push(doc.id);
    } else {
      kept += 1;
    }
  }

  return {
    scanned: snap.size,
    purged,
    kept,
    purgedIds,
    mediaLogicVersion: MEDIA_LOGIC_VERSION,
    minReasonableScore: MIN_REASONABLE_SCORE,
  };
}

module.exports = {
  normalizeExerciseName,
  cacheDocId,
  scoreNameMatch,
  pickBestMatch,
  gifUrlForExercise,
  resolveExerciseMediaForName,
  isWeakOrMismatchedCache,
  cleanupMismatchedExerciseMediaCache,
  lookupExerciseMediaOverride,
  EXERCISE_MEDIA_OVERRIDES,
  EXERCISEDB_BASE,
  CACHE_COLLECTION,
  MIN_REASONABLE_SCORE,
  MEDIA_LOGIC_VERSION,
};
