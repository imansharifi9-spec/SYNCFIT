import SwiftUI

struct RoutineEditorSheet: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.dismiss) private var dismiss

    let existingRoutine: WorkoutRoutine?
    let fixedSplitKind: WorkoutScheduleKind?
    var persistToStore: Bool
    var showsSyncFitPlusPromo: Bool
    var onSaved: ((WorkoutRoutine) -> Void)?

    @State private var name: String
    @State private var exerciseItems: [RoutineExerciseItem]
    @State private var showingAddExercise = false
    @State private var planningExerciseID: UUID?
    @State private var pendingExercise: Exercise?

    private var isCreating: Bool { existingRoutine == nil }

    private static let nameTemplates: [RoutineNameTemplate] = [
        RoutineNameTemplate(title: "Push Day", preset: "Push Day"),
        RoutineNameTemplate(title: "Pull Day", preset: "Pull Day"),
        RoutineNameTemplate(title: "Leg Day", preset: "Leg Day"),
        RoutineNameTemplate(title: "Upper", preset: "Upper"),
        RoutineNameTemplate(title: "Lower", preset: "Lower"),
        RoutineNameTemplate(title: "Full Body", preset: "Full Body")
    ]

    init(
        routine: WorkoutRoutine? = nil,
        suggestedName: String? = nil,
        fixedSplitKind: WorkoutScheduleKind? = nil,
        persistToStore: Bool = true,
        showsSyncFitPlusPromo: Bool = true,
        onSaved: ((WorkoutRoutine) -> Void)? = nil
    ) {
        self.existingRoutine = routine
        self.fixedSplitKind = fixedSplitKind
        self.persistToStore = persistToStore
        self.showsSyncFitPlusPromo = showsSyncFitPlusPromo
        self.onSaved = onSaved
        let initialName: String
        if let fixedSplitKind, routine == nil {
            initialName = "\(fixedSplitKind.displayName) Day"
        } else {
            initialName = routine?.name ?? suggestedName ?? ""
        }
        _name = State(initialValue: initialName)
        _exerciseItems = State(
            initialValue: routine?.sortedExercises.map { $0.isolatedCopy() } ?? []
        )
    }

    private var isSplitSetup: Bool {
        fixedSplitKind != nil && isCreating
    }

    private var draftRoutine: WorkoutRoutine {
        WorkoutRoutine(id: existingRoutine?.id ?? UUID(), name: name, exercises: exerciseItems)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isCreating, showsSyncFitPlusPromo, !appState.isSyncFitPlusSubscriber {
                    Section {
                        SyncFitPlusRoutinePromo {
                            appState.presentSyncFitPlusUpgrade(highlight: .personalizedRoutines)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                }

                if isSplitSetup, let kind = fixedSplitKind {
                    Section {
                        Text("Add the exercises you do on \(kind.displayName.lowercased()) day.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        TextField("e.g. Bro Split A", text: $name)
                            .font(.body.weight(.semibold))

                        Text("Quick fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 8
                        ) {
                            ForEach(Self.nameTemplates) { template in
                                RoutineNameTemplateChip(
                                    title: template.title,
                                    isSelected: name.caseInsensitiveCompare(template.preset) == .orderedSame
                                ) {
                                    name = template.preset
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    } header: {
                        Text("Routine name")
                    } footer: {
                        Text("Quick fill only changes the routine name.")
                            .font(.caption)
                    }
                }

                Section("Exercises") {
                    if exerciseItems.isEmpty {
                        Text("Add the exercises you do every session.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(exerciseItems) { item in
                            RoutineExerciseEditorRow(
                                item: item,
                                routine: draftRoutine,
                                onTap: { planningExerciseID = item.id }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    exerciseItems.removeAll { $0.id == item.id }
                                } label: {
                                    Text("Remove")
                                }
                                .tint(.red)
                            }
                        }
                        .onMove(perform: moveExercises)
                    }

                    Button(
                        exerciseItems.isEmpty ? "+ Add First Exercise" : "Add Exercise",
                        systemImage: "plus"
                    ) {
                        showingAddExercise = true
                    }
                    .font(exerciseItems.isEmpty ? .subheadline.weight(.semibold) : .body)
                }
                .environment(\.editMode, .constant(.active))
            }
            .navigationTitle(isSplitSetup ? "\(fixedSplitKind?.displayName ?? "") Day Exercises" : (isCreating ? "Create Routine" : "Edit Routine"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Create" : "Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || exerciseItems.isEmpty)
                }
            }
            .sheet(isPresented: $showingAddExercise) {
                AddExercisePickerSheet { exercise in
                    pendingExercise = exercise
                }
            }
            .sheet(item: $pendingExercise) { exercise in
                RoutineExerciseTargetsSheet(exercise: exercise) { setCount, reps, weight in
                    exerciseItems.append(
                        RoutineExerciseItem(
                            exercise: exercise,
                            sortOrder: exerciseItems.count,
                            plannedSetCount: setCount,
                            plannedReps: reps,
                            plannedWeight: weight
                        )
                    )
                    pendingExercise = nil
                }
            }
            .sheet(isPresented: Binding(
                get: { planningExerciseID != nil },
                set: { if !$0 { planningExerciseID = nil } }
            )) {
                if let id = planningExerciseID,
                   let index = exerciseItems.firstIndex(where: { $0.id == id }) {
                    RoutineExerciseTargetsSheet(
                        exercise: exerciseItems[index].exercise,
                        initialSetCount: exerciseItems[index].plannedSetCount,
                        initialReps: exerciseItems[index].plannedReps,
                        initialWeight: exerciseItems[index].plannedWeight
                    ) { setCount, reps, weight in
                        exerciseItems[index].plannedSetCount = setCount
                        exerciseItems[index].plannedReps = reps
                        exerciseItems[index].plannedWeight = weight
                        planningExerciseID = nil
                    }
                }
            }
        }
    }

    private func moveExercises(from source: IndexSet, to destination: Int) {
        exerciseItems.move(fromOffsets: source, toOffset: destination)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !exerciseItems.isEmpty else { return }

        let routineID = existingRoutine?.id ?? UUID()
        let ordered = exerciseItems.enumerated().map { index, item in
            RoutineExerciseItem(
                id: item.id,
                exercise: item.exercise,
                sortOrder: index,
                plannedSetCount: item.plannedSetCount,
                plannedReps: item.plannedReps,
                plannedWeight: item.plannedWeight
            )
        }
        let routine = WorkoutRoutine(id: routineID, name: trimmedName, exercises: ordered)

        if persistToStore {
            if existingRoutine == nil {
                dataStore.addRoutine(routine)
            } else {
                dataStore.updateRoutine(routine)
            }
        }
        onSaved?(routine)
        dismiss()
    }
}

private struct RoutineExerciseEditorRow: View {
    let item: RoutineExerciseItem
    let routine: WorkoutRoutine
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.exercise.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    HStack(spacing: 0) {
                        Text(item.plannedSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if routine.showsMuscleGroup(for: item.exercise) {
                            Text("  ·  \(item.exercise.muscleGroup)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "line.3.horizontal")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct RoutineExerciseTargetsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let exercise: Exercise
    let onSave: (Int, Int, Double?) -> Void

    @State private var setCount: Int
    @State private var reps: Int
    @State private var weightText: String
    @State private var isBodyweight: Bool

    init(
        exercise: Exercise,
        initialSetCount: Int = 3,
        initialReps: Int = 8,
        initialWeight: Double? = nil,
        onSave: @escaping (Int, Int, Double?) -> Void
    ) {
        self.exercise = exercise
        self.onSave = onSave
        _setCount = State(initialValue: max(initialSetCount, 1))
        _reps = State(initialValue: max(initialReps, 1))
        if let initialWeight {
            if initialWeight == 0 {
                _isBodyweight = State(initialValue: true)
                _weightText = State(initialValue: "")
            } else {
                _isBodyweight = State(initialValue: false)
                _weightText = State(initialValue: SyncFitFormat.decimal(initialWeight))
            }
        } else {
            _isBodyweight = State(initialValue: exercise.isBodyweight)
            _weightText = State(initialValue: "")
        }
    }

    private var canSave: Bool {
        isBodyweight || !weightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(exercise.name)
                        .font(.headline)
                    if exercise.isBodyweight {
                        Text("Bodyweight movement")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Set targets") {
                    Stepper("Sets: \(setCount)", value: $setCount, in: 1...12)
                    Stepper("Reps: \(reps)", value: $reps, in: 1...100)

                    if exercise.isBodyweight {
                        Text("Bodyweight")
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle("Bodyweight", isOn: $isBodyweight)
                        if !isBodyweight {
                            TextField("Weight (lbs)", text: $weightText)
                                .keyboardType(.decimalPad)
                        }
                    }
                }

                Section {
                    Text("These targets apply to this exercise in this routine only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Exercise Targets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let weight: Double?
                        if isBodyweight || exercise.isBodyweight {
                            weight = 0
                        } else if let parsed = Double(weightText.replacingOccurrences(of: ",", with: "")) {
                            weight = SyncFitFormat.round(parsed)
                        } else {
                            weight = nil
                        }
                        guard weight != nil else { return }
                        onSave(setCount, reps, weight)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct LogRoutineSheet: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.dismiss) private var dismiss

    let routine: WorkoutRoutine
    let logDate: Date

    @State private var drafts: [RoutineExerciseDraft]
    @State private var showingAddExercise = false

    init(routine: WorkoutRoutine, logDate: Date) {
        self.routine = routine
        self.logDate = logDate
        _drafts = State(initialValue: routine.sortedExercises.map {
            RoutineExerciseDraft(exercise: $0.exercise)
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(routine.name)
                        .font(.headline)
                    Text("\(drafts.count) exercises ready to log")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if drafts.isEmpty {
                    Section {
                        Text("Add at least one exercise to log this routine.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach($drafts) { $draft in
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(draft.exercise.name)
                                    .font(.subheadline.weight(.semibold))
                                Text(draft.exercise.muscleGroup)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            WorkoutSetsEditor(sets: $draft.sets)

                            TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                        }
                    }
                    .onDelete { drafts.remove(atOffsets: $0) }
                }

                Section {
                    Button("Add Exercise", systemImage: "plus") {
                        showingAddExercise = true
                    }
                }
            }
            .navigationTitle("Log Routine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save All") { save() }
                        .disabled(drafts.isEmpty || drafts.allSatisfy { $0.sets.isEmpty })
                }
            }
            .sheet(isPresented: $showingAddExercise) {
                AddExercisePickerSheet { exercise in
                    drafts.append(RoutineExerciseDraft(exercise: exercise))
                }
            }
        }
    }

    private func save() {
        dataStore.logRoutine(routine, drafts: drafts, on: Calendar.current.startOfDay(for: logDate))
        dismiss()
    }
}

private struct RoutineNameTemplate: Identifiable, Hashable {
    let title: String
    let preset: String

    var id: String { title }
}

private struct RoutineNameTemplateChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(isSelected ? SyncFitTheme.accentBright : Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct AddExercisePickerSheet: View {
    let onSelect: (Exercise) -> Void

    var body: some View {
        AddExerciseSheet(mode: .routineSingleSelect(onSelect: onSelect))
    }
}