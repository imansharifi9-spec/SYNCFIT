import SwiftUI

enum MuscleGroupArt {
    static func assetName(for muscleGroup: String) -> String? {
        switch muscleGroup {
        case "Arms", "Biceps", "Triceps": return "muscle_arms"
        case "Back": return "muscle_back"
        case "Chest": return "muscle_chest"
        case "Legs": return "muscle_legs"
        case "Shoulders": return "muscle_shoulders"
        case "Core": return "muscle_core"
        case "Cardio": return "muscle_cardio"
        default: return nil
        }
    }

    static func accentColor(for muscleGroup: String) -> Color {
        switch muscleGroup {
        case "Chest":
            return Color(red: 0.95, green: 0.72, blue: 0.28)       // amber
        case "Shoulders":
            return Color(red: 0.30, green: 0.62, blue: 0.98)       // blue
        case "Triceps":
            return Color(red: 0.62, green: 0.38, blue: 0.95)       // purple
        case "Back":
            return Color(red: 0.25, green: 0.78, blue: 0.75)       // teal
        case "Biceps":
            return Color(red: 0.95, green: 0.40, blue: 0.45)       // pink/red
        case "Legs":
            return Color(red: 0.34, green: 0.78, blue: 0.48)       // green
        case "Core":
            return Color(red: 0.55, green: 0.57, blue: 0.60)       // gray
        case "Cardio":
            return Color(red: 0.45, green: 0.75, blue: 0.98)
        case "Arms":
            return Color(red: 0.62, green: 0.38, blue: 0.95)
        default:
            return SyncFitTheme.accent
        }
    }

    static func systemIcon(for muscleGroup: String) -> String {
        switch muscleGroup {
        case "Chest": return "figure.strengthtraining.traditional"
        case "Back": return "figure.rowing"
        case "Shoulders": return "figure.arms.open"
        case "Triceps": return "arrow.down.forward.circle.fill"
        case "Biceps": return "dumbbell.fill"
        case "Arms": return "dumbbell.fill"
        case "Legs": return "figure.run"
        case "Core": return "figure.core.training"
        case "Cardio": return "figure.run.circle.fill"
        default: return "figure.mixed.cardio"
        }
    }

    static func primaryGroup(for muscleGroup: String, exerciseName: String) -> String {
        Exercise.resolvePrimaryMuscleGroup(name: exerciseName, catalogGroup: muscleGroup)
    }
}

struct ExerciseIllustrationView: View {
    let exerciseName: String
    let muscleGroup: String
    var style: Style = .card

    private var iconMuscleGroup: String {
        MuscleGroupArt.primaryGroup(for: muscleGroup, exerciseName: exerciseName)
    }

    enum Style {
        case card
        case thumbnail
        case inline
    }

    private var cornerRadius: CGFloat {
        switch style {
        case .card: return 14
        case .thumbnail, .inline: return 10
        }
    }

    private var height: CGFloat {
        switch style {
        case .card: return 148
        case .thumbnail: return 52
        case .inline: return 64
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MuscleGroupIllustrationView(
                muscleGroup: iconMuscleGroup,
                exerciseName: exerciseName,
                compact: style != .card
            )

            if style == .card, MuscleGroupArt.assetName(for: iconMuscleGroup) == nil {
                muscleBadge
                    .padding(10)
            }
        }
        .frame(maxWidth: style == .card ? .infinity : nil)
        .frame(width: style == .card ? nil : (style == .inline ? 64 : 52), height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(MuscleGroupArt.accentColor(for: iconMuscleGroup).opacity(style == .card ? 0.22 : 0.3), lineWidth: 1)
        }
    }

    private var muscleBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(MuscleGroupArt.accentColor(for: iconMuscleGroup))
                .frame(width: 8, height: 8)
            Text(iconMuscleGroup)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55))
        .clipShape(Capsule())
    }
}

