import Foundation

enum ProgramDifficulty: String, CaseIterable, Codable {
    case beginner
    case intermediate
    case advanced

    var displayName: String {
        rawValue.capitalized
    }
}

enum ProgramGoal: String, CaseIterable, Codable {
    case hypertrophy
    case strength
    case both

    var displayName: String {
        switch self {
        case .hypertrophy: return "Build muscle"
        case .strength: return "Get stronger"
        case .both: return "Both"
        }
    }
}

struct ProgramTemplateExerciseSpec: Hashable {
    let name: String
    let setCount: Int
    let reps: Int
}

struct ProgramTemplateDaySpec: Hashable {
    let weekday: Int
    let routineName: String
    let exercises: [ProgramTemplateExerciseSpec]
    let isRest: Bool

    init(
        weekday: Int,
        routineName: String,
        exercises: [ProgramTemplateExerciseSpec] = [],
        isRest: Bool = false
    ) {
        self.weekday = weekday
        self.routineName = routineName
        self.exercises = exercises
        self.isRest = isRest
    }
}

struct ProgramTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let difficulty: ProgramDifficulty
    let daysPerWeek: Int
    let goal: ProgramGoal
    let days: [ProgramTemplateDaySpec]

    var trainingDays: [ProgramTemplateDaySpec] {
        days.filter { !$0.isRest }
    }

    var averageExercisesPerDay: Int {
        let counts = trainingDays.map(\.exercises.count)
        guard !counts.isEmpty else { return 0 }
        return counts.reduce(0, +) / counts.count
    }

    func uniqueRoutineDays() -> [(name: String, exercises: [ProgramTemplateExerciseSpec])] {
        var seen = Set<String>()
        var result: [(String, [ProgramTemplateExerciseSpec])] = []
        for day in trainingDays {
            guard seen.insert(day.routineName).inserted else { continue }
            result.append((day.routineName, day.exercises))
        }
        return result
    }
}

enum ProgramTemplateLibrary {
    private static func ex(_ name: String, _ sets: Int, _ reps: Int) -> ProgramTemplateExerciseSpec {
        ProgramTemplateExerciseSpec(name: name, setCount: sets, reps: reps)
    }

    private static func day(
        _ weekday: Int,
        _ routineName: String,
        _ exercises: [ProgramTemplateExerciseSpec],
        rest: Bool = false
    ) -> ProgramTemplateDaySpec {
        ProgramTemplateDaySpec(weekday: weekday, routineName: routineName, exercises: exercises, isRest: rest)
    }

    static let all: [ProgramTemplate] = [
        pushPullLegs3,
        fullBody3x,
        upperLower4,
        ppl6Day,
        fiveThreeOne,
        hypertrophy5Day,
        powerlifting4Day,
        phul4Day
    ]

    static func resolveExercise(named name: String) -> Exercise {
        let resolved = exerciseAliases[name] ?? name
        if let match = ExerciseLibrary.exercises.first(where: {
            $0.name.caseInsensitiveCompare(resolved) == .orderedSame
        }) {
            return match
        }
        return Exercise(name: resolved, muscleGroup: inferredMuscleGroup(for: resolved))
    }

    static func recommended(daysPerWeek: Int, goal: ProgramGoal) -> [ProgramTemplate] {
        let scored = all.map { template -> (ProgramTemplate, Int) in
            var score = 0
            if template.daysPerWeek == daysPerWeek { score += 12 }
            else if abs(template.daysPerWeek - daysPerWeek) == 1 { score += 6 }
            else if abs(template.daysPerWeek - daysPerWeek) == 2 { score += 2 }

            switch (goal, template.goal) {
            case (.hypertrophy, .hypertrophy): score += 10
            case (.strength, .strength): score += 10
            case (.both, .both): score += 10
            case (.both, _), (_, .both): score += 5
            case (.hypertrophy, .both): score += 4
            case (.strength, .both): score += 4
            default: break
            }

            switch template.difficulty {
            case .beginner where daysPerWeek <= 4: score += 2
            case .intermediate where daysPerWeek >= 4: score += 2
            case .advanced where goal == .strength: score += 3
            default: break
            }
            return (template, score)
        }
        .sorted { $0.1 > $1.1 }

        let top = scored.prefix(3).map(\.0)
        if top.count >= 2 { return Array(top) }
        return Array(all.prefix(3))
    }

    private static let exerciseAliases: [String: String] = [
        "Incline Dumbbell Press": "Incline Bench Press",
        "Dumbbell Press": "Dumbbell Bench Press",
        "Curl": "Barbell Curl",
        "Tricep work": "Tricep Pushdown",
        "OHP": "Overhead Press",
        "Cable Row": "Seated Cable Row"
    ]

    private static func inferredMuscleGroup(for name: String) -> String {
        let primary = Exercise.resolvePrimaryMuscleGroup(name: name, catalogGroup: "Core")
        switch primary {
        case "Triceps", "Biceps":
            return "Arms"
        default:
            return primary
        }
    }

    // MARK: - Programs

