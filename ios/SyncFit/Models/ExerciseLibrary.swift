import Foundation

enum ExerciseLibrary {
    static let muscleGroups = ["Chest", "Back", "Shoulders", "Arms", "Legs", "Core", "Cardio"]

    static let exercises: [Exercise] = [
        // Chest
        Exercise(name: "Bench Press", muscleGroup: "Chest"),
        Exercise(name: "Incline Bench Press", muscleGroup: "Chest"),
        Exercise(name: "Decline Bench Press", muscleGroup: "Chest"),
        Exercise(name: "Dumbbell Bench Press", muscleGroup: "Chest"),
        Exercise(name: "Close-Grip Bench Press", muscleGroup: "Chest"),
        Exercise(name: "Cable Fly", muscleGroup: "Chest"),
        Exercise(name: "Dumbbell Fly", muscleGroup: "Chest"),
        Exercise(name: "Chest Dip", muscleGroup: "Chest"),
        Exercise(name: "Push-Up", muscleGroup: "Chest"),

        // Back
        Exercise(name: "Deadlift", muscleGroup: "Back"),
        Exercise(name: "Barbell Row", muscleGroup: "Back"),
        Exercise(name: "T-Bar Row", muscleGroup: "Back"),
        Exercise(name: "Pull-Up", muscleGroup: "Back"),
        Exercise(name: "Chin-Up", muscleGroup: "Back"),
        Exercise(name: "Lat Pulldown", muscleGroup: "Back"),
        Exercise(name: "Straight-Arm Pulldown", muscleGroup: "Back"),
        Exercise(name: "Seated Cable Row", muscleGroup: "Back"),
        Exercise(name: "Dumbbell Row", muscleGroup: "Back"),
        Exercise(name: "Dumbbell Pullover", muscleGroup: "Back"),
        Exercise(name: "Inverted Row", muscleGroup: "Back"),

        // Shoulders
        Exercise(name: "Overhead Press", muscleGroup: "Shoulders"),
        Exercise(name: "Dumbbell Shoulder Press", muscleGroup: "Shoulders"),
        Exercise(name: "Arnold Press", muscleGroup: "Shoulders"),
        Exercise(name: "Lateral Raise", muscleGroup: "Shoulders"),
        Exercise(name: "Front Raise", muscleGroup: "Shoulders"),
        Exercise(name: "Rear Delt Fly", muscleGroup: "Shoulders"),
        Exercise(name: "Upright Row", muscleGroup: "Shoulders"),
        Exercise(name: "Shrug", muscleGroup: "Shoulders"),
        Exercise(name: "Face Pull", muscleGroup: "Shoulders"),

        // Arms
        Exercise(name: "Barbell Curl", muscleGroup: "Arms"),
        Exercise(name: "Dumbbell Curl", muscleGroup: "Arms"),
        Exercise(name: "Hammer Curl", muscleGroup: "Arms"),
        Exercise(name: "Preacher Curl", muscleGroup: "Arms"),
        Exercise(name: "Concentration Curl", muscleGroup: "Arms"),
        Exercise(name: "Tricep Pushdown", muscleGroup: "Arms"),
        Exercise(name: "Skull Crusher", muscleGroup: "Arms"),
        Exercise(name: "Overhead Tricep Extension", muscleGroup: "Arms"),
        Exercise(name: "Tricep Dip", muscleGroup: "Arms"),
        Exercise(name: "Close-Grip Push-Up", muscleGroup: "Arms"),

        // Legs
        Exercise(name: "Squat", muscleGroup: "Legs"),
        Exercise(name: "Front Squat", muscleGroup: "Legs"),
        Exercise(name: "Goblet Squat", muscleGroup: "Legs"),
        Exercise(name: "Hack Squat", muscleGroup: "Legs"),
        Exercise(name: "Leg Press", muscleGroup: "Legs"),
        Exercise(name: "Romanian Deadlift", muscleGroup: "Legs"),
        Exercise(name: "Sumo Deadlift", muscleGroup: "Legs"),
        Exercise(name: "Good Morning", muscleGroup: "Legs"),
        Exercise(name: "Leg Curl", muscleGroup: "Legs"),
        Exercise(name: "Leg Extension", muscleGroup: "Legs"),
        Exercise(name: "Walking Lunge", muscleGroup: "Legs"),
        Exercise(name: "Step-Up", muscleGroup: "Legs"),
        Exercise(name: "Calf Raise", muscleGroup: "Legs"),

        // Core
        Exercise(name: "Plank", muscleGroup: "Core"),
        Exercise(name: "Sit-Up", muscleGroup: "Core"),
        Exercise(name: "Decline Crunch", muscleGroup: "Core"),
        Exercise(name: "Russian Twist", muscleGroup: "Core"),
        Exercise(name: "Hanging Leg Raise", muscleGroup: "Core"),
        Exercise(name: "Hanging Knee Raise", muscleGroup: "Core"),
        Exercise(name: "Cable Crunch", muscleGroup: "Core"),
        Exercise(name: "Ab Wheel Rollout", muscleGroup: "Core"),
        Exercise(name: "Dead Bug", muscleGroup: "Core"),

        // Cardio
        Exercise(name: "Treadmill Run", muscleGroup: "Cardio"),
        Exercise(name: "Stationary Bike", muscleGroup: "Cardio"),
        Exercise(name: "Rowing Machine", muscleGroup: "Cardio"),
        Exercise(name: "Stair Climber", muscleGroup: "Cardio"),
        Exercise(name: "Elliptical", muscleGroup: "Cardio"),
        Exercise(name: "Jump Rope", muscleGroup: "Cardio"),
        Exercise(name: "Burpee", muscleGroup: "Cardio")
    ]
}
