import SwiftUI

// MARK: - Routine library

struct CoachRoutineLibraryView: View {
    @EnvironmentObject private var coachService: CoachService
    @State private var editingTemplate: CoachRoutineTemplate?
    @State private var showingCreate = false
    @State private var saveError: String?

    var body: some View {
        List {
            if coachService.routineTemplates.isEmpty {
                ContentUnavailableView(
                    "No routines yet",
                    systemImage: "dumbbell",
                    description: Text("Create reusable templates to send to any client.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(coachService.routineTemplates) { template in
                    Button {
                        editingTemplate = template
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(template.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(template.summaryText)
                                .font(.system(size: 12))
                                .foregroundStyle(CoachUIColor.muted)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(CoachUIColor.card)
                }
                .onDelete(perform: deleteTemplates)
            }
        }
        .scrollContentBackground(.hidden)
        .background(CoachUIColor.page)
        .navigationTitle("My Routines")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCreate = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear {
            Task { await coachService.refreshRoutineTemplates() }
        }
        .sheet(isPresented: $showingCreate) {
            CoachRoutineTemplateEditorView(template: CoachRoutineTemplate.blank()) { saved in
                await persistTemplate(saved)
            }
        }
        .sheet(item: $editingTemplate) { template in
            CoachRoutineTemplateEditorView(template: template) { saved in
                await persistTemplate(saved)
            }
        }
        .alert("Could not save routine", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func persistTemplate(_ template: CoachRoutineTemplate) async -> Bool {
        do {
            try await coachService.saveRoutineTemplate(template)
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func deleteTemplates(at offsets: IndexSet) {
        let templates = offsets.map { coachService.routineTemplates[$0] }
        Task {
            for template in templates {
                try? await coachService.deleteRoutineTemplate(template)
            }
        }
    }
}

// MARK: - Template editor

struct CoachRoutineTemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var days: [CoachRoutineTemplateDay]
    @State private var editingWeekday: WeekdaySelection?
    @State private var isSaving = false

    let templateID: UUID
    let createdAt: Date
    let onSave: (CoachRoutineTemplate) async -> Bool

    init(template: CoachRoutineTemplate, onSave: @escaping (CoachRoutineTemplate) async -> Bool) {
        templateID = template.id
        createdAt = template.createdAt
        _name = State(initialValue: template.name)
        _days = State(initialValue: CoachRoutineTemplate.normalizedWeekdays(from: template.days))
        self.onSave = onSave
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && days.contains { !$0.exercises.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Routine name") {
                    TextField("e.g. Push Pull Legs — Beginner", text: $name)
                }

                Section {
                    CoachRoutineWeekdayStrip(
                        selectedWeekday: Binding(
                            get: { editingWeekday?.weekday },
                            set: { newValue in
                                if let newValue {
                                    editingWeekday = WeekdaySelection(weekday: newValue)
                                } else {
                                    editingWeekday = nil
                                }
                            }
                        ),
                        hasExercises: { weekday in
                            day(for: weekday)?.exercises.isEmpty == false
                        },
                        onSelect: { weekday in
                            editingWeekday = WeekdaySelection(weekday: weekday)
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Weekly schedule")
                } footer: {
                    Text("Tap a day to add or edit exercises. Unassigned days are rest days.")
                        .font(.caption)
                }
            }
            .navigationTitle(name.isEmpty ? "New Routine" : "Edit Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave || isSaving)
                }
            }
            .sheet(item: $editingWeekday) { selection in
                if let index = dayIndex(for: selection.weekday) {
                    RoutineEditorSheet(
                        routine: days[index].asWorkoutRoutine(),
                        persistToStore: false,
                        showsSyncFitPlusPromo: false
                    ) { routine in
                        days[index].applyWorkoutRoutine(routine)
                        editingWeekday = nil
                    }
                }
            }
        }
    }

    private func dayIndex(for weekday: Int) -> Int? {
        days.firstIndex(where: { $0.weekday == weekday })
    }

    private func day(for weekday: Int) -> CoachRoutineTemplateDay? {
        guard let index = dayIndex(for: weekday) else { return nil }
        return days[index]
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isSaving = true
        let template = CoachRoutineTemplate(
            id: templateID,
            name: trimmedName,
            days: days,
            createdAt: createdAt
        )

        Task {
            let succeeded = await onSave(template)
            await MainActor.run {
                isSaving = false
                if succeeded {
                    dismiss()
                }
            }
        }
    }
}

private struct WeekdaySelection: Identifiable {
    let weekday: Int
    var id: Int { weekday }
}

private struct CoachRoutineWeekdayStrip: View {
    @Binding var selectedWeekday: Int?
    let hasExercises: (Int) -> Bool
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(WorkoutWeekSchedule.mondayFirstDisplay.enumerated()), id: \.offset) { index, item in
                Button {
                    selectedWeekday = item.weekday
                    onSelect(item.weekday)
                } label: {
                    VStack(spacing: 8) {
                        Text(DayHistory.weekdayLabels[index])
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(
                                selectedWeekday == item.weekday
                                    ? CoachUIColor.accent
                                    : CoachUIColor.muted
                            )

                        ZStack {
                            if selectedWeekday == item.weekday {
                                Circle()
                                    .stroke(CoachUIColor.accent, lineWidth: 2)
                                    .frame(width: 22, height: 22)
                            }

                            Circle()
                                .fill(
                                    hasExercises(item.weekday)
                                        ? CoachUIColor.accent
                                        : ConsistencyVisualStyle.emptyDot
                                )
                                .frame(
                                    width: hasExercises(item.weekday) ? 10 : 8,
                                    height: hasExercises(item.weekday) ? 10 : 8
                                )
                        }
                        .frame(height: 22)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Send routine

struct CoachSendRoutineSheet: View {
    let connection: CoachClientConnection

    @EnvironmentObject private var coachService: CoachService
    @EnvironmentObject private var chatService: CoachChatService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplateID: UUID?
    @State private var coachNote = ""
    @State private var isSending = false
    @State private var sendError: String?

    private var conversationId: String {
        CoachChatService.conversationId(
            userId: connection.clientUserID,
            coachId: coachService.coachFirestoreID
        )
    }

    private var selectedTemplate: CoachRoutineTemplate? {
        guard let selectedTemplateID else { return nil }
        return coachService.routineTemplates.first { $0.id == selectedTemplateID }
    }

    var body: some View {
        NavigationStack {
            Form {
                if coachService.routineTemplates.isEmpty {
                    Section {
                        Text("Create routines in My Routines before sending to clients.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Choose routine") {
                        ForEach(coachService.routineTemplates) { template in
                            Button {
                                selectedTemplateID = template.id
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(template.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(template.summaryText)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedTemplateID == template.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(CoachUIColor.accent)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Note (optional)") {
                    TextField("e.g. Start light on week one", text: $coachNote, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Send Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { sendRoutine() }
                        .disabled(selectedTemplate == nil || isSending)
                }
            }
            .onAppear {
                Task { await coachService.refreshRoutineTemplates() }
            }
            .alert("Could not send routine", isPresented: Binding(
                get: { sendError != nil },
                set: { if !$0 { sendError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sendError ?? "")
            }
        }
    }

    private func sendRoutine() {
        guard let template = selectedTemplate else { return }
        isSending = true

        let coachName = coachService.portalProfile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCoachName = coachName.isEmpty ? "Coach" : coachName
        let clientName = connection.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedClientName = clientName.isEmpty ? "Client" : clientName
        let note = coachNote.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            let success = await chatService.sendRoutineCard(
                conversationId: conversationId,
                coachId: coachService.coachFirestoreID,
                coachName: resolvedCoachName,
                userId: connection.clientUserID,
                userName: resolvedClientName,
                template: template,
                coachNote: note.isEmpty ? nil : note
            )
            await MainActor.run {
                isSending = false
                if success {
                    dismiss()
                } else {
                    sendError = "Please try again."
                }
            }
        }
    }
}
