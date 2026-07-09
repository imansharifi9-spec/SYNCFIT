import Foundation

enum ExerciseLibrary {
    static let muscleGroups = ["Chest", "Back", "Shoulders", "Arms", "Legs", "Core", "Cardio"]

    static let exercises: [Exercise] = [
        // Chest
        Exercise(name: "Bench Press", muscleGroup: "Chest"),
        Exercise(name: "Incline Bench Press", muscleGroup: "Chest"),
        Exercise(name: "Dumbbell Bench Press", muscleGroup: "Chest"),
        Exercise(name: "Cable Fly", muscleGroup: "Chest"),
        Exercise(name: "Push-Up", muscleGroup: "Chest"),

        // Back
        Exercise(name: "Deadlift", muscleGroup: "Back"),
        Exercise(name: "Barbell Row", muscleGroup: "Back"),
        Exercise(name: "Pull-Up", muscleGroup: "Back"),
        Exercise(name: "Lat Pulldown", muscleGroup: "Back"),
        Exercise(name: "Seated Cable Row", muscleGroup: "Back"),
        Exercise(name: "Dumbbell Row", muscleGroup: "Back"),

        // Shoulders
        Exercise(name: "Overhead Press", muscleGroup: "Shoulders"),
        Exercise(name: "Dumbbell Shoulder Press", muscleGroup: "Shoulders"),
        Exercise(name: "Lateral Raise", muscleGroup: "Shoulders"),
        Exercise(name: "Face Pull", muscleGroup: "Shoulders"),

        // Arms
        Exercise(name: "Barbell Curl", muscleGroup: "Arms"),
        Exercise(name: "Dumbbell Curl", muscleGroup: "Arms"),
        Exercise(name: "Tricep Pushdown", muscleGroup: "Arms"),
        Exercise(name: "Skull Crusher", muscleGroup: "Arms"),
        Exercise(name: "Hammer Curl", muscleGroup: "Arms"),

        // Legs
        Exercise(name: "Squat", muscleGroup: "Legs"),
        Exercise(name: "Front Squat", muscleGroup: "Legs"),
        Exercise(name: "Leg Press", muscleGroup: "Legs"),
        Exercise(name: "Romanian Deadlift", muscleGroup: "Legs"),
        Exercise(name: "Leg Curl", muscleGroup: "Legs"),
        Exercise(name: "Leg Extension", muscleGroup: "Legs"),
        Exercise(name: "Walking Lunge", muscleGroup: "Legs"),
        Exercise(name: "Calf Raise", muscleGroup: "Legs"),

        // Core
        Exercise(name: "Plank", muscleGroup: "Core"),
        Exercise(name: "Hanging Leg Raise", muscleGroup: "Core"),
        Exercise(name: "Cable Crunch", muscleGroup: "Core"),
        Exercise(name: "Ab Wheel Rollout", muscleGroup: "Core"),

        // Cardio
        Exercise(name: "Treadmill Run", muscleGroup: "Cardio"),
        Exercise(name: "Stationary Bike", muscleGroup: "Cardio"),
        Exercise(name: "Rowing Machine", muscleGroup: "Cardio"),
        Exercise(name: "Stair Climber", muscleGroup: "Cardio")
    ]
}