    private static let pushDayExercises: [ProgramTemplateExerciseSpec] = [
        ex("Bench Press", 4, 8),
        ex("Overhead Press", 3, 10),
        ex("Incline Dumbbell Press", 3, 10),
        ex("Tricep Pushdown", 3, 12),
        ex("Lateral Raise", 3, 15)
    ]

    private static let pullDayExercises: [ProgramTemplateExerciseSpec] = [
        ex("Barbell Row", 4, 8),
        ex("Lat Pulldown", 3, 10),
        ex("Face Pull", 3, 15),
        ex("Barbell Curl", 3, 12),
        ex("Hammer Curl", 3, 12)
    ]

    private static let legDayExercises: [ProgramTemplateExerciseSpec] = [
        ex("Squat", 4, 8),
        ex("Romanian Deadlift", 3, 10),
        ex("Leg Press", 3, 12),
        ex("Leg Curl", 3, 12),
        ex("Calf Raise", 4, 15)
    ]

    private static let pushPullLegs3 = ProgramTemplate(
        id: "ppl-3",
        name: "Push Pull Legs",
        description: "Classic 3-day split hitting each muscle group once per week.",
        difficulty: .beginner,
        daysPerWeek: 3,
        goal: .hypertrophy,
        days: [
            day(2, "Push", pushDayExercises),
            day(4, "Pull", pullDayExercises),
            day(6, "Legs", legDayExercises)
        ]
    )

    private static let fullBodyDay: [ProgramTemplateExerciseSpec] = [
        ex("Squat", 3, 8),
        ex("Bench Press", 3, 8),
        ex("Barbell Row", 3, 8),
        ex("Overhead Press", 3, 10),
        ex("Romanian Deadlift", 3, 10)
    ]

    private static let fullBody3x = ProgramTemplate(
        id: "full-body-3",
        name: "Full Body 3x",
        description: "Three full-body sessions per week — great for beginners building consistency.",
        difficulty: .beginner,
        daysPerWeek: 3,
        goal: .both,
        days: [
            day(2, "Full Body", fullBodyDay),
            day(4, "Full Body", fullBodyDay),
            day(6, "Full Body", fullBodyDay)
        ]
    )

    private static let upperDay: [ProgramTemplateExerciseSpec] = [
        ex("Bench Press", 4, 8),
        ex("Barbell Row", 4, 8),
        ex("Overhead Press", 3, 10),
        ex("Lat Pulldown", 3, 10),
        ex("Curl", 3, 12)
    ]

    private static let lowerDay: [ProgramTemplateExerciseSpec] = [
        ex("Squat", 4, 8),
        ex("Romanian Deadlift", 3, 10),
        ex("Leg Press", 3, 12),
        ex("Leg Curl", 3, 12),
        ex("Calf Raise", 4, 15)
    ]

    private static let upperLower4 = ProgramTemplate(
        id: "upper-lower-4",
        name: "Upper / Lower",
        description: "Four training days alternating upper and lower body.",
        difficulty: .beginner,
        daysPerWeek: 4,
        goal: .both,
        days: [
            day(2, "Upper", upperDay),
            day(3, "Lower", lowerDay),
            day(5, "Upper", upperDay),
            day(6, "Lower", lowerDay)
        ]
    )

    private static let push6 = pushDayExercises + [ex("Cable Fly", 3, 12)]
    private static let pull6 = pullDayExercises + [ex("Dumbbell Curl", 3, 12)]
    private static let legs6 = legDayExercises + [ex("Leg Extension", 3, 12)]

    private static let ppl6Day = ProgramTemplate(
        id: "ppl-6",
        name: "PPL 6-Day",
        description: "Push, pull, and legs twice per week with extra isolation volume.",
        difficulty: .intermediate,
        daysPerWeek: 6,
        goal: .hypertrophy,
        days: [
            day(2, "Push", push6),
            day(3, "Pull", pull6),
            day(4, "Legs", legs6),
            day(5, "Push", push6),
            day(6, "Pull", pull6),
            day(7, "Legs", legs6)
        ]
    )

    private static let fiveThreeOne = ProgramTemplate(
        id: "531-4",
        name: "5/3/1",
        description: "Four-day strength program centered on squat, bench, deadlift, and press.",
        difficulty: .intermediate,
        daysPerWeek: 4,
        goal: .strength,
        days: [
            day(2, "Squat Day", [
                ex("Squat", 5, 5),
                ex("Front Squat", 5, 8),
                ex("Leg Press", 5, 10)
            ]),
            day(4, "Bench Day", [
                ex("Bench Press", 5, 5),
                ex("Dumbbell Press", 5, 10),
                ex("Tricep Pushdown", 5, 10)
            ]),
            day(6, "Deadlift Day", [
                ex("Deadlift", 5, 5),
                ex("Romanian Deadlift", 5, 8),
                ex("Leg Curl", 5, 10)
            ]),
            day(7, "Overhead Day", [
                ex("Overhead Press", 5, 5),
                ex("Dumbbell Press", 5, 10),
                ex("Lat Pulldown", 5, 10)
            ])
        ]
    )

