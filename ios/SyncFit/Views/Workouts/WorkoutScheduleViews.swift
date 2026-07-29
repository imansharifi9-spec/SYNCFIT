import SwiftUI

enum WorkoutScheduleColors {
    static func color(for kind: WorkoutScheduleKind) -> Color {
        switch kind {
        case .unassigned:
            return .clear
        case .rest:
            return Color(.tertiaryLabel)
        case .push:
            return Color(red: 0.95, green: 0.62, blue: 0.12)
        case .pull:
            return Color(red: 0.35, green: 0.58, blue: 0.95)
        case .legs:
            return SyncFitTheme.accentBright
        case .upper:
            return Color(red: 0.58, green: 0.42, blue: 0.92)
        case .lower:
            return Color(red: 0.22, green: 0.72, blue: 0.68)
        case .arms:
            return Color(red: 0.92, green: 0.38, blue: 0.55)
        case .backChest:
            return Color(red: 0.45, green: 0.55, blue: 0.88)
        case .fullBody:
            return Color(red: 0.55, green: 0.55, blue: 0.58)
        case .custom:
            return SyncFitTheme.accent
        }
    }

    static func color(
        for assignment: WorkoutScheduleAssignment,
        routines: [WorkoutRoutine]
    ) -> Color {
        let kind = assignment.resolvedScheduleKind(matching: routines)
        return color(for: kind)
    }
}

struct TodaysWorkoutHeader: View {
    let date: Date
    let assignment: WorkoutScheduleAssignment
    let routines: [WorkoutRoutine]
    let isRestDay: Bool
    var schedulePreview: WorkoutSchedulePreview?

    private var weekdayName: String {
        WorkoutScheduleFormatters.weekdayName(for: date)
    }

