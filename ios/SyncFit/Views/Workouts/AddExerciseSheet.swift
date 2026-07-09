import SwiftUI

enum AddExercisePickerMode {
    case workoutDay(Date)
    case routineSingleSelect(onSelect: (Exercise) -> Void)
}

struct AddExerciseSheet: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.dismiss) private var dismiss

    let mode: AddExercisePickerMode

    @State private var searchText = ""
    @State private var selectedIDs = Set<UUID>()
    @FocusState private var isSearchFocused: Bool

    private var isMultiSelect: Bool {
        if case .workoutDay = mode { return true }
        return false
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredExercises: [Exercise] {
        dataStore.searchExercises(query: searchText)
    }

    private var recentlyUsed: [Exercise] {
        guard !isSearching else { return [] }
        return dataStore.recentlyUsedExercises(limit: 4)
    }

    private var alphabeticalExercises: [Exercise] {
        let recentIDs = Set(recentlyUsed.map(\.id))
        return filteredExercises.filter { !recentIDs.contains($0.id) }
    }

    private var selectionCount: Int { selectedIDs.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if !recentlyUsed.isEmpty {
                            Text("Recently used")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                                .padding(.leading, 4)
                                .padding(.bottom, 2)

                            ForEach(recentlyUsed) { exercise in
                                exerciseRow(exercise)
                            }

                            Divider()
                                .padding(.vertical, 8)
                        }

                        if filteredExercises.isEmpty {
                            Text("No exercises match your search.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(isSearching ? filteredExercises : alphabeticalExercises) { exercise in
                                exerciseRow(exercise)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .background(SyncFitTheme.background)
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isMultiSelect, selectionCount > 0 {
                    Button("Add (\(selectionCount))") {
                        addSelectedExercises()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(
                        SyncFitTheme.background
                            .shadow(color: .black.opacity(0.2), radius: 8, y: -4)
                    )
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    isSearchFocused = true
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search exercises...", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(SyncFitTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func exerciseRow(_ exercise: Exercise) -> some View {
        ExerciseSearchRow(
            exercise: exercise,
            isSelected: selectedIDs.contains(exercise.id)
        ) {
            handleTap(exercise)
        }
    }

    private func handleTap(_ exercise: Exercise) {
        switch mode {
        case .workoutDay:
            withAnimation(.easeOut(duration: 0.18)) {
                if selectedIDs.contains(exercise.id) {
                    selectedIDs.remove(exercise.id)
                } else {
                    selectedIDs.insert(exercise.id)
                }
            }
        case .routineSingleSelect(let onSelect):
            onSelect(exercise)
            dismiss()
        }
    }

    private func addSelectedExercises() {
        guard case .workoutDay(let date) = mode else { return }
        let dayStart = Calendar.current.startOfDay(for: date)
        let selected = dataStore.exercises.filter { selectedIDs.contains($0.id) }

        for exercise in selected {
            var entryNotes = ""
            let draft = WorkoutEntry(exercise: exercise, sets: [], date: dayStart, notes: entryNotes)
            if dataStore.isOffCategoryExercise(draft, on: date) {
                entryNotes = WorkoutEntryMarker.manual
            }
            dataStore.addWorkout(
                WorkoutEntry(
                    exercise: exercise,
                    sets: [],
                    date: dayStart,
                    notes: entryNotes
                )
            )
        }
        dismiss()
    }
}

struct LogWorkoutSheet: View {
    let logDate: Date

    init(logDate: Date = .now) {
        self.logDate = logDate
    }

    var body: some View {
        AddExerciseSheet(mode: .workoutDay(logDate))
    }
}
