import SwiftUI

private enum OnboardingPrimaryGoal: String, CaseIterable, Identifiable {
    case loseWeight = "Lose Weight"
    case maintain = "Maintain"
    case buildMuscle = "Build Muscle"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .loseWeight: return "Burn fat while keeping strength"
        case .maintain: return "Stay at your current weight"
        case .buildMuscle: return "Add size with smart nutrition"
        }
    }

    var icon: String {
        switch self {
        case .loseWeight: return "flame.fill"
        case .maintain: return "equal.circle.fill"
        case .buildMuscle: return "figure.strengthtraining.traditional"
        }
    }

    var fitnessGoal: FitnessGoal {
        switch self {
        case .loseWeight: return .loseFat
        case .maintain: return .healthyLifestyle
        case .buildMuscle: return .buildMuscle
        }
    }

    static func from(_ goal: FitnessGoal) -> OnboardingPrimaryGoal {
        switch goal {
        case .loseFat: return .loseWeight
        case .buildMuscle: return .buildMuscle
        default: return .maintain
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var firestore: FirestoreDatabaseManager
    @State private var step = 0
    @State private var draft = UserProfile()
    @State private var selectedCalorieOptionID: String?
    @State private var heightFeet = 5
    @State private var heightInches = 9
    @State private var heightCmInput = 175.0
    @State private var weightLbsInput = 165.0
    @State private var weightKgInput = 75.0

    private let totalSteps = 10

    var body: some View {
        VStack(spacing: 0) {
            onboardingChrome

            Group {
                switch step {
                case 0: nameStep
                case 1: birthdayStep
                case 2: genderStep
                case 3: bodyStatsStep
                case 4: goalStep
                case 5: paceStep
                case 6: activityStep
                case 7: experienceStep
                case 8: coachStep
                default: summaryStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            .id(step)

            onboardingFooter
        }
        .background(SyncFitTheme.background.ignoresSafeArea())
        // onAppear / step changes only mutate the local draft UI state — never AppState,
        // Firestore, or routines. Persistence happens only in completeOnboarding().
        .onAppear { loadBodyStatsFromDraft() }
        .onChange(of: draft.measurementSystem) { _, _ in loadBodyStatsFromDraft() }
        .onChange(of: step) { _, newStep in
            if newStep == 5 { preparePaceSelection() }
            if newStep == 9 { refreshCalculatedTargets() }
        }
    }

    // MARK: - Chrome

    private var onboardingChrome: some View {
        VStack(spacing: 16) {
            HStack {
                if step > 0 {
                    Button {
                        withAnimation { step -= 1 }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 40)
                            .background(SyncFitTheme.card)
                            .clipShape(Circle())
                    }
                } else {
                    Color.clear.frame(width: 40, height: 40)
                }

                Spacer()

                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Step \(step + 1) of \(totalSteps)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SyncFitTheme.accent)
                    Spacer()
                    Text("\(Int((Double(step + 1) / Double(totalSteps) * 100).rounded()))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(SyncFitTheme.accent.opacity(0.15))
                        Capsule()
                            .fill(SyncFitTheme.accent)
                            .frame(width: geo.size.width * CGFloat(step + 1) / CGFloat(totalSteps))
                            .animation(.easeInOut(duration: 0.28), value: step)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var onboardingFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                if step == totalSteps - 1 {
                    completeOnboarding()
                } else {
                    advanceStep()
                }
            } label: {
                Text(step == totalSteps - 1 ? "Looks good, let's go!" : "Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canContinue)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
        .background(SyncFitTheme.background)
    }

    // MARK: - Steps

    private var nameStep: some View {
        onboardingScreen(
            title: "What's your name?",
            subtitle: "We'll use this to personalize your experience."
        ) {
            TextField("Your name", text: $draft.name)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .padding(.vertical, 20)
                .padding(.horizontal, 16)
                .background(SyncFitTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var birthdayStep: some View {
        onboardingScreen(
            title: "When's your birthday?",
            subtitle: "Age helps us calculate accurate calorie needs."
        ) {
            VStack(spacing: 16) {
                Text("\(draft.age)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(SyncFitTheme.accent)
                Text("years old")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)

                DatePicker(
                    "Birthday",
                    selection: $draft.birthday,
                    in: ...Date.now,
                    displayedComponents: .date
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxHeight: 180)
            }
            .padding(20)
            .background(SyncFitTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var genderStep: some View {
        onboardingScreen(
            title: "How do you identify?",
            subtitle: "Used for metabolic calculations."
        ) {
            VStack(spacing: 12) {
                ForEach(Gender.allCases) { gender in
                    onboardingOption(
                        title: gender.rawValue,
                        isSelected: draft.gender == gender
                    ) {
                        draft.gender = gender
                    }
                }
            }
        }
    }

    private var bodyStatsStep: some View {
        onboardingScreen(
            title: "Height & weight",
            subtitle: "We'll keep this private and use it for your targets."
        ) {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    ForEach(MeasurementSystem.allCases) { system in
                        let isSelected = draft.measurementSystem == system
                        Button {
                            draft.measurementSystem = system
                        } label: {
                            Text(system == .imperial ? "Imperial" : "Metric")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(isSelected ? SyncFitTheme.accent : SyncFitTheme.card)
                                .foregroundStyle(isSelected ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if draft.measurementSystem == .imperial {
                    measurementField(title: "Height") {
                        HStack(spacing: 8) {
                            TextField("ft", value: $heightFeet, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 44)
                            Text("ft").foregroundStyle(.secondary)
                            TextField("in", value: $heightInches, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 44)
                            Text("in").foregroundStyle(.secondary)
                        }
                    }
                    measurementField(title: "Weight") {
                        HStack(spacing: 8) {
                            TextField("lbs", value: $weightLbsInput, format: .number.precision(.fractionLength(0...1)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("lb").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    measurementField(title: "Height") {
                        HStack(spacing: 8) {
                            TextField("cm", value: $heightCmInput, format: .number.precision(.fractionLength(0...1)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("cm").foregroundStyle(.secondary)
                        }
                    }
                    measurementField(title: "Weight") {
                        HStack(spacing: 8) {
                            TextField("kg", value: $weightKgInput, format: .number.precision(.fractionLength(0...1)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("kg").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var goalStep: some View {
        onboardingScreen(
            title: "What's your goal?",
            subtitle: "We'll build your plan around this."
        ) {
            VStack(spacing: 12) {
                ForEach(OnboardingPrimaryGoal.allCases) { goal in
                    onboardingOption(
                        title: goal.rawValue,
                        subtitle: goal.subtitle,
                        icon: goal.icon,
                        isSelected: OnboardingPrimaryGoal.from(draft.goal) == goal
                    ) {
                        draft.goal = goal.fitnessGoal
                    }
                }
            }
        }
    }

    private var paceStep: some View {
        onboardingScreen(
            title: paceStepTitle,
            subtitle: paceStepSubtitle
        ) {
            VStack(spacing: 12) {
                ForEach(paceOptions) { option in
                    onboardingOption(
                        title: option.title,
                        subtitle: "\(option.calories) cal/day · \(option.detail)",
                        isSelected: selectedCalorieOptionID == option.id
                    ) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            selectedCalorieOptionID = option.id
                            draft.applyMacroTargets(calories: option.calories)
                        }
                    }
                }
            }
        }
        .onAppear { preparePaceSelection() }
    }

    private var activityStep: some View {
        onboardingScreen(
            title: "How active are you?",
            subtitle: "Outside of planned workouts."
        ) {
            VStack(spacing: 12) {
                ForEach(ActivityLevel.allCases) { level in
                    onboardingOption(
                        title: level.rawValue,
                        subtitle: level.detail,
                        isSelected: draft.activityLevel == level
                    ) {
                        draft.activityLevel = level
                    }
                }
            }
        }
    }

    private var experienceStep: some View {
        onboardingScreen(
            title: "Training experience",
            subtitle: "Helps us suggest the right starting point."
        ) {
            VStack(spacing: 12) {
                ForEach(ExperienceLevel.allCases) { level in
                    onboardingOption(
                        title: level.rawValue,
                        subtitle: experienceSubtitle(for: level),
                        isSelected: draft.experienceLevel == level
                    ) {
                        draft.experienceLevel = level
                    }
                }
            }
        }
    }

    private var coachStep: some View {
        onboardingScreen(
            title: "Working with a coach?",
            subtitle: "You can connect with coaches anytime in the app."
        ) {
            VStack(spacing: 12) {
                onboardingOption(
                    title: "On my own",
                    subtitle: "I'll train solo for now",
                    icon: "person.fill",
                    isSelected: !draft.hasCoach
                ) {
                    draft.hasCoach = false
                }
                onboardingOption(
                    title: "I have a coach",
                    subtitle: "Or I'm looking for one",
                    icon: "person.2.fill",
                    isSelected: draft.hasCoach
                ) {
                    draft.hasCoach = true
                }
            }
        }
    }

    private var summaryStep: some View {
        onboardingScreen(
            title: "Your daily targets",
            subtitle: "Calculated with Mifflin–St Jeor from your profile."
        ) {
            VStack(spacing: 12) {
                summaryMacroCard(
                    label: "Daily Calories",
                    value: "\(draft.calorieTarget)",
                    unit: "cal",
                    accent: SyncFitTheme.accent
                )
                HStack(spacing: 12) {
                    summaryMacroCard(label: "Protein", value: "\(draft.proteinTarget)", unit: "g", accent: SyncFitTheme.protein)
                    summaryMacroCard(label: "Carbs", value: "\(draft.carbTarget)", unit: "g", accent: SyncFitTheme.carbs)
                    summaryMacroCard(label: "Fat", value: "\(draft.fatTarget)", unit: "g", accent: SyncFitTheme.fat)
                }
                Text("Adjust anytime in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .onAppear { refreshCalculatedTargets() }
    }

    // MARK: - Helpers

    private var paceStepTitle: String {
        switch draft.goal {
        case .loseFat: return "How fast do you want to lose?"
        case .buildMuscle: return "How fast do you want to gain?"
        default: return "Your weekly pace"
        }
    }

    private var paceStepSubtitle: String {
        switch draft.goal {
        case .loseFat: return "Sustainable pace wins long term."
        case .buildMuscle: return "Lean gains take patience."
        default: return "We'll keep you at maintenance calories."
        }
    }

    private var paceOptions: [CalorieCalculator.PaceOption] {
        let all = CalorieCalculator.calculate(for: draft).options
        switch draft.goal {
        case .loseFat:
            return all.filter { $0.id.hasPrefix("loss-") }
        case .buildMuscle:
            return all.filter { $0.id.hasPrefix("gain-") }
        default:
            return all.filter(\.isMaintenance)
        }
    }

    private var canContinue: Bool {
        switch step {
        case 0:
            return !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 3:
            syncBodyStatsToDraft()
            if draft.measurementSystem == .imperial {
                return weightLbsInput > 0 && (heightFeet > 0 || heightInches > 0)
            }
            return weightKgInput > 0 && heightCmInput > 0
        case 5:
            return selectedCalorieOptionID != nil
        default:
            return true
        }
    }

    private func experienceSubtitle(for level: ExperienceLevel) -> String {
        switch level {
        case .beginner: return "New to structured training"
        case .intermediate: return "1–3 years of consistent lifting"
        case .advanced: return "3+ years, comfortable with periodization"
        }
    }

    private func preparePaceSelection() {
        syncBodyStatsToDraft()
        switch draft.goal {
        case .loseFat:
            let defaultID = "loss-moderate"
            selectedCalorieOptionID = selectedCalorieOptionID?.hasPrefix("loss-") == true
                ? selectedCalorieOptionID
                : defaultID
        case .buildMuscle:
            let defaultID = "gain-slow"
            selectedCalorieOptionID = selectedCalorieOptionID?.hasPrefix("gain-") == true
                ? selectedCalorieOptionID
                : defaultID
        default:
            selectedCalorieOptionID = "maintenance"
        }
        CalorieCalculator.applyRecommendedTargets(to: &draft, selectedOptionID: selectedCalorieOptionID)
    }

    private func refreshCalculatedTargets() {
        syncBodyStatsToDraft()
        CalorieCalculator.applyRecommendedTargets(to: &draft, selectedOptionID: selectedCalorieOptionID)
    }

    private func advanceStep() {
        if step == 3 { syncBodyStatsToDraft() }
        if step == 4 { preparePaceSelection() }
        withAnimation { step += 1 }
    }

    private func completeOnboarding() {
        refreshCalculatedTargets()
        // Explicit user action only — never called from onAppear / render.
        appState.completeOnboarding(with: draft)
        Task {
            do {
                try await firestore.saveUserProfile(
                    draft,
                    hasCompletedOnboarding: true,
                    hasCompletedProgramSetup: false
                )
            } catch {
                print("[Onboarding] Failed to save profile for authenticated user: \(error)")
            }
        }
    }

    private func loadBodyStatsFromDraft() {
        heightFeet = draft.heightFeet
        heightInches = draft.heightInches
        heightCmInput = SyncFitFormat.round(draft.heightCm, places: 1)
        weightLbsInput = SyncFitFormat.round(draft.bodyWeightLbs, places: 1)
        weightKgInput = SyncFitFormat.round(draft.bodyWeightKg, places: 1)
    }

    private func syncBodyStatsToDraft() {
        if draft.measurementSystem == .imperial {
            draft.setHeight(feet: max(heightFeet, 0), inches: min(max(heightInches, 0), 11))
            draft.setBodyWeight(lbs: SyncFitFormat.round(max(weightLbsInput, 0), places: 1))
            weightLbsInput = SyncFitFormat.round(draft.bodyWeightLbs, places: 1)
        } else {
            draft.heightCm = SyncFitFormat.round(max(heightCmInput, 0), places: 1)
            draft.bodyWeightKg = SyncFitFormat.round(max(weightKgInput, 0), places: 1)
            weightKgInput = SyncFitFormat.round(draft.bodyWeightKg, places: 1)
        }
    }

    // MARK: - Components

    private func onboardingScreen<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                content()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func onboardingOption(
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let icon {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(isSelected ? SyncFitTheme.accent : .secondary)
                        .frame(width: 28)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? SyncFitTheme.accent : Color(.tertiaryLabel))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? SyncFitTheme.accent.opacity(0.12) : SyncFitTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? SyncFitTheme.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private func measurementField<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
                .font(.body.weight(.semibold))
            Spacer()
            content()
                .font(.title3.weight(.semibold))
        }
        .padding(18)
        .background(SyncFitTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func summaryMacroCard(label: String, value: String, unit: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: label == "Daily Calories" ? 36 : 24, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                Text(unit)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(SyncFitTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AppState.preview())
        .environmentObject(FirestoreDatabaseManager())
}
