import SwiftUI

struct WorkoutView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dataStore: FitnessDataStore
    @EnvironmentObject private var healthKit: HealthKitService
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDate = Date.now
    @State private var showingLogSheet = false
    @State private var editingWorkout: WorkoutEntry?
    @State private var editingRoutine: WorkoutRoutine?
    @State private var showingScheduleSetup = false
    @State private var activeSession: ActiveWorkoutSession?
    @State private var workoutCompleteResult: WorkoutSessionResult?
    @State private var showingPRBreakdown = false

    private var dayWorkouts: [WorkoutEntry] {
        dataStore.workouts(on: selectedDate)
    }

    private var workoutSessionState: WorkoutSessionState {
        dataStore.workoutSessionState(for: selectedDate)
    }

    private var dayTotalVolume: Double {
        dataStore.totalVolume(on: selectedDate)
    }

    private var dayHeroTitle: String {
        dataStore.routineDisplayName(for: selectedDate)
    }

    private var scheduleAccentColor: Color {
        let assignment = dataStore.scheduledAssignment(for: selectedDate)
        return WorkoutScheduleColors.color(for: assignment, routines: dataStore.routines)
    }

    private var showUnassignedDay: Bool {
        dataStore.scheduledAssignment(for: selectedDate).kind == .unassigned
            && dayWorkouts.isEmpty
            && dataStore.activeDayTemplate(for: selectedDate) == nil
    }

    private var dayWeekdayLabel: String {
        WorkoutScheduleFormatters.weekdayName(for: selectedDate).uppercased()
    }

    private var dayDetailLine: String {
        let count = dayWorkouts.count
        if count > 0 {
            return "\(count) \(count == 1 ? "exercise" : "exercises")"
        }
        let plannedCount = dataStore.routineExerciseCount(for: selectedDate)
        if plannedCount > 0 {
            return "\(plannedCount) \(plannedCount == 1 ? "exercise" : "exercises")"
        }
        return "Log any exercises you do today"
    }

    private var dayVolumeLine: String? {
        guard dayTotalVolume > 0 else { return nil }
        return "Total volume: \(dataStore.formattedVolume(dayTotalVolume)) lbs"
    }

    private var showRestDay: Bool {
        dataStore.isRestDay(for: selectedDate)
            && dayWorkouts.isEmpty
            && dataStore.activeDayTemplate(for: selectedDate) == nil
    }

    private var weekProgressLabel: String {
        let week = dataStore.workoutsThisWeekCount()
        let goal = dataStore.weeklyWorkoutGoal()
        return "\(week)/\(goal) this week"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                NutritionWeekStrip(
                    selectedDate: $selectedDate,
                    hasLoggedFood: { dataStore.hasWorkout(on: $0) },
                    scheduleAccentColor: { date in
                        let assignment = dataStore.scheduledAssignment(for: date)
                        guard assignment.kind != .unassigned else { return nil }
                        return WorkoutScheduleColors.color(
                            for: assignment,
                            routines: dataStore.routines
                        )
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, 4)

                Group {
                    if showUnassignedDay {
                        UnassignedDayHeroCard(
                            colorScheme: colorScheme,
                            onOpenSchedule: { showingScheduleSetup = true },
                            onLogAdHoc: { showingLogSheet = true }
                        )
                    } else if showRestDay {
                        RestDayHeroCard(
                            colorScheme: colorScheme,
                            onTrainAnyway: { startWorkout() }
                        )
                    } else {
                        DailyWorkoutHeroCard(
                            weekdayLabel: dayWeekdayLabel,
                            title: dayHeroTitle,
                            detailLine: dayDetailLine,
                            volumeLine: dayVolumeLine,
                            personalRecordsToday: dataStore.personalRecordsCount(on: selectedDate),
                            sessionState: workoutSessionState,
                            accentColor: scheduleAccentColor,
                            colorScheme: colorScheme,
                            onShowPRBreakdown: { showingPRBreakdown = true }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if !showUnassignedDay {
                    SyncFitAICoachCard(
                        model: dataStore.coachCardModel(
                            for: selectedDate,
                            profile: appState.profile
                        ),
                        isPremium: subscriptionManager.isSubscribed,
                        onViewPlan: {
                            if subscriptionManager.isSubscribed {
                                appState.presentAICoach()
                            } else {
                                appState.presentSyncFitPlusUpgrade(highlight: .personalizedRoutines)
                            }
                        }
                    )
                    .id(dataStore.currentCalendarDay)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if showRestDay {
                            RestDayRecoverySection(
                                proteinGoal: appState.profile.proteinTarget,
                                onOpenSchedule: { showingScheduleSetup = true }
                            )
                        } else {
                            DayExercisesSection(
                                title: Calendar.current.isDateInToday(selectedDate) ? "Today's exercises" : "Exercises",
                                workouts: dayWorkouts,
                                colorScheme: colorScheme,
                                selectedDate: selectedDate,
                                subtitle: { rowSubtitle(for: $0) },
                                lastPerformance: { dataStore.workoutPlanLastSessionLine(for: $0, on: selectedDate) },
                                onTap: handleExerciseTap,
                                onDelete: { dataStore.deleteWorkout($0) },
                                onAdd: { showingLogSheet = true }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .background(SyncFitTheme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !showRestDay && !showUnassignedDay && workoutSessionState != .completed {
                    WorkoutSessionStickyCTA(
                        sessionState: workoutSessionState,
                        onStartWorkout: { startWorkout() }
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("Workouts")
                            .font(.headline)
                        Text(weekProgressLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Schedule") {
                        showingScheduleSetup = true
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .sheet(isPresented: $showingLogSheet) {
                LogWorkoutSheet(logDate: selectedDate)
            }
            .sheet(item: $editingWorkout) { workout in
                EditWorkoutSheet(workout: workout)
            }
            .sheet(item: $editingRoutine) { routine in
                RoutineEditorSheet(routine: routine)
            }
            .sheet(isPresented: $showingScheduleSetup) {
                NavigationStack {
                    ScheduleSetupView()
                }
            }
            .onAppear {
                syncSelectedDayFromSchedule()
                if appState.shouldPresentScheduleSetup {
                    showingScheduleSetup = true
                    appState.shouldPresentScheduleSetup = false
                }
                handlePendingHomeWorkoutAction()
            }
            .onChange(of: appState.pendingWorkoutHomeAction) { _, _ in
                handlePendingHomeWorkoutAction()
            }
            .onChange(of: selectedDate) { _, _ in
                syncSelectedDayFromSchedule()
            }
            .onChange(of: dataStore.weekSchedule) { _, _ in
                syncSelectedDayFromSchedule()
            }
            .onChange(of: showingScheduleSetup) { _, isPresented in
                if !isPresented {
                    syncSelectedDayFromSchedule()
                }
            }
            .fullScreenCover(item: $activeSession) { session in
                ActiveWorkoutSessionView(session: session) { result in
                    dataStore.markWorkoutCompleted(for: session.logDate)
                    Task {
                        await healthKit.syncWorkoutSession(result, on: session.logDate)
                    }
                }
            }
            .sheet(item: $workoutCompleteResult) { result in
                WorkoutCompleteSheet(result: result)
            }
            .sheet(isPresented: $showingPRBreakdown) {
                PersonalRecordBreakdownSheet(
                    records: dataStore.personalRecordDetails(on: selectedDate)
                )
            }
        }
    }

    private func syncSelectedDayFromSchedule() {
        dataStore.syncWorkoutDayFromSchedule(for: selectedDate)
    }

    private func handlePendingHomeWorkoutAction() {
        guard let action = appState.pendingWorkoutHomeAction else { return }
        appState.pendingWorkoutHomeAction = nil
        selectedDate = .now
        syncSelectedDayFromSchedule()

        switch action {
        case .startWorkout:
            startWorkout()
        case .resumeWorkout:
            startWorkout()
        case .viewCompleted:
            if workoutSessionState == .completed {
                viewWorkoutSummary()
            }
        }
    }

    private func startWorkout(jumpingTo workout: WorkoutEntry? = nil) {
        if workoutSessionState == .completed { return }

        dataStore.applyScheduledPlan(for: selectedDate)

        let routine = dataStore.buildActiveWorkoutRoutine(for: selectedDate)
        guard !routine.sortedExercises.isEmpty else {
            showingLogSheet = true
            return
        }

        var startIndex = 0
        if let workout, let index = dataStore.exerciseIndex(in: routine, for: workout.exercise.name) {
            startIndex = index
        }

        activeSession = ActiveWorkoutSession(
            routine: routine,
            logDate: selectedDate,
            startExerciseIndex: startIndex
        )
    }

    private func handleExerciseTap(_ workout: WorkoutEntry) {
        if workoutSessionState == .inProgress {
            startWorkout(jumpingTo: workout)
        } else {
            editingWorkout = workout
        }
    }

    private func viewWorkoutSummary() {
        workoutCompleteResult = dataStore.buildSessionResult(for: selectedDate, profile: appState.profile)
    }

    private func rowSubtitle(for workout: WorkoutEntry) -> String? {
        guard dataStore.isOffCategoryExercise(workout, on: selectedDate) else { return nil }
        return "\(workout.exercise.muscleGroup) · off-plan"
    }
}

// MARK: - Daily hero & history

private enum HistoryDayKey {
    static func make(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Calendar.current.startOfDay(for: date))
    }
}

private struct DailyWorkoutHeroCard: View {
    let weekdayLabel: String
    let title: String
    let detailLine: String
    let volumeLine: String?
    let personalRecordsToday: Int
    let sessionState: WorkoutSessionState
    var accentColor: Color = SyncFitTheme.accentBright
    let colorScheme: ColorScheme
    let onShowPRBreakdown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(weekdayLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentColor)
                .textCase(.uppercase)

            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(detailLine)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if let volumeLine {
                Text(volumeLine)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            if personalRecordsToday > 0 {
                Button(action: onShowPRBreakdown) {
                    HStack(spacing: 6) {
                        Text("🎉 +\(personalRecordsToday) PR\(personalRecordsToday == 1 ? "" : "s") today")
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(SyncFitTheme.accentBright)
                }
                .buttonStyle(.plain)
            }

            if sessionState == .completed {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                    Text("Completed ✓")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            SyncFitTheme.accent.opacity(colorScheme == .dark ? 0.24 : 0.14),
                            Color(.secondarySystemGroupedBackground)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(SyncFitTheme.accentBright.opacity(0.28), lineWidth: 1)
        )
    }
}

private struct WorkoutSessionStickyCTA: View {
    let sessionState: WorkoutSessionState
    let onStartWorkout: () -> Void

    var body: some View {
        switch sessionState {
        case .notStarted:
            stickyButton(title: "Start Workout", action: onStartWorkout)
        case .inProgress:
            stickyButton(title: "Continue Workout", action: onStartWorkout)
        case .completed:
            EmptyView()
        }
    }

    private func stickyButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(SyncFitTheme.accentBright)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: SyncFitTheme.accentBright.opacity(0.25), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}

private struct PersonalRecordBreakdownSheet: View {
    @Environment(\.dismiss) private var dismiss

    let records: [PersonalRecordDetail]

    var body: some View {
        NavigationStack {
            List {
                if records.isEmpty {
                    Text("No personal records logged for this day.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.exerciseName)
                                .font(.headline)
                            Text(record.detail)
                                .font(.subheadline)
                                .foregroundStyle(SyncFitTheme.accentBright)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Personal Records")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ExerciseSplitFilterBar: View {
    @Binding var selectedKind: WorkoutScheduleKind?
    let primaryKinds: [WorkoutScheduleKind]
    let extraKinds: [WorkoutScheduleKind]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(primaryKinds) { kind in
                splitChip(kind)
            }

            Menu {
                ForEach(extraKinds) { kind in
                    Button(kind.displayName) {
                        selectedKind = kind
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(extraMenuTitle)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(isExtraKindActive ? .white : SyncFitTheme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isExtraKindActive ? SyncFitTheme.accentBright : SyncFitTheme.accent.opacity(0.1))
                )
            }
        }
    }

    private var isExtraKindActive: Bool {
        guard let selectedKind else { return false }
        return extraKinds.contains(selectedKind)
    }

    private var extraMenuTitle: String {
        if let selectedKind, extraKinds.contains(selectedKind) {
            return selectedKind.displayName
        }
        return "More"
    }

    @ViewBuilder
    private func splitChip(_ kind: WorkoutScheduleKind) -> some View {
        Button {
            selectedKind = selectedKind == kind ? nil : kind
        } label: {
            Text(kind.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selectedKind == kind ? .white : SyncFitTheme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selectedKind == kind ? SyncFitTheme.accentBright : SyncFitTheme.accent.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rest day recovery

private struct RestDayRecoverySection: View {
    let proteinGoal: Int
    let onOpenSchedule: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recovery")
                .font(.headline)

            VStack(alignment: .leading, spacing: 0) {
                RecoveryTipRow(
                    icon: "💧",
                    text: "Hydration — aim for 3–4L of water today"
                )
                Divider().padding(.leading, 36)
                RecoveryTipRow(
                    icon: "🥩",
                    text: "Protein — hit your \(proteinGoal)g goal to support muscle repair"
                )
                Divider().padding(.leading, 36)
                RecoveryTipRow(
                    icon: "😴",
                    text: "Sleep — 7–9 hours accelerates recovery by up to 40%"
                )
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )

            Button(action: onOpenSchedule) {
                Text("Change rest day → Schedule")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }
}

private struct RecoveryTipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(icon)
                .font(.system(size: 16))
                .frame(width: 24, alignment: .center)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 200 / 255, green: 200 / 255, blue: 200 / 255))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }
}

private struct DayExercisesSection: View {
    let title: String
    let workouts: [WorkoutEntry]
    let colorScheme: ColorScheme
    let selectedDate: Date
    let subtitle: (WorkoutEntry) -> String?
    let lastPerformance: (WorkoutEntry) -> WorkoutPlanLastSessionInfo
    let onTap: (WorkoutEntry) -> Void
    let onDelete: (WorkoutEntry) -> Void
    let onAdd: () -> Void

    @State private var workoutPendingRemoval: WorkoutEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button("Add", action: onAdd)
                    .font(.subheadline.weight(.semibold))
            }

            List {
                if workouts.isEmpty {
                    Text("No exercises yet — tap Add to log one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                        .listRowBackground(Color(.secondarySystemGroupedBackground))
                } else {
                    ForEach(workouts) { workout in
                    Button { onTap(workout) } label: {
                        HStack(alignment: .center) {
                            WorkoutRow(
                                workout: workout,
                                colorScheme: colorScheme,
                                subtitle: subtitle(workout),
                                lastSession: lastPerformance(workout)
                            )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            workoutPendingRemoval = workout
                        } label: {
                            Text("Remove")
                        }
                        .tint(.red)
                    }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .id(workouts.map(\.id))
            .frame(height: CGFloat(max(workouts.count, 1)) * 96 + 8)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .alert(
                "Remove from today's workout?",
                isPresented: Binding(
                    get: { workoutPendingRemoval != nil },
                    set: { if !$0 { workoutPendingRemoval = nil } }
                )
            ) {
                Button("Remove", role: .destructive) {
                    if let workout = workoutPendingRemoval {
                        onDelete(workout)
                    }
                    workoutPendingRemoval = nil
                }
                Button("Cancel", role: .cancel) {
                    workoutPendingRemoval = nil
                }
            } message: {
                Text("This removes the exercise from this session only. Your routine template is unchanged.")
            }
        }
    }
}

private struct DayTemplateAssignSheet: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.dismiss) private var dismiss

    let kind: WorkoutScheduleKind
    let onAssign: (WorkoutRoutine) -> Void
    let onBuildExercises: () -> Void

    private var preferredName: String { "\(kind.displayName) Day" }

    private var recommendedRoutine: WorkoutRoutine? {
        dataStore.routines.first {
            $0.name.caseInsensitiveCompare(preferredName) == .orderedSame
        }
    }

    private var otherRoutines: [WorkoutRoutine] {
        dataStore.routines.filter { routine in
            routine.id != recommendedRoutine?.id
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Add exercises for \(kind.displayName.lowercased()) day, or link an existing routine.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        dismiss()
                        onBuildExercises()
                    } label: {
                        Label("Build \(preferredName) exercises", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }

                if let recommended = recommendedRoutine {
                    Section("Use existing routine") {
                        Button {
                            onAssign(recommended)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recommended.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("\(recommended.sortedExercises.count) exercises · Recommended")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }

                        ForEach(otherRoutines) { routine in
                            Button {
                                onAssign(routine)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(routine.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("\(routine.sortedExercises.count) exercises")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else if !otherRoutines.isEmpty {
                    Section("Use existing routine") {
                        ForEach(otherRoutines) { routine in
                            Button {
                                onAssign(routine)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(routine.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("\(routine.sortedExercises.count) exercises")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(kind.displayName) Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct LastSessionSummaryLine: View {
    let summary: RecentWorkoutDaySummary?
    let onTap: () -> Void

    private var lineText: String {
        guard let summary else { return "No previous sessions yet" }
        let session = RoutineDisplayName.short(from: summary.sessionName)
        let when = DayHistory.displayTitle(for: summary.date)
        if summary.durationMinutes > 0 {
            return "\(session) · \(when) · \(WorkoutDurationFormat.minutes(summary.durationMinutes))"
        }
        return "\(session) · \(when)"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(lineText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if summary != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(summary == nil)
    }
}

private struct WorkoutHistoryPanel: View {
    let summaries: [RecentWorkoutDaySummary]
    @Binding var expandedDayKeys: Set<String>
    let colorScheme: ColorScheme
    let onEditWorkout: (WorkoutEntry) -> Void

    @EnvironmentObject private var dataStore: FitnessDataStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if summaries.isEmpty {
                    Text("No workout history yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    ForEach(summaries) { summary in
                        CollapsibleHistoryDayRow(
                            summary: summary,
                            isExpanded: expandedDayKeys.contains(HistoryDayKey.make(for: summary.date)),
                            workouts: dataStore.workouts(on: summary.date),
                            colorScheme: colorScheme,
                            onToggle: {
                                let key = HistoryDayKey.make(for: summary.date)
                                if expandedDayKeys.contains(key) {
                                    expandedDayKeys.remove(key)
                                } else {
                                    expandedDayKeys.insert(key)
                                }
                            },
                            onEdit: onEditWorkout
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
    }
}

private struct CollapsibleHistoryDayRow: View {
    let summary: RecentWorkoutDaySummary
    let isExpanded: Bool
    let workouts: [WorkoutEntry]
    let colorScheme: ColorScheme
    let onToggle: () -> Void
    let onEdit: (WorkoutEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .center, spacing: 0) {
                    RecentWorkoutRow(summary: summary, showsTrailingChevron: false)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SyncFitTheme.accent.opacity(0.7))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                        .padding(.trailing, 16)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                        .padding(.horizontal, 16)

                    ForEach(workouts) { workout in
                        Button { onEdit(workout) } label: {
                            WorkoutRow(workout: workout, colorScheme: colorScheme)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 14)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(SyncFitTheme.accent.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct RecentWorkoutRow: View {
    let summary: RecentWorkoutDaySummary
    var showsTrailingChevron: Bool = true

    private var statLine: String {
        var parts: [String] = []
        if summary.durationMinutes > 0 {
            parts.append(WorkoutDurationFormat.minutes(summary.durationMinutes))
        }
        if summary.totalSets > 0 {
            parts.append("\(summary.totalSets) sets")
        }
        if summary.personalRecords > 0 {
            parts.append("\(summary.personalRecords) PR\(summary.personalRecords == 1 ? "" : "s")")
        }
        return parts.joined(separator: " • ")
    }

    private var highlightLine: String? {
        guard let delta = summary.volumeDeltaVsPrevious else { return nil }
        let prefix = delta > 0 ? "+" : ""
        return "\(prefix)\(delta) lb total volume vs last session"
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.sessionName)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(SyncFitTheme.accentBright)

                Text(DayHistory.displayTitle(for: summary.date))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                if !statLine.isEmpty {
                    Text(statLine)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if let highlightLine {
                    Text(highlightLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SyncFitTheme.accent)
                }
            }
            Spacer(minLength: 8)

            if showsTrailingChevron {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SyncFitTheme.accent.opacity(0.7))
                    .padding(8)
                    .background(
                        Circle()
                            .fill(SyncFitTheme.accent.opacity(0.1))
                    )
            }
        }
        .contentShape(Rectangle())
        .padding(16)
    }
}

private struct SelectedDayWorkoutsCard: View {
    let date: Date
    let workouts: [WorkoutEntry]
    let sessionName: String?
    let durationMinutes: Int
    let colorScheme: ColorScheme
    let onEdit: (WorkoutEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(DayHistory.displayTitle(for: date))
                .font(.headline)
            if let sessionName {
                Text(sessionName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SyncFitTheme.accent)
            }
            if durationMinutes > 0 {
                Text(WorkoutDurationFormat.minutes(durationMinutes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(workouts) { workout in
                Button { onEdit(workout) } label: {
                    WorkoutRow(workout: workout, colorScheme: colorScheme)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

private struct WorkoutRow: View {
    let workout: WorkoutEntry
    let colorScheme: ColorScheme
    var subtitle: String?
    var lastSession: WorkoutPlanLastSessionInfo? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ExerciseIllustrationView(
                    exerciseName: workout.exercise.name,
                    muscleGroup: workout.exercise.muscleGroup,
                    style: .thumbnail
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(workout.exercise.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if let lastSession {
                        Text(lastSession.text)
                            .font(.caption)
                            .foregroundStyle(
                                lastSession.isReadyPrompt
                                    ? SyncFitTheme.accentBright.opacity(0.85)
                                    : Color(.tertiaryLabel)
                            )
                    }

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Text(workout.displaySummary)
                        .font(.caption)
                        .foregroundStyle(SyncFitTheme.detailText(for: colorScheme))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct EditWorkoutSheet: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.dismiss) private var dismiss

    let workout: WorkoutEntry

    @State private var exerciseName: String
    @State private var muscleGroup: String
    @State private var plannedSets: [WorkoutSet]
    @State private var notes: String
    @State private var didLoadGlobalNote = false

    private var history: [ExerciseHistoryEntry] {
        dataStore.exerciseHistory(for: exerciseName, before: workout.date, limit: 5)
    }

    init(workout: WorkoutEntry) {
        self.workout = workout
        _exerciseName = State(initialValue: workout.exercise.name)
        _muscleGroup = State(initialValue: workout.exercise.muscleGroup)
        if workout.plannedSets.isEmpty {
            _plannedSets = State(initialValue: [WorkoutSet(reps: 8, weight: 135)])
        } else {
            _plannedSets = State(initialValue: workout.plannedSets)
        }
        _notes = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SelectedExerciseCard(
                        exercise: Exercise(name: exerciseName, muscleGroup: muscleGroup),
                        pulse: false,
                        showChangeButton: false,
                        showSelectedBadge: false,
                        onChange: {}
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .allowsHitTesting(false)
                }

                Section("Exercise") {
                    TextField("Exercise name", text: $exerciseName)
                    Picker("Muscle group", selection: $muscleGroup) {
                        ForEach(ExerciseLibrary.muscleGroups, id: \.self) { group in
                            Text(group).tag(group)
                        }
                    }
                }

                WorkoutSetsEditor(sets: $plannedSets, sectionTitle: "Planned sets")

                if !workout.sets.isEmpty {
                    Section("Logged today") {
                        Text(workout.setsSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                    Text("This note appears every time you log this exercise.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Exercise notes")
                }

                if !history.isEmpty {
                    Section("Recent history") {
                        HStack {
                            Text("Date").font(.caption.weight(.semibold))
                            Spacer()
                            Text("Sets").font(.caption.weight(.semibold)).frame(width: 36)
                            Text("Reps").font(.caption.weight(.semibold)).frame(width: 44)
                            Text("Weight").font(.caption.weight(.semibold)).frame(width: 56, alignment: .trailing)
                        }
                        .foregroundStyle(.secondary)

                        ForEach(history) { entry in
                            HStack {
                                Text(dataStore.relativeWorkoutDate(entry.date, from: workout.date))
                                    .font(.subheadline)
                                Spacer()
                                Text("\(entry.setsCount)")
                                    .font(.subheadline.monospacedDigit())
                                    .frame(width: 36)
                                Text(entry.repsSummary)
                                    .font(.subheadline.monospacedDigit())
                                    .frame(width: 44)
                                Text(entry.weightSummary)
                                    .font(.subheadline.monospacedDigit())
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit Exercise")
            .onAppear {
                guard !didLoadGlobalNote else { return }
                notes = dataStore.exerciseNote(for: workout.exercise.name)
                didLoadGlobalNote = true
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard !plannedSets.isEmpty else { return }
                        let updated = WorkoutEntry(
                            id: workout.id,
                            exercise: Exercise(name: exerciseName, muscleGroup: muscleGroup),
                            sets: workout.sets,
                            plannedSets: plannedSets,
                            date: workout.date,
                            notes: workout.notes
                        )
                        dataStore.updateWorkoutPlan(updated)
                        dataStore.setExerciseNote(notes, for: exerciseName)
                        dismiss()
                    }
                    .disabled(exerciseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plannedSets.isEmpty)
                }
            }
        }
    }
}

struct WorkoutSetsEditor: View {
    @Binding var sets: [WorkoutSet]
    var sectionTitle: String = "Sets"

    var body: some View {
        Section(sectionTitle) {
            ForEach($sets) { $set in
                VStack(alignment: .leading, spacing: 8) {
                    EditableIntRow(title: "Reps", value: $set.reps, range: 1...100)
                    EditableDoubleRow(title: "Weight", value: $set.weight, range: 0...1000, suffix: "lb", step: 5)
                }
            }
            .onDelete { sets.remove(atOffsets: $0) }

            Button("Add Set", systemImage: "plus") {
                let last = sets.last ?? WorkoutSet(reps: 8, weight: 135)
                sets.append(WorkoutSet(reps: last.reps, weight: last.weight))
            }
        }
    }
}

#Preview {
    WorkoutView()
        .environmentObject(AppState.preview())
        .environmentObject(FitnessDataStore.preview())
}
