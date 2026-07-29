import SwiftUI

struct ActiveWorkoutSession: Identifiable {
    let id = UUID()
    let routine: WorkoutRoutine
    let logDate: Date
    var startExerciseIndex: Int = 0
}

enum RoutineDisplayName {
    static func short(from name: String) -> String {
        for keyword in ["Push", "Pull", "Legs", "Upper", "Lower", "Full Body"] {
            if name.localizedCaseInsensitiveContains(keyword) { return keyword }
        }
        return name.replacingOccurrences(of: " Day", with: "", options: .caseInsensitive)
    }
}

private enum ActiveSessionColors {
    static let inputBlock = Color(red: 0.102, green: 0.102, blue: 0.102)
    static let logButton = SyncFitTheme.primaryAction
}

struct ActiveWorkoutSessionView: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let session: ActiveWorkoutSession
    let onComplete: (WorkoutSessionResult) -> Void

    @State private var drafts: [RoutineExerciseDraft]
    @State private var exerciseIndex: Int
    @State private var currentReps = 8
    @State private var currentWeight = 135.0
    @State private var sessionStart = Date.now
    @State private var elapsedSeconds = 0
    @State private var didHydrateFromLog = false
    @State private var showingExitConfirm = false
    @State private var editingSetRef: EditableSetRef?
    @State private var restTimerActive = false
    @State private var restSecondsRemaining = 0
    @State private var restShowComplete = false
    @State private var completionSummary: ActiveWorkoutCompletionSummary?
    @State private var sessionTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(session: ActiveWorkoutSession, onComplete: @escaping (WorkoutSessionResult) -> Void) {
        self.session = session
        self.onComplete = onComplete
        _drafts = State(
            initialValue: session.routine.sortedExercises.map {
                RoutineExerciseDraft(exercise: $0.exercise, sets: [])
            }
        )
        _exerciseIndex = State(initialValue: session.startExerciseIndex)
    }

    private var currentDraft: RoutineExerciseDraft {
        drafts[exerciseIndex]
    }

    private var currentRoutineItem: RoutineExerciseItem? {
        let sorted = session.routine.sortedExercises
        guard exerciseIndex < sorted.count else { return nil }
        return sorted[exerciseIndex]
    }

    private var usesBodyweight: Bool {
        currentDraft.exercise.isBodyweight
    }

    private var plannedSetCount: Int {
        currentRoutineItem?.plannedSetCount ?? 0
    }

    private var hasMetPlannedSets: Bool {
        plannedSetCount > 0 && currentDraft.sets.count >= plannedSetCount
    }

    private var isLastExercise: Bool {
        exerciseIndex >= drafts.count - 1
    }

    private var logButtonTitle: String {
        if hasMetPlannedSets {
            return isLastExercise ? "Finish workout" : "Done with exercise"
        }
        return "Log set"
    }

    private var canLogSet: Bool {
        usesBodyweight || currentWeight > 0
    }

    private var currentSetNumber: Int {
        currentDraft.sets.count + 1
    }

    var body: some View {
        ZStack {
            SyncFitTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                sessionTopBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 20)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        exerciseHeader

                        if !currentDraft.sets.isEmpty {
                            completedSetsSection
                                .padding(.top, 16)
                        }

                        Text("SET \(currentSetNumber)")
                            .font(.caption2.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                            .padding(.top, currentDraft.sets.isEmpty ? 24 : 16)

                        currentSetInputs
                            .padding(.top, 12)

                        logSetButton
                            .padding(.top, 16)

                        if restTimerActive {
                            inlineRestTimer
                                .padding(.top, 12)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if !currentDraft.sets.isEmpty {
                            nextExerciseLink
                                .padding(.top, 12)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
            if !didHydrateFromLog {
                hydrateFromLoggedWorkouts()
                didHydrateFromLog = true
            }
            prefillCurrentSetFields()
            elapsedSeconds = 0
        }
        .onReceive(sessionTick) { _ in
            elapsedSeconds = max(0, Int(Date.now.timeIntervalSince(sessionStart)))
            guard restTimerActive, !restShowComplete else { return }
            if restSecondsRemaining > 0 {
                restSecondsRemaining -= 1
            } else {
                restShowComplete = true
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #endif
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        restTimerActive = false
                        restShowComplete = false
                    }
                }
            }
        }
        .confirmationDialog(
            "End workout?",
            isPresented: $showingExitConfirm,
            titleVisibility: .visible
        ) {
            Button("End workout", role: .destructive) { dismiss() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Your progress will be saved.")
        }
        .sheet(item: $editingSetRef) { ref in
            EditLoggedSetSheet(
                set: drafts[exerciseIndex].sets[ref.index],
                usesBodyweight: usesBodyweight
            ) { updated in
                updateSet(at: ref.index, with: updated)
                editingSetRef = nil
            }
        }
        .fullScreenCover(item: $completionSummary) { summary in
            ActiveWorkoutCompletionView(summary: summary) {
                onComplete(summary.result)
                completionSummary = nil
                dismiss()
            }
        }
    }

    // MARK: - Top bar

    private var sessionTopBar: some View {
        HStack(spacing: 12) {
            Button {
                showingExitConfirm = true
            } label: {
                Text("Exit")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color(.tertiarySystemFill))
                    )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            exerciseProgressDots

            Spacer(minLength: 0)

            Text(ActiveSessionFormat.elapsed(elapsedSeconds))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var exerciseProgressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<drafts.count, id: \.self) { index in
                if index < exerciseIndex {
                    Circle()
                        .fill(SyncFitTheme.accentBright)
                        .frame(width: 8, height: 8)
                } else if index == exerciseIndex {
                    Capsule()
                        .fill(SyncFitTheme.accentBright)
                        .frame(width: 18, height: 8)
                } else {
                    Circle()
                        .strokeBorder(Color(.tertiaryLabel).opacity(0.35), lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                }
            }
        }
    }

    // MARK: - Exercise header

    private var exerciseHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EXERCISE \(exerciseIndex + 1) OF \(drafts.count)")
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(SyncFitTheme.accentBright)

            Text(currentDraft.exercise.name)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let summary = dataStore.lastSessionSummary(
                for: currentDraft.exercise.name,
                before: session.logDate
            ) {
                HStack(spacing: 0) {
                    Text(summary.prefix)
                        .foregroundStyle(.secondary)
                    Text(summary.performance)
                        .foregroundStyle(SyncFitTheme.accentBright)
                    Text(summary.suffix)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Completed sets

    private var completedSetsSection: some View {
        VStack(spacing: 6) {
            ForEach(Array(currentDraft.sets.enumerated()), id: \.element.id) { index, set in
                Button {
                    editingSetRef = EditableSetRef(index: index)
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(SyncFitTheme.accentBright.opacity(0.2))
                                .frame(width: 22, height: 22)
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(SyncFitTheme.accentBright)
                        }

                        Text("Set \(index + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(set.weight > 0
                            ? "\(SyncFitFormat.decimal(set.weight)) × \(set.reps)"
                            : "BW × \(set.reps)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(SyncFitTheme.accent.opacity(0.14))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Inputs

    private var currentSetInputs: some View {
        HStack(spacing: 10) {
            if !usesBodyweight {
                ActiveWeightInputBlock(value: $currentWeight)
            }
            ActiveRepsInputBlock(value: $currentReps)
        }
    }

    private var logSetButton: some View {
        Button {
            if hasMetPlannedSets {
                if isLastExercise {
                    finishWorkout()
                } else {
                    advanceExercise()
                }
            } else {
                saveCurrentSet()
            }
        } label: {
            Text(logButtonTitle)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(canLogSet || hasMetPlannedSets ? ActiveSessionColors.logButton : ActiveSessionColors.logButton.opacity(0.45))
                )
        }
        .buttonStyle(.plain)
        .disabled(!hasMetPlannedSets && !canLogSet)
    }

    private var inlineRestTimer: some View {
        HStack(spacing: 10) {
            SpinningRestIndicator()
            Text(restShowComplete
                ? "Rest complete — go!"
                : "Rest · \(ActiveSessionFormat.elapsed(restSecondsRemaining)) remaining")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Skip") {
                withAnimation(.easeOut(duration: 0.2)) {
                    restTimerActive = false
                    restShowComplete = false
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(SyncFitTheme.accentBright)
            .buttonStyle(.plain)
        }
        .frame(height: 40)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(0.55))
        )
    }

    private var nextExerciseLink: some View {
        Button {
            if isLastExercise {
                finishWorkout()
            } else {
                advanceExercise()
            }
        } label: {
            Text(isLastExercise ? "Finish workout →" : "Next exercise →")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func hydrateFromLoggedWorkouts() {
        let logged = dataStore.workouts(on: session.logDate)
        for index in drafts.indices {
            if let entry = logged.first(where: {
                $0.exercise.name.caseInsensitiveCompare(drafts[index].exercise.name) == .orderedSame
            }) {
                drafts[index].sets = entry.sets
                drafts[index].notes = entry.notes
            }
        }

        if session.startExerciseIndex > 0 {
            exerciseIndex = min(session.startExerciseIndex, drafts.count - 1)
        } else if let nextIndex = drafts.firstIndex(where: { $0.sets.isEmpty }) {
            exerciseIndex = nextIndex
        }
    }

    private func prefillCurrentSetFields() {
        if let previous = currentDraft.sets.last {
            currentReps = previous.reps
            currentWeight = previous.weight > 0 ? previous.weight : (usesBodyweight ? 0 : currentWeight)
            return
        }

        if let item = currentRoutineItem {
            currentReps = item.plannedReps
            if let weight = item.plannedWeight {
                currentWeight = weight
            }
            return
        }

        if let entry = dataStore.workouts(on: session.logDate).first(where: {
            $0.exercise.name.caseInsensitiveCompare(currentDraft.exercise.name) == .orderedSame
        }), let planned = entry.plannedSets.first {
            currentReps = planned.reps
            currentWeight = planned.weight
        }
    }

    private func saveCurrentSet() {
        guard canLogSet else { return }
        let weight = usesBodyweight ? 0 : SyncFitFormat.round(currentWeight)
        let set = WorkoutSet(reps: currentReps, weight: weight)

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            drafts[exerciseIndex].sets.append(set)
        }

        dataStore.appendSetToWorkout(
            exercise: drafts[exerciseIndex].exercise,
            set: set,
            on: session.logDate
        )

        prefillCurrentSetFields()
        restSecondsRemaining = appState.restTimerSeconds
        withAnimation(.easeOut(duration: 0.2)) {
            restTimerActive = true
            restShowComplete = false
        }
    }

    private func updateSet(at index: Int, with set: WorkoutSet) {
        guard drafts[exerciseIndex].sets.indices.contains(index) else { return }
        drafts[exerciseIndex].sets[index] = set
        var entry = dataStore.workouts(on: session.logDate).first(where: {
            $0.exercise.name.caseInsensitiveCompare(currentDraft.exercise.name) == .orderedSame
        })
        if var entry {
            entry.sets[index] = set
            dataStore.updateWorkout(entry)
        }
    }

    private func advanceExercise() {
        restTimerActive = false
        restShowComplete = false
        exerciseIndex += 1
        prefillCurrentSetFields()
    }

    private func finishWorkout() {
        dataStore.markWorkoutCompleted(for: session.logDate)
        let durationMinutes = max(Int(Date.now.timeIntervalSince(sessionStart) / 60), 1)
        let base = dataStore.buildSessionResult(for: session.logDate, profile: appState.profile)
        let result = WorkoutSessionResult(
            sessionName: base.sessionName,
            durationMinutes: durationMinutes,
            totalVolumeLbs: dataStore.totalVolumeLbs(in: drafts),
            personalRecords: dataStore.personalRecordsCount(on: session.logDate),
            proteinGoalMet: base.proteinGoalMet,
            estimatedCaloriesBurned: max(durationMinutes * 8, 120)
        )
        completionSummary = ActiveWorkoutCompletionSummary(
            result: result,
            durationSeconds: elapsedSeconds,
            personalRecordDetails: dataStore.personalRecordDetails(on: session.logDate),
            exercisesCompleted: drafts.filter { !$0.sets.isEmpty }.count
        )
    }
}

// MARK: - Formatting

private enum ActiveSessionFormat {
    static func elapsed(_ seconds: Int) -> String {
        let m = max(seconds, 0) / 60
        let s = max(seconds, 0) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Input blocks

private struct ActiveWeightInputBlock: View {
    @Binding var value: Double
    @FocusState private var isFocused: Bool
    @State private var text = ""

    var body: some View {
        inputBlock(
            label: "WEIGHT",
            valueText: SyncFitFormat.decimal(value),
            unit: "lbs"
        ) {
            text = SyncFitFormat.decimal(value)
            isFocused = true
        }
        .background(hiddenWeightField)
    }

    private var hiddenWeightField: some View {
        TextField("", text: $text)
            .keyboardType(.decimalPad)
            .focused($isFocused)
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .onChange(of: text) { _, newValue in
                let cleaned = newValue.replacingOccurrences(of: ",", with: "")
                if let parsed = Double(cleaned) {
                    value = SyncFitFormat.round(min(max(parsed, 0), 1000))
                }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    text = SyncFitFormat.decimal(value)
                }
            }
    }
}

private struct ActiveRepsInputBlock: View {
    @Binding var value: Int
    @FocusState private var isFocused: Bool

    var body: some View {
        inputBlock(
            label: "REPS",
            valueText: "\(value)",
            unit: nil
        ) {
            isFocused = true
        }
        .background(hiddenRepsField)
    }

    private var hiddenRepsField: some View {
        TextField("", value: $value, format: .number)
            .keyboardType(.numberPad)
            .focused($isFocused)
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .onChange(of: value) { _, newValue in
                value = min(max(newValue, 1), 100)
            }
    }
}

@ViewBuilder
private func inputBlock(
    label: String,
    valueText: String,
    unit: String?,
    onTap: @escaping () -> Void
) -> some View {
    Button(action: onTap) {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(valueText)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            Text("tap to edit")
                .font(.caption2)
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ActiveSessionColors.inputBlock)
        )
    }
    .buttonStyle(.plain)
}

// MARK: - Rest indicator

private struct SpinningRestIndicator: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.92)
            .stroke(
                SyncFitTheme.accentBright.opacity(0.25),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .overlay {
                Circle()
                    .trim(from: 0.08, to: 0.35)
                    .stroke(SyncFitTheme.accentBright, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

private struct EditableSetRef: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: - Edit set sheet

private struct EditLoggedSetSheet: View {
    @Environment(\.dismiss) private var dismiss

    let usesBodyweight: Bool
    let onSave: (WorkoutSet) -> Void

    @State private var reps: Int
    @State private var weight: Double

    init(set: WorkoutSet, usesBodyweight: Bool, onSave: @escaping (WorkoutSet) -> Void) {
        self.usesBodyweight = usesBodyweight
        self.onSave = onSave
        _reps = State(initialValue: set.reps)
        _weight = State(initialValue: set.weight)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    if !usesBodyweight {
                        ActiveWeightInputBlock(value: $weight)
                    }
                    ActiveRepsInputBlock(value: $reps)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
            .background(SyncFitTheme.background)
            .navigationTitle("Edit Set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let w = usesBodyweight ? 0 : SyncFitFormat.round(weight)
                        onSave(WorkoutSet(reps: reps, weight: w))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Completion

struct ActiveWorkoutCompletionSummary: Identifiable {
    let id = UUID()
    let result: WorkoutSessionResult
    let durationSeconds: Int
    let personalRecordDetails: [PersonalRecordDetail]
    let exercisesCompleted: Int
}

struct ActiveWorkoutCompletionView: View {
    let summary: ActiveWorkoutCompletionSummary
    let onDone: () -> Void

    var body: some View {
        ZStack {
            SyncFitTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Workout complete")
                        .font(.largeTitle.weight(.bold))

                    VStack(spacing: 16) {
                        statRow(label: "Duration", value: ActiveSessionFormat.elapsed(summary.durationSeconds))
                        statRow(label: "Total volume", value: "\(Int(summary.result.totalVolumeLbs)) lbs")
                        statRow(label: "Exercises", value: "\(summary.exercisesCompleted)")
                    }

                    if !summary.personalRecordDetails.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("PRs hit")
                                .font(.headline)
                            ForEach(summary.personalRecordDetails) { record in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "trophy.fill")
                                        .font(.caption)
                                        .foregroundStyle(SyncFitTheme.accentBright)
                                        .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.exerciseName)
                                            .font(.subheadline.weight(.semibold))
                                        Text(record.detail)
                                            .font(.caption)
                                            .foregroundStyle(SyncFitTheme.accentBright)
                                    }
                                }
                            }
                        }
                    }

                    Button(action: onDone) {
                        Text("Done")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(ActiveSessionColors.logButton)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(24)
            }
        }
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
    }
}

enum WorkoutDurationFormat {
    static func minutes(_ total: Int) -> String {
        guard total > 0 else { return "" }
        if total < 90 { return "\(total) min" }
        let hours = total / 60
        let remainder = total % 60
        if remainder == 0 { return "\(hours)h" }
        return "\(hours)h \(remainder) min"
    }
}

struct WorkoutCompleteSheet: View {
    @Environment(\.dismiss) private var dismiss

    let result: WorkoutSessionResult

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Workout Complete")
                            .font(.largeTitle.weight(.bold))
                        Text(result.sessionName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(SyncFitTheme.accentBright)
                    }

                    VStack(spacing: 14) {
                        statRow(label: "Duration", value: WorkoutDurationFormat.minutes(result.durationMinutes))
                        statRow(label: "Volume", value: "\(Int(result.totalVolumeLbs)) lb")
                        if result.personalRecords > 0 {
                            statRow(label: "Personal Records", value: "\(result.personalRecords)")
                        }
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
                .padding(24)
            }
            .background(SyncFitTheme.background)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
    }
}
