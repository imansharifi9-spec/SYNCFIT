import SwiftUI

struct EditProfileSheet: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dataStore: FitnessDataStore
    @EnvironmentObject private var firestore: FirestoreDatabaseManager
    @Environment(\.dismiss) private var dismiss

    @State private var draft: UserProfile
    @State private var heightFeet: Int
    @State private var heightInches: Int
    @State private var heightCmInput: Double
    @State private var weightLbsInput: Double
    @State private var weightKgInput: Double
    @State private var showingCaloriePlanner = false
    @State private var initialBodyWeightLbs: Double

    init(profile: UserProfile) {
        _draft = State(initialValue: profile)
        _heightFeet = State(initialValue: profile.heightFeet)
        _heightInches = State(initialValue: profile.heightInches)
        _heightCmInput = State(initialValue: profile.heightCm)
        _weightLbsInput = State(initialValue: profile.bodyWeightLbs)
        _weightKgInput = State(initialValue: profile.bodyWeightKg)
        _initialBodyWeightLbs = State(initialValue: SyncFitFormat.round(profile.bodyWeightLbs))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("About You") {
                    TextField("Name", text: $draft.name)
                    Picker("Gender", selection: $draft.gender) {
                        ForEach(Gender.allCases) { gender in
                            Text(gender.rawValue).tag(gender)
                        }
                    }
                    DatePicker("Birthday", selection: $draft.birthday, in: ...Date.now, displayedComponents: .date)
                    LabeledContent("Age", value: "\(draft.age) years")
                }

                Section("Measurements") {
                    Picker("Units", selection: $draft.measurementSystem) {
                        ForEach(MeasurementSystem.allCases) { system in
                            Text(system.rawValue).tag(system)
                        }
                    }
                    .onChange(of: draft.measurementSystem) { _, _ in
                        syncInputsFromDraft()
                    }

                    if draft.measurementSystem == .imperial {
                        HStack {
                            Text("Height")
                            Spacer()
                            TextField("ft", value: $heightFeet, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 36)
                            Text("ft")
                                .foregroundStyle(.secondary)
                            TextField("in", value: $heightInches, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 36)
                            Text("in")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Weight")
                            Spacer()
                            TextField("lbs", value: $weightLbsInput, format: .number.precision(.fractionLength(0...3)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                            Text("lb")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack {
                            Text("Height")
                            Spacer()
                            TextField("cm", value: $heightCmInput, format: .number.precision(.fractionLength(0...3)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                            Text("cm")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Weight")
                            Spacer()
                            TextField("kg", value: $weightKgInput, format: .number.precision(.fractionLength(0...3)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                            Text("kg")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Training") {
                    Picker("Goal", selection: $draft.goal) {
                        ForEach(FitnessGoal.allCases) { goal in
                            Text(goal.rawValue).tag(goal)
                        }
                    }
                    Picker("Experience", selection: $draft.experienceLevel) {
                        ForEach(ExperienceLevel.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    Picker("Activity Level", selection: $draft.activityLevel) {
                        ForEach(ActivityLevel.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    Text(draft.activityLevel.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Daily Targets") {
                    LabeledContent("Calories", value: "\(draft.calorieTarget)")
                    LabeledContent("Protein", value: "\(draft.proteinTarget)g")
                    LabeledContent("Carbs", value: "\(draft.carbTarget)g")
                    LabeledContent("Fat", value: "\(draft.fatTarget)g")

                    Button("Recalculate Calories") {
                        syncBodyStatsToDraft()
                        showingCaloriePlanner = true
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        syncBodyStatsToDraft()
                        appState.updateProfile(draft)
                        let updatedLbs = SyncFitFormat.round(draft.bodyWeightLbs)
                        if abs(updatedLbs - initialBodyWeightLbs) > 0.05 {
                            dataStore.syncProfileBodyWeight(draft)
                        }
                        Task {
                            try? await firestore.saveUserProfile(
                                draft,
                                hasCompletedOnboarding: appState.hasCompletedOnboarding
                            )
                        }
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingCaloriePlanner) {
                NavigationStack {
                    ScrollView {
                        CalorieTargetPlannerView(profile: $draft)
                            .padding()
                    }
                    .background(SyncFitTheme.background)
                    .navigationTitle("Calorie Plan")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingCaloriePlanner = false }
                        }
                    }
                }
            }
            .onAppear {
                syncInputsFromDraft()
            }
        }
    }

    private func syncInputsFromDraft() {
        heightFeet = draft.heightFeet
        heightInches = draft.heightInches
        heightCmInput = draft.heightCm
        weightLbsInput = draft.bodyWeightLbs
        weightKgInput = draft.bodyWeightKg
    }

    private func syncBodyStatsToDraft() {
        if draft.measurementSystem == .imperial {
            draft.setHeight(feet: max(heightFeet, 0), inches: min(max(heightInches, 0), 11))
            draft.setBodyWeight(lbs: SyncFitFormat.round(max(weightLbsInput, 0)))
        } else {
            draft.heightCm = SyncFitFormat.round(max(heightCmInput, 0))
            draft.bodyWeightKg = SyncFitFormat.round(max(weightKgInput, 0))
        }
    }
}
