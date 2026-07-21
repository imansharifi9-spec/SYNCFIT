/**
 * Loads recent workout + nutrition logs from Firestore for AI context.
 *
 * IMPORTANT: users/{uid}/workouts/{id} stores ONE DOCUMENT PER EXERCISE, not per
 * session. Session counts must use groupWorkoutSessions() (calendar day + optional
 * session label) — matching CoachClientDataView / ProgressAnalytics day grouping.
 */

const { getFirestore, Timestamp } = require("firebase-admin/firestore");

const LOOKBACK_DAYS = 30;
const MAX_DOCS = 200;

/**
 * @param {FirebaseFirestore.Timestamp|Date|string|number|undefined|null} value
 * @returns {string|null}
 */
function toIso(value) {
  if (value == null) return null;
  if (typeof value.toDate === "function") {
    return value.toDate().toISOString();
  }
  if (value instanceof Date) return value.toISOString();
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/**
 * Calendar day key in local-ish ISO date form (YYYY-MM-DD) from an ISO timestamp.
 * Mirrors Calendar.startOfDay grouping used in CoachClientDataView.workoutSessions.
 * @param {string|null} iso
 * @returns {string|null}
 */
function dayKeyFromIso(iso) {
  if (!iso || typeof iso !== "string") return null;
  // Prefer the calendar date portion; workout docs are day-scoped in SyncFit.
  const m = iso.match(/^(\d{4}-\d{2}-\d{2})/);
  return m ? m[1] : null;
}

/**
 * Group per-exercise workout docs into distinct workout sessions.
 * Key = date (YYYY-MM-DD) + optional sessionLabel/sessionName when present on docs
 * (same spirit as FitnessDataStore session labels: one session identity per day,
 * with an explicit label when available).
 *
 * Only entries with at least one logged set count as a real session (matches
 * workoutGoalMet / ProgressAnalytics consistency).
 *
 * @param {Array<object>} exerciseEntries
 * @returns {{
 *   sessions: Array<object>,
 *   workoutSessionCount: number,
 *   exerciseEntryCount: number,
 *   uniqueExercises: string[],
 *   muscleGroupSessionFrequency: Record<string, number>
 * }}
 */
function groupWorkoutSessions(exerciseEntries) {
  const entries = Array.isArray(exerciseEntries) ? exerciseEntries : [];
  const bySession = new Map();

  for (const entry of entries) {
    const day = dayKeyFromIso(entry.date);
    if (!day) continue;
    const labelRaw =
      (typeof entry.sessionLabel === "string" && entry.sessionLabel.trim()) ||
      (typeof entry.sessionName === "string" && entry.sessionName.trim()) ||
      "";
    const label = labelRaw || "";
    const key = `${day}|${label.toLowerCase()}`;

    if (!bySession.has(key)) {
      bySession.set(key, {
        date: day,
        sessionLabel: label || null,
        exercises: [],
      });
    }
    bySession.get(key).exercises.push(entry);
  }

  const sessions = [];
  const muscleGroupSessionFrequency = {};
  const uniqueExerciseSet = new Set();

  for (const session of bySession.values()) {
    const logged = session.exercises.filter(
      (e) => Array.isArray(e.sets) && e.sets.length > 0
    );
    // Prefer logged exercises; if a day only has planned (empty) rows, skip —
    // mirrors ProgressAnalytics workoutHit = dayWorkouts.contains { !$0.sets.isEmpty }.
    if (logged.length === 0) continue;

    const muscleGroups = [
      ...new Set(logged.map((e) => e.muscleGroup).filter(Boolean)),
    ];
    for (const group of muscleGroups) {
      muscleGroupSessionFrequency[group] =
        (muscleGroupSessionFrequency[group] || 0) + 1;
    }
    for (const e of logged) {
      if (e.exerciseName) uniqueExerciseSet.add(e.exerciseName);
    }

    sessions.push({
      date: session.date,
      sessionLabel: session.sessionLabel,
      exerciseCount: logged.length,
      muscleGroups,
      exercises: logged.map((e) => ({
        id: e.id,
        exerciseName: e.exerciseName,
        muscleGroup: e.muscleGroup,
        notes: e.notes || "",
        sets: e.sets,
      })),
    });
  }

  sessions.sort((a, b) => {
    if (a.date === b.date) {
      return String(b.sessionLabel || "").localeCompare(String(a.sessionLabel || ""));
    }
    return a.date < b.date ? 1 : -1;
  });

  return {
    sessions,
    workoutSessionCount: sessions.length,
    exerciseEntryCount: entries.length,
    uniqueExercises: [...uniqueExerciseSet],
    muscleGroupSessionFrequency,
  };
}

/**
 * Map a Firestore workout doc into a flat exercise entry (pre-session-group).
 * @param {FirebaseFirestore.QueryDocumentSnapshot} doc
 */
function mapWorkoutDoc(doc) {
  const d = doc.data() || {};
  return {
    id: d.id || doc.id,
    date: toIso(d.date),
    exerciseName: d.exerciseName || "",
    muscleGroup: d.muscleGroup || "",
    notes: d.notes || "",
    sessionLabel:
      (typeof d.sessionLabel === "string" && d.sessionLabel) ||
      (typeof d.sessionName === "string" && d.sessionName) ||
      null,
    sets: Array.isArray(d.sets)
      ? d.sets.map((s) => ({
          reps: s.reps,
          weight: s.weight,
          rpe: s.rpe ?? null,
        }))
      : [],
  };
}

/**
 * @param {ReturnType<typeof groupWorkoutSessions>} grouped
 */
function workoutSummaryFields(grouped) {
  return {
    // Distinct sessions (date + session label) — USE THIS for "workouts logged".
    workoutSessionCount: grouped.workoutSessionCount,
    // Deprecated alias kept only so older prompts don't invent numbers from length.
    // Intentionally equal to workoutSessionCount, NOT raw docs.
    workoutCount: grouped.workoutSessionCount,
    exerciseEntryCount: grouped.exerciseEntryCount,
    uniqueExercises: grouped.uniqueExercises,
    // Muscle group tallies = number of distinct sessions that hit that group.
    muscleGroupSessionFrequency: grouped.muscleGroupSessionFrequency,
    // Back-compat name; same session-based meaning as muscleGroupSessionFrequency.
    muscleGroupFrequency: grouped.muscleGroupSessionFrequency,
    recentSessions: grouped.sessions.slice(0, 30),
    // Compact exercise sample for programming detail (still per-exercise docs).
    recentWorkouts: grouped.sessions
      .flatMap((s) =>
        s.exercises.map((e) => ({
          ...e,
          date: s.date,
          sessionLabel: s.sessionLabel,
        }))
      )
      .slice(0, 60),
  };
}

/**
 * @param {string} uid
 * @param {object} [options]
 * @param {FirebaseFirestore.Firestore} [options.db]
 * @param {Date} [options.now]
 * @param {number} [options.lookbackDays]
 * @returns {Promise<object>}
 */
async function loadUserTrainingContext(
  uid,
  { db = getFirestore(), now = new Date(), lookbackDays = LOOKBACK_DAYS } = {}
) {
  const cutoff = new Date(now.getTime() - lookbackDays * 24 * 60 * 60 * 1000);
  const cutoffTs = Timestamp.fromDate(cutoff);

  const [workoutSnap, mealSnap, userSnap] = await Promise.all([
    db
      .collection("users")
      .doc(uid)
      .collection("workouts")
      .where("date", ">=", cutoffTs)
      .orderBy("date", "desc")
      .limit(MAX_DOCS)
      .get(),
    db
      .collection("users")
      .doc(uid)
      .collection("meals")
      .where("date", ">=", cutoffTs)
      .orderBy("date", "desc")
      .limit(MAX_DOCS)
      .get(),
    db.collection("users").doc(uid).get(),
  ]);

  const profile = userSnap.exists ? userSnap.data() || {} : {};
  const exerciseEntries = workoutSnap.docs.map(mapWorkoutDoc);
  const grouped = groupWorkoutSessions(exerciseEntries);

  const meals = mealSnap.docs.map((doc) => {
    const d = doc.data() || {};
    return {
      id: d.id || doc.id,
      date: toIso(d.date),
      name: d.name || "",
      meal: d.meal || "",
      calories: d.calories ?? 0,
      protein: d.protein ?? 0,
      carbs: d.carbs ?? 0,
      fat: d.fat ?? 0,
    };
  });

  const totalCalories = meals.reduce((sum, m) => sum + (Number(m.calories) || 0), 0);
  const totalProtein = meals.reduce((sum, m) => sum + (Number(m.protein) || 0), 0);

  return {
    lookbackDays,
    cutoffIso: cutoff.toISOString(),
    profileHints: {
      profileName: profile.profileName || null,
      goalRaw: profile.goalRaw || null,
      experienceRaw: profile.experienceRaw || null,
      calorieTarget: profile.calorieTarget ?? null,
      proteinTarget: profile.proteinTarget ?? null,
    },
    ...workoutSummaryFields(grouped),
    mealCount: meals.length,
    nutritionTotals: {
      calories: totalCalories,
      protein: totalProtein,
    },
    recentMeals: meals.slice(0, 60),
  };
}

/**
 * Load only the categories a client has shared with a coach.
 * Unshared categories are OMITTED entirely (not empty arrays) so callers /
 * tests can prove data never reaches Claude.
 *
 * @param {string} clientUid
 * @param {{ workouts?: boolean, nutrition?: boolean, progress?: boolean }} permissions
 * @param {object} [options]
 * @returns {Promise<object>}
 */
async function loadSharedClientTrainingContext(
  clientUid,
  permissions,
  { db = getFirestore(), now = new Date(), lookbackDays = LOOKBACK_DAYS } = {}
) {
  const share = {
    workouts: permissions?.workouts === true,
    nutrition: permissions?.nutrition === true,
    progress: permissions?.progress === true,
  };

  const cutoff = new Date(now.getTime() - lookbackDays * 24 * 60 * 60 * 1000);
  const cutoffTs = Timestamp.fromDate(cutoff);
  const userRef = db.collection("users").doc(clientUid);

  const userSnap = await userRef.get();
  const profile = userSnap.exists ? userSnap.data() || {} : {};

  /** @type {object} */
  const summary = {
    lookbackDays,
    cutoffIso: cutoff.toISOString(),
    sharedCategories: { ...share },
    profileHints: {
      profileName: profile.profileName || null,
      goalRaw: profile.goalRaw || null,
      experienceRaw: profile.experienceRaw || null,
      calorieTarget: profile.calorieTarget ?? null,
      proteinTarget: profile.proteinTarget ?? null,
    },
  };

  if (share.workouts) {
    const workoutSnap = await userRef
      .collection("workouts")
      .where("date", ">=", cutoffTs)
      .orderBy("date", "desc")
      .limit(MAX_DOCS)
      .get();

    const exerciseEntries = workoutSnap.docs.map(mapWorkoutDoc);
    const grouped = groupWorkoutSessions(exerciseEntries);
    Object.assign(summary, workoutSummaryFields(grouped));
  }

  if (share.nutrition) {
    const mealSnap = await userRef
      .collection("meals")
      .where("date", ">=", cutoffTs)
      .orderBy("date", "desc")
      .limit(MAX_DOCS)
      .get();

    const meals = mealSnap.docs.map((doc) => {
      const d = doc.data() || {};
      return {
        id: d.id || doc.id,
        date: toIso(d.date),
        name: d.name || "",
        meal: d.meal || "",
        calories: d.calories ?? 0,
        protein: d.protein ?? 0,
        carbs: d.carbs ?? 0,
        fat: d.fat ?? 0,
      };
    });

    summary.mealCount = meals.length;
    summary.nutritionTotals = {
      calories: meals.reduce((sum, m) => sum + (Number(m.calories) || 0), 0),
      protein: meals.reduce((sum, m) => sum + (Number(m.protein) || 0), 0),
    };
    summary.recentMeals = meals.slice(0, 60);
  }

  if (share.progress) {
    const weightSnap = await userRef
      .collection("weights")
      .where("date", ">=", cutoffTs)
      .orderBy("date", "desc")
      .limit(MAX_DOCS)
      .get();

    const weights = weightSnap.docs.map((doc) => {
      const d = doc.data() || {};
      return {
        id: d.id || doc.id,
        date: toIso(d.date),
        weight: d.weight ?? d.value ?? null,
        unit: d.unit || null,
        notes: d.notes || "",
      };
    });

    summary.weightCount = weights.length;
    summary.recentWeights = weights.slice(0, 60);
  }

  return summary;
}

module.exports = {
  LOOKBACK_DAYS,
  dayKeyFromIso,
  groupWorkoutSessions,
  loadUserTrainingContext,
  loadSharedClientTrainingContext,
};