struct MuscleGroupIconBadge: View {
    let muscleGroup: String
    var size: CGFloat = 44

    private var accent: Color { MuscleGroupArt.accentColor(for: muscleGroup) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.18))
            Image(systemName: MuscleGroupArt.systemIcon(for: muscleGroup))
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(accent)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accent.opacity(0.35), lineWidth: 1)
        }
    }
}

struct MuscleGroupIllustrationView: View {
    let muscleGroup: String
    var exerciseName: String = ""
    var compact: Bool = false

    private var resolvedGroup: String {
        guard !exerciseName.isEmpty else { return muscleGroup }
        return MuscleGroupArt.primaryGroup(for: muscleGroup, exerciseName: exerciseName)
    }

    var body: some View {
        ZStack {
            if compact {
                MuscleGroupIconBadge(muscleGroup: resolvedGroup)
            } else if let assetName = MuscleGroupArt.assetName(for: resolvedGroup) {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fallbackIllustration
            }
        }
        .clipped()
    }

    private var fallbackIllustration: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.13, blue: 0.15),
                    Color(red: 0.08, green: 0.09, blue: 0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if compact {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(MuscleGroupArt.accentColor(for: resolvedGroup).opacity(0.9))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: iconName)
                        .font(.system(size: 52, weight: .regular))
                        .foregroundStyle(MuscleGroupArt.accentColor(for: resolvedGroup).opacity(0.9))
                        .shadow(color: MuscleGroupArt.accentColor(for: resolvedGroup).opacity(0.35), radius: 12)

                    Text("Targets \(resolvedGroup)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
        }
    }

    private var iconName: String {
        MuscleGroupArt.systemIcon(for: resolvedGroup)
    }
}

#Preview {
    VStack(spacing: 16) {
        ExerciseIllustrationView(exerciseName: "Lateral Raise", muscleGroup: "Shoulders")
        ExerciseIllustrationView(exerciseName: "Bench Press", muscleGroup: "Chest")
        ExerciseIllustrationView(exerciseName: "Plank", muscleGroup: "Core")
        ExerciseIllustrationView(exerciseName: "Squat", muscleGroup: "Legs", style: .thumbnail)
            .frame(width: 52)
        SelectedExerciseCard(
            exercise: Exercise(name: "Dumbbell Curl", muscleGroup: "Arms"),
            pulse: false,
            onChange: {}
        )
    }
    .padding()
    .background(SyncFitTheme.background)
}

struct ExerciseSearchRow: View {
    let exercise: Exercise
    let isSelected: Bool
    let onTap: () -> Void

    private var accent: Color { SyncFitTheme.accentBright }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ExerciseThumbnailView(
                    exerciseName: exercise.name,
                    muscleGroup: exercise.muscleGroup
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(exercise.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(exercise.muscleGroup)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.72) : .secondary)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(accent)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(0.95)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.22) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accent)
                        .frame(width: 4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: isSelected)
    }
}

struct SelectedExerciseCard: View {
    let exercise: Exercise
    let pulse: Bool
    var showChangeButton = true
    var showSelectedBadge = true
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ExerciseIllustrationView(
                exerciseName: exercise.name,
                muscleGroup: exercise.muscleGroup,
                style: .inline
            )

            VStack(alignment: .leading, spacing: 4) {
                if showSelectedBadge {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(SyncFitTheme.accent)
                            .scaleEffect(pulse ? 1.2 : 1)
                            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: pulse)
                        Text("Selected")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SyncFitTheme.accent)
                    }
                }
                Text(exercise.name)
                    .font(.headline)
                Text(exercise.muscleGroup)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if showChangeButton {
                Button("Change", action: onChange)
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(SyncFitTheme.accent.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(SyncFitTheme.accent.opacity(0.45), lineWidth: 1.5)
        )
        .transition(.asymmetric(
            insertion: .scale(scale: 0.96).combined(with: .opacity),
            removal: .opacity
        ))
    }
}