    private var workoutLabel: String {
        if isRestDay { return "Rest Day" }
        return assignment.subtitle(matching: routines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today's Workout")
                .font(.title3.weight(.bold))
                .foregroundStyle(SyncFitTheme.itemHeading)

            Text("\(workoutLabel) • \(weekdayName)")
                .font(.headline.weight(.semibold))
                .foregroundStyle(isRestDay ? .secondary : SyncFitTheme.accentBright)

            if !isRestDay,
               let nextTitle = schedulePreview?.nextTitle,
               let nextDay = schedulePreview?.nextWeekdayName {
                Text("Next: \(nextTitle) • \(nextDay)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RestDayHeroCard: View {
    let colorScheme: ColorScheme
    let onTrainAnyway: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("😴")
                .font(.system(size: 40))

            Text("Today is a Rest Day")
                .font(.title3.weight(.bold))

            Text("Recovery is part of the plan. Focus on nutrition and sleep today.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onTrainAnyway) {
                Text("Train anyway →")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
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

struct UnassignedDayHeroCard: View {
    let colorScheme: ColorScheme
    let onOpenSchedule: () -> Void
    let onLogAdHoc: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No workout planned")
                .font(.title3.weight(.bold))

            Text("Assign a routine in your weekly schedule, or log exercises without a plan.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(action: onOpenSchedule) {
                Text("Set Up Schedule")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(SyncFitTheme.primaryAction)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(action: onLogAdHoc) {
                Text("Log exercises anyway")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SyncFitTheme.primaryAction)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(SyncFitTheme.accent.opacity(colorScheme == .dark ? 0.2 : 0.12), lineWidth: 1)
        )
    }
}

struct WorkoutScheduleSummarySection: View {
    let schedule: WorkoutWeekSchedule
    let preview: WorkoutSchedulePreview
    let routines: [WorkoutRoutine]
    @Binding var isExpanded: Bool
    let onEditSchedule: () -> Void

    private var summaryLine: String {
        var parts = ["Today: \(preview.todayTitle)"]
        if let nextTitle = preview.nextTitle, let abbrev = preview.nextDayAbbrev {
            parts.append("Next: \(nextTitle) (\(abbrev))")
        }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Schedule")
                            .font(.headline)
                            .foregroundStyle(SyncFitTheme.itemHeading)
                        Text(summaryLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SyncFitTheme.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(WorkoutWeekSchedule.mondayFirstDisplay.enumerated()), id: \.offset) { index, item in
                        let assignment = schedule.assignment(forWeekday: item.weekday)
                        let isToday = Calendar.current.component(.weekday, from: .now) == item.weekday

                        WorkoutScheduleDayReadOnlyRow(
                            dayLabel: item.label,
                            assignment: assignment,
                            routines: routines,
                            isToday: isToday
                        )

                        if index < WorkoutWeekSchedule.mondayFirstDisplay.count - 1 {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))

                Button(action: onEditSchedule) {
                    Text("Edit Schedule")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SyncFitTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct WorkoutScheduleDayReadOnlyRow: View {
    let dayLabel: String
    let assignment: WorkoutScheduleAssignment
    let routines: [WorkoutRoutine]
    let isToday: Bool

    var body: some View {
        HStack(spacing: 12) {
            if isToday {
                Text("\(dayLabel) • TODAY")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(SyncFitTheme.accentBright)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(SyncFitTheme.accentBright.opacity(0.16))
                    .clipShape(Capsule())
            } else {
                Text(dayLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
            }

            Spacer()

            ScheduleAssignmentTag(assignment: assignment, routines: routines)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(isToday ? SyncFitTheme.accent.opacity(0.1) : Color.clear)
    }
}

struct ScheduleAssignmentTag: View {
    let assignment: WorkoutScheduleAssignment
    let routines: [WorkoutRoutine]

    var body: some View {
        if assignment.kind == .unassigned {
            Text("Tap to assign")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
        } else if assignment.kind == .rest {
            Text("Rest")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        } else if let title = assignment.tagTitle(matching: routines) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(WorkoutScheduleColors.color(for: assignment, routines: routines))
                )
        }
    }
}

private struct ScheduleDayPickerContext: Identifiable {
    let id = UUID()
    let weekday: Int
    let dayLabel: String
}

struct ScheduleSetupView: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.dismiss) private var dismiss

    @State private var pickerContext: ScheduleDayPickerContext?
    @State private var editingRoutine: WorkoutRoutine?
    @State private var showingCreateRoutine = false
    @State private var pendingAssignWeekday: Int?
    @State private var showingResetConfirm = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ProgramTemplateBrowserView()
                } label: {
                    Label("Browse programs", systemImage: "books.vertical.fill")
                    Text("Import a ready-made split")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Programs")
            }

            Section {
                Text("Tap a day to assign a routine or mark it as rest.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            Section("Weekly Schedule") {
                ForEach(WorkoutWeekSchedule.mondayFirstDisplay, id: \.weekday) { item in
                    let assignment = dataStore.weekSchedule.assignment(forWeekday: item.weekday)
                    let isToday = Calendar.current.component(.weekday, from: .now) == item.weekday

                    Button {
                        pickerContext = ScheduleDayPickerContext(
                            weekday: item.weekday,
                            dayLabel: item.label
                        )
                    } label: {
                        ScheduleDayRow(
                            dayLabel: item.label,
                            assignment: assignment,
                            routines: dataStore.routines,
                            isToday: isToday
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Reset", role: .destructive) {
                    showingResetConfirm = true
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .alert("Reset workout plan?", isPresented: $showingResetConfirm) {
            Button("Reset Assignments", role: .destructive) {
                dataStore.resetWorkoutPlanning()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears your weekly schedule to blank days. Your logged workouts and saved routines are kept.")
        }
        .sheet(item: $pickerContext) { context in
            DayRoutinePickerSheet(
                weekday: context.weekday,
                dayLabel: context.dayLabel,
                onEditRoutine: { routine in
                    pickerContext = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        editingRoutine = routine
                    }
                },
                onCreateRoutine: {
                    pendingAssignWeekday = context.weekday
                    pickerContext = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showingCreateRoutine = true
                    }
                }
            )
        }
        .sheet(isPresented: $showingCreateRoutine) {
            RoutineEditorSheet(onSaved: { routine in
                if let weekday = pendingAssignWeekday {
                    dataStore.assignRoutine(routine, toWeekday: weekday)
                    pendingAssignWeekday = nil
                }
            })
        }
        .sheet(item: $editingRoutine) { routine in
            RoutineEditorSheet(routine: routine)
        }
    }
}

/// Kept for Settings deep links — same as `ScheduleSetupView`.
typealias EditScheduleView = ScheduleSetupView

private struct ScheduleDayRow: View {
    let dayLabel: String
    let assignment: WorkoutScheduleAssignment
    let routines: [WorkoutRoutine]
    let isToday: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(dayLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)

                if isToday {
                    Text("TODAY")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(SyncFitTheme.accentBright)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(SyncFitTheme.accentBright.opacity(0.16))
                        .clipShape(Capsule())
                }
            }

            Spacer()

            ScheduleAssignmentTag(assignment: assignment, routines: routines)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct DayRoutinePickerSheet: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.dismiss) private var dismiss

    let weekday: Int
    let dayLabel: String
    let onEditRoutine: (WorkoutRoutine) -> Void
    let onCreateRoutine: () -> Void

    @State private var routinePendingDelete: WorkoutRoutine?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        dataStore.assignRest(toWeekday: weekday)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "moon.zzz.fill")
                                .foregroundStyle(.secondary)
                            Text("Rest day")
                                .font(.body.weight(.semibold))
                            Spacer()
                            if dataStore.isRestAssigned(toWeekday: weekday) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(SyncFitTheme.accentBright)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section("Your routines") {
                    if dataStore.routines.isEmpty {
                        Text("No routines yet — create one below.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(dataStore.routines) { routine in
                            RoutinePickerRow(
                                routine: routine,
                                isAssigned: dataStore.isRoutineAssigned(routine, toWeekday: weekday),
                                usageCount: dataStore.assignmentCount(for: routine),
                                onAssign: {
                                    dataStore.assignRoutine(routine, toWeekday: weekday)
                                    dismiss()
                                },
                                onEdit: { onEditRoutine(routine) }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    routinePendingDelete = routine
                                } label: {
                                    Text("Delete")
                                }
                                .tint(.red)
                            }
                        }
                    }
                }

                Section {
                    Button(action: onCreateRoutine) {
                        Label("Create new routine", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .navigationTitle("Assign to \(dayLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert(
                "Delete \(routinePendingDelete?.name ?? "Routine")?",
                isPresented: Binding(
                    get: { routinePendingDelete != nil },
                    set: { if !$0 { routinePendingDelete = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let routine = routinePendingDelete {
                        dataStore.deleteRoutine(routine)
                    }
                    routinePendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    routinePendingDelete = nil
                }
            } message: {
                Text("This will remove it from all scheduled days.")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct RoutinePickerRow: View {
    let routine: WorkoutRoutine
    let isAssigned: Bool
    let usageCount: Int
    let onAssign: () -> Void
    let onEdit: () -> Void

    private var previewExercises: String {
        let names = routine.sortedExercises.prefix(3).map(\.exercise.name)
        guard !names.isEmpty else { return "No exercises yet" }
        let joined = names.joined(separator: ", ")
        if routine.sortedExercises.count > 3 {
            return "\(joined)…"
        }
        return joined
    }

    private var tagColor: Color {
        if let kind = WorkoutScheduleKind.matchingDayRoutine(named: routine.name) {
            return WorkoutScheduleColors.color(for: kind)
        }
        return WorkoutScheduleColors.color(for: .custom)
    }

    private var usageLabel: String? {
        guard usageCount > 0 else { return nil }
        return "Used \(usageCount)×"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(routine.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("\(routine.sortedExercises.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(tagColor.opacity(0.85)))
                    if let usageLabel {
                        Text("·  \(usageLabel)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(previewExercises)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onAssign)

            HStack(spacing: 10) {
                if isAssigned {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(SyncFitTheme.accentBright)
                }
                Button("Edit", action: onEdit)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SyncFitTheme.accent)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}