    private static let hypertrophy5Day = ProgramTemplate(
        id: "hypertrophy-5",
        name: "Hypertrophy",
        description: "Five-day body-part split with higher reps and isolation focus.",
        difficulty: .intermediate,
        daysPerWeek: 5,
        goal: .hypertrophy,
        days: [
            day(2, "Chest", [
                ex("Bench Press", 4, 10), ex("Incline Bench Press", 3, 12),
                ex("Dumbbell Bench Press", 3, 12), ex("Cable Fly", 3, 15),
                ex("Tricep Pushdown", 3, 15), ex("Push-Up", 3, 15),
                ex("Lateral Raise", 3, 15), ex("Skull Crusher", 3, 12)
            ]),
            day(3, "Shoulders", [
                ex("Overhead Press", 4, 10), ex("Dumbbell Shoulder Press", 3, 12),
                ex("Lateral Raise", 4, 15), ex("Face Pull", 3, 15),
                ex("Cable Fly", 3, 15), ex("Tricep Pushdown", 3, 15),
                ex("Hammer Curl", 3, 12), ex("Barbell Curl", 3, 12)
            ]),
            day(4, "Legs", [
                ex("Squat", 4, 10), ex("Leg Press", 3, 12), ex("Romanian Deadlift", 3, 12),
                ex("Leg Curl", 3, 12), ex("Leg Extension", 3, 15),
                ex("Walking Lunge", 3, 12), ex("Calf Raise", 4, 15), ex("Front Squat", 3, 10)
            ]),
            day(5, "Back & Biceps", [
                ex("Deadlift", 4, 8), ex("Barbell Row", 4, 10), ex("Lat Pulldown", 3, 12),
                ex("Seated Cable Row", 3, 12), ex("Pull-Up", 3, 10),
                ex("Face Pull", 3, 15), ex("Barbell Curl", 3, 12), ex("Hammer Curl", 3, 12)
            ]),
            day(6, "Arms", [
                ex("Barbell Curl", 4, 12), ex("Hammer Curl", 3, 12), ex("Dumbbell Curl", 3, 12),
                ex("Tricep Pushdown", 4, 12), ex("Skull Crusher", 3, 12),
                ex("Cable Fly", 3, 15), ex("Lateral Raise", 3, 15), ex("Face Pull", 3, 15)
            ])
        ]
    )

    private static let powerlifting4Day = ProgramTemplate(
        id: "powerlifting-4",
        name: "Powerlifting",
        description: "Heavy squat, bench, and deadlift focus with low-rep strength work.",
        difficulty: .advanced,
        daysPerWeek: 4,
        goal: .strength,
        days: [
            day(2, "Squat Focus", [
                ex("Squat", 5, 3), ex("Front Squat", 4, 5),
                ex("Leg Press", 3, 6), ex("Leg Curl", 3, 8)
            ]),
            day(3, "Bench Focus", [
                ex("Bench Press", 5, 3), ex("Incline Bench Press", 4, 5),
                ex("Dumbbell Bench Press", 3, 6), ex("Tricep Pushdown", 3, 8)
            ]),
            day(5, "Deadlift Focus", [
                ex("Deadlift", 5, 3), ex("Romanian Deadlift", 4, 5),
                ex("Barbell Row", 3, 6), ex("Leg Curl", 3, 8)
            ]),
            day(6, "Accessories", [
                ex("Overhead Press", 4, 5), ex("Bench Press", 3, 5),
                ex("Lat Pulldown", 3, 8), ex("Barbell Row", 3, 6)
            ])
        ]
    )

    private static let phul4Day = ProgramTemplate(
        id: "phul-4",
        name: "PHUL",
        description: "Power and hypertrophy upper/lower — heavy days and volume days.",
        difficulty: .advanced,
        daysPerWeek: 4,
        goal: .both,
        days: [
            day(2, "Upper Power", [
                ex("Bench Press", 5, 3), ex("Barbell Row", 5, 3),
                ex("Overhead Press", 4, 5), ex("Pull-Up", 4, 5), ex("Skull Crusher", 3, 8)
            ]),
            day(3, "Lower Power", [
                ex("Squat", 5, 3), ex("Romanian Deadlift", 5, 3),
                ex("Leg Press", 3, 8), ex("Leg Curl", 3, 8), ex("Calf Raise", 4, 8)
            ]),
            day(4, "Rest", [], rest: true),
            day(5, "Upper Hypertrophy", [
                ex("Incline Bench Press", 4, 10), ex("Lat Pulldown", 4, 10),
                ex("Dumbbell Press", 3, 12), ex("Seated Cable Row", 3, 12),
                ex("Curl", 3, 12), ex("Tricep Pushdown", 3, 12)
            ]),
            day(6, "Lower Hypertrophy", [
                ex("Squat", 4, 10), ex("Leg Press", 4, 12), ex("Romanian Deadlift", 3, 12),
                ex("Leg Curl", 3, 12), ex("Leg Extension", 3, 15), ex("Calf Raise", 4, 15)
            ])
        ]
    )
}
