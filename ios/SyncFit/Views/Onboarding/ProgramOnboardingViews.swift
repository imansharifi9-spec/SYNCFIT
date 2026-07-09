import SwiftUI

// MARK: - Onboarding container

struct ProgramOnboardingFlow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dataStore: FitnessDataStore
    @EnvironmentObject private var firestore: FirestoreDatabaseManager

    enum Step: Hashable {
        case choosePath
        case questions
        case recommendations
        case preview(ProgramTemplate)
        case success(ProgramTemplate)
    }

    @State private var path: [Step] = []
    @State private var trainingDays = 3
    @State private var goal: ProgramGoal = .hypertrophy
    @State private var browseAll = false

    let onFinish: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            choosePathScreen
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .choosePath:
                        choosePathScreen
                    case .questions:
                        questionsScreen
                    case .recommendations:
                        recommendationsScreen
                    case .preview(let template):
                        ProgramTemplatePreviewView(
                            template: template,
                            showsImportButton: true,
                            onImport: { importTemplate(template) }
                        )
                    case .success(let template):
                        ProgramImportSuccessView(template: template, onDone: onFinish)
                    }
                }
        }
        // Rendering choosePath / questions never writes profile or routines.
        // Writes happen only on explicit "Build my own" / import actions below.
    }

    private var choosePathScreen: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 24)

            VStack(spacing: 8) {
                Text("How do you want to start?")
                    .font(.title.weight(.bold))
                Text("Get training in under a minute.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                programPathCard(
                    title: "Start with a program",
                    subtitle: "We'll set up your full weekly schedule in one tap",
                    icon: "calendar.badge.plus"
                ) {
                    path.append(.questions)
                }

                programPathCard(
                    title: "Build my own",
                    subtitle: "Create routines from scratch",
                    icon: "slider.horizontal.3"
                ) {
                    appState.completeProgramSetup(buildYourOwn: true)
                    persistProgramSetupToCloud()
                    onFinish()
                }
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SyncFitTheme.background)
        .navigationBarHidden(true)
    }

    private var questionsScreen: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("How many days can you train?")
                    .font(.title3.weight(.bold))
                ProgramPillRow(
                    options: [2, 3, 4, 5, 6],
                    selection: $trainingDays,
                    label: { "\($0)" }
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What's your main goal?")
                    .font(.title3.weight(.bold))
                ProgramPillRow(
                    options: ProgramGoal.allCases,
                    selection: $goal,
                    label: { $0.displayName }
                )
            }

            Spacer()

            Button {
                browseAll = false
                path.append(.recommendations)
            } label: {
                Text("Continue →")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(red: 0.361, green: 0.859, blue: 0.431))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SyncFitTheme.background)
        .navigationTitle("Quick setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var recommendationsScreen: some View {
        let templates = browseAll
            ? ProgramTemplateLibrary.all
            : ProgramTemplateLibrary.recommended(daysPerWeek: trainingDays, goal: goal)

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(browseAll ? "All programs" : "Recommended for you")
                    .font(.title2.weight(.bold))

                ForEach(templates) { template in
                    ProgramTemplateCard(template: template) {
                        path.append(.preview(template))
                    }
                }

                if !browseAll {
                    Button {
                        browseAll = true
                    } label: {
                        Text("Browse all programs →")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
            }
            .padding(20)
        }
        .background(SyncFitTheme.background)
        .navigationTitle("Programs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func programPathCard(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(SyncFitTheme.accentBright)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }

    private func importTemplate(_ template: ProgramTemplate) {
        dataStore.importProgramTemplate(template, replaceExisting: true)
        persistProgramSetupToCloud()
        appState.selectedTab = .workouts
        path.append(.success(template))
    }

    private func persistProgramSetupToCloud() {
        Task {
            try? await firestore.saveUserProfile(
                appState.profile,
                hasCompletedOnboarding: appState.hasCompletedOnboarding,
                hasCompletedProgramSetup: true,
                workoutScheduleJSON: dataStore.persistedWorkoutScheduleJSON()
            )
        }
    }
}

// MARK: - Shared components

private struct ProgramPillRow<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == option ? .black : .primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(selection == option
                                    ? SyncFitTheme.accentBright
                                    : Color(.tertiarySystemFill))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ProgramTemplateCard: View {
    let template: ProgramTemplate
    let onPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(template.name)
                        .font(.headline)
                    Text(template.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Preview", action: onPreview)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SyncFitTheme.accentBright)
            }

            HStack(spacing: 8) {
                ProgramDifficultyBadge(difficulty: template.difficulty)
                Text("\(template.daysPerWeek) days · ~\(template.averageExercisesPerDay) exercises")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

struct ProgramDifficultyBadge: View {
    let difficulty: ProgramDifficulty

    private var color: Color {
        switch difficulty {
        case .beginner: return SyncFitTheme.accentBright
        case .intermediate: return Color(red: 0.95, green: 0.62, blue: 0.12)
        case .advanced: return Color(red: 0.92, green: 0.38, blue: 0.42)
        }
    }

    var body: some View {
        Text(difficulty.displayName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

// MARK: - Preview

struct ProgramTemplatePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var dataStore: FitnessDataStore

    let template: ProgramTemplate
    var showsImportButton: Bool = true
    var replaceExisting: Bool = true
    var onImport: (() -> Void)?

    @State private var expandedDays: Set<Int> = []
    @State private var showingReplaceConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(template.name)
                            .font(.title.weight(.bold))
                        Text(template.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ProgramDifficultyBadge(difficulty: template.difficulty)
                            Text("\(template.daysPerWeek) days/week")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(spacing: 8) {
                        ForEach(orderedWeekdays(), id: \.self) { weekday in
                            if let day = template.days.first(where: { $0.weekday == weekday }) {
                                dayRow(day)
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, showsImportButton ? 80 : 24)
            }

            if showsImportButton {
                Button(action: startImport) {
                    Text("Start this program")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(red: 0.361, green: 0.859, blue: 0.431))
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
        .background(SyncFitTheme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back") { dismiss() }
            }
        }
        .alert("Replace current schedule?", isPresented: $showingReplaceConfirm) {
            Button("Replace", role: .destructive) { performImport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will replace your current schedule. Your workout history is kept.")
        }
    }

    private func orderedWeekdays() -> [Int] {
        [2, 3, 4, 5, 6, 7, 1]
    }

    @ViewBuilder
    private func dayRow(_ day: ProgramTemplateDaySpec) -> some View {
        let label = WorkoutScheduleFormatters.weekdayName(for: weekdayDate(day.weekday))
        let isExpanded = expandedDays.contains(day.weekday)

        if day.isRest {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Rest")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemFill).opacity(0.5))
            )
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { isExpanded },
                    set: { expanded in
                        if expanded { expandedDays.insert(day.weekday) }
                        else { expandedDays.remove(day.weekday) }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(day.exercises, id: \.self) { exercise in
                        Text("\(exercise.name) — \(exercise.setCount)×\(exercise.reps)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(label) · \(day.routineName)")
                        .font(.subheadline.weight(.semibold))
                    Text("\(day.exercises.count) exercises")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    private func weekdayDate(_ weekday: Int) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let todayWeekday = calendar.component(.weekday, from: today)
        let delta = (weekday - todayWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: delta, to: today) ?? today
    }

    private func startImport() {
        if !dataStore.routines.isEmpty || !dataStore.weekSchedule.days.allSatisfy({ $0.kind == .unassigned }) {
            showingReplaceConfirm = true
        } else {
            performImport()
        }
    }

    private func performImport() {
        if let onImport {
            onImport()
        } else {
            dataStore.importProgramTemplate(template, replaceExisting: replaceExisting)
            dismiss()
        }
    }
}

// MARK: - Success

struct ProgramImportSuccessView: View {
    let template: ProgramTemplate
    let onDone: () -> Void

    @State private var showCheck = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(SyncFitTheme.accentBright)
                .scaleEffect(showCheck ? 1 : 0.5)
                .opacity(showCheck ? 1 : 0)

            VStack(spacing: 10) {
                Text("You're all set")
                    .font(.title.weight(.bold))
                Text("Your \(template.name) program starts \(startDayLabel).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            Button(action: onDone) {
                Text("Go to workout")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(red: 0.361, green: 0.859, blue: 0.431))
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SyncFitTheme.background)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                showCheck = true
            }
        }
    }

    private var startDayLabel: String {
        if dataStoreHasTodayWorkout() { return "today" }
        return "Monday"
    }

    private func dataStoreHasTodayWorkout() -> Bool {
        let assignment = Calendar.current.component(.weekday, from: .now)
        return template.days.contains { $0.weekday == assignment && !$0.isRest }
    }
}

// MARK: - Browser (Schedule)

struct ProgramTemplateBrowserView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text("Import a program to create routines and fill your weekly schedule.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("All programs") {
                ForEach(ProgramTemplateLibrary.all) { template in
                    NavigationLink {
                        ProgramTemplatePreviewView(template: template)
                    } label: {
                        ProgramTemplateListRow(template: template)
                    }
                }
            }
        }
        .navigationTitle("Programs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

private struct ProgramTemplateListRow: View {
    let template: ProgramTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(template.name)
                    .font(.headline)
                Spacer()
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SyncFitTheme.accentBright)
            }
            Text(template.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                ProgramDifficultyBadge(difficulty: template.difficulty)
                Text("\(template.daysPerWeek) days · ~\(template.averageExercisesPerDay) exercises")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
