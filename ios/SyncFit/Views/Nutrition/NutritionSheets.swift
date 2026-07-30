import SwiftUI

struct LogFoodSheet: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.dismiss) private var dismiss

    let logDate: Date

    @State private var searchText = ""
    @State private var selectedItem: FoodLibraryItem?
    @State private var selectionPulse = false
    @State private var amount = 6.0
    @State private var unit: LegacyFoodAmountUnit = .oz
    @State private var meal: MealType = .lunch

    @State private var name = ""
    @State private var calories = 0
    @State private var protein = 0
    @State private var carbs = 0
    @State private var fat = 0

    @State private var isSearchingUSDA = false
    @State private var isLoadingDetails = false
    @State private var usdaResults: [FoodLibraryItem] = []
    @State private var usdaError: String?
    @State private var usdaSearchTask: Task<Void, Never>?
    @State private var showingManualEntry = false

    init(logDate: Date = .now) {
        self.logDate = logDate
    }

    private var hasServingUnit: Bool {
        guard let grams = selectedItem?.servingGrams else { return false }
        return grams > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search foods", text: $searchText)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    }
                }

                if let selected = selectedItem {
                    Section {
                        SelectedFoodCard(
                            item: selected,
                            calories: calories,
                            protein: protein,
                            pulse: selectionPulse,
                            isLoadingDetails: isLoadingDetails,
                            onChange: clearSelection
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                    }

                    Section("How much?") {
                        EditableDoubleRow(
                            title: "Amount",
                            value: $amount,
                            range: 0.001...9_999,
                            step: 0.5
                        )

                        unitSegmentedPicker

                        if unit == .servings, let grams = selected.servingGrams {
                            Text("1 serving = \(formattedGrams(grams))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if unit == .oz {
                            Text("≈ \(formattedGrams(amount * 28.3495)) total")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        macroPreviewRow
                    }
                    .onChange(of: amount) { _, _ in recalcFromSelection() }
                    .onChange(of: unit) { _, _ in recalcFromSelection() }

                    Section("Log as") {
                        Picker("Meal", selection: $meal) {
                            ForEach(MealType.allCases) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                    }
                } else {
                    searchResultsSection

                    Section {
                        Button {
                            showingManualEntry = true
                        } label: {
                            Label("Enter food manually", systemImage: "square.and.pencil")
                        }
                    }
                }
            }
            .navigationTitle("Add Food")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSelectedFood()
                    }
                    .disabled(selectedItem == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showingManualEntry) {
                ManualFoodEntrySheet(logDate: logDate)
            }
        }
        .onChange(of: searchText) { _, _ in
            runUSDASearchIfNeeded()
        }
        .onAppear {
            runUSDASearchIfNeeded()
        }
    }

    private func saveSelectedFood() {
        let entry = FoodEntry(
            name: name,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            meal: meal,
            date: startOfDay(logDate)
        )
        dataStore.addFood(entry)
        dismiss()
    }

    private func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    @ViewBuilder
    private var unitSegmentedPicker: some View {
        if hasServingUnit {
            Picker("Unit", selection: $unit) {
                Text("oz").tag(LegacyFoodAmountUnit.oz)
                Text("g").tag(LegacyFoodAmountUnit.grams)
                Text("serving").tag(LegacyFoodAmountUnit.servings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else {
            Picker("Unit", selection: $unit) {
                Text("oz").tag(LegacyFoodAmountUnit.oz)
                Text("g").tag(LegacyFoodAmountUnit.grams)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var macroPreviewRow: some View {
        HStack(spacing: 16) {
            macroChip("\(calories)", label: "cal")
            macroChip("\(protein)g", label: "protein")
            macroChip("\(carbs)g", label: "carbs")
            macroChip("\(fat)g", label: "fat")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func macroChip(_ value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SyncFitTheme.accent)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        Section {
            if isRemoteSearchEnabled {
                if let usdaError {
                    Text(usdaError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isSearchingUSDA {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if activeResults.isEmpty, !isSearchingUSDA {
                Text(emptyResultsMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(activeResults) { item in
                    FoodSearchRow(
                        item: item,
                        subtitle: resultSubtitle(for: item),
                        isSelected: selectedItem?.id == item.id
                    ) {
                        selectFood(item)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
        } header: {
            if !activeResults.isEmpty || isSearchingUSDA {
                Text("Pick a food")
            }
        }
    }

    private var emptyResultsMessage: String {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Search the food database to get started."
        }
        return "No matches — try a different search or enter manually."
    }

    private var filteredItems: [FoodLibraryItem] {
        []
    }

    private var isRemoteSearchEnabled: Bool {
        AppConfig.isFoodSearchEnabled
    }

    private var activeResults: [FoodLibraryItem] {
        if isRemoteSearchEnabled {
            return usdaResults
        }
        return filteredItems
    }

    private func resultSubtitle(for item: FoodLibraryItem) -> String {
        var parts: [String] = []
        if item.isPerServing {
            parts.append("\(Int(item.calories)) cal per serving")
        } else {
            parts.append("\(Int(item.calories)) cal · \(Int(item.protein))g protein per 100g")
        }
        if let brand = item.brand?.trimmingCharacters(in: .whitespacesAndNewlines), !brand.isEmpty {
            parts.append(brand)
        }
        if let grams = item.servingGrams, grams > 0, !item.isPerServing {
            parts.append("serving ≈ \(formattedGrams(grams))")
        }
        return parts.joined(separator: " · ")
    }

    private func formattedGrams(_ grams: Double) -> String {
        let rounded = SyncFitFormat.round(grams)
        return rounded == 1 ? "1g" : "\(SyncFitFormat.decimal(rounded))g"
    }

    private func selectFood(_ item: FoodLibraryItem) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            selectedItem = item
            name = item.name
            if item.isPerServing || (item.servingGrams != nil && item.servingGrams! > 0) {
                unit = .servings
                amount = 1
            } else {
                unit = .oz
                amount = 6
            }
            recalcFromSelection()
            selectionPulse.toggle()
        }
        loadFoodDetailsIfNeeded(for: item)
    }

    private func loadFoodDetailsIfNeeded(for item: FoodLibraryItem) {
        guard !AppConfig.usdaApiKey.isEmpty, let fdcId = item.fdcId else { return }
        let selectedID = item.id

        Task { @MainActor in
            isLoadingDetails = true
            defer { isLoadingDetails = false }

            do {
                if let detailed = try await USDAFoodDataCentralService.fetchFood(
                    fdcId: fdcId,
                    apiKey: AppConfig.usdaApiKey
                ), selectedItem?.id == selectedID {
                    selectedItem = detailed
                    name = detailed.name
                    recalcFromSelection()
                }
            } catch {
                // Keep search result if detail fetch fails.
            }
        }
    }

    private func clearSelection() {
        withAnimation(.easeOut(duration: 0.2)) {
            selectedItem = nil
            name = ""
            calories = 0
            protein = 0
            carbs = 0
            fat = 0
        }
    }

    private func recalcFromSelection() {
        guard let item = selectedItem else { return }
        if unit == .servings, item.servingGrams == nil {
            unit = .oz
        }
        let grams = unit.toGrams(amount, servingGrams: item.servingGrams)
        guard grams > 0 else { return }
        let scaled = item.scaled(to: grams)
        calories = scaled.calories
        protein = scaled.protein
        carbs = scaled.carbs
        fat = scaled.fat
    }

    private func runUSDASearchIfNeeded() {
        guard isRemoteSearchEnabled else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            usdaResults = []
            usdaError = nil
            return
        }

        usdaSearchTask?.cancel()
        usdaSearchTask = Task { @MainActor in
            usdaError = nil
            isSearchingUSDA = true
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            do {
                let results = try await USDAFoodDataCentralService.searchFoods(
                    query: query,
                    apiKey: AppConfig.usdaApiKey,
                    pageSize: 40
                )
                usdaResults = refineUSDAResults(query: query, results: results)
            } catch {
                usdaResults = []
                usdaError = "Search failed. Check your connection and try again."
            }
            isSearchingUSDA = false
        }
    }

    private func refineUSDAResults(query: String, results: [FoodLibraryItem]) -> [FoodLibraryItem] {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }

        let isSingleTokenQuery = tokens.count == 1
        let token = tokens.first ?? ""

        let filtered = results.filter { item in
            guard item.calories > 0 else { return false }
            let name = item.name.lowercased()
            let brand = (item.brand ?? "").lowercased()
            guard name.count <= 72 else { return false }

            if tokens.isEmpty { return true }
            if isSingleTokenQuery {
                return name.contains(token) || brand.contains(token)
            }
            return tokens.allSatisfy { name.contains($0) }
        }

        var seen = Set<String>()
        let deduped = filtered.filter { item in
            let key = "\(item.name.lowercased())|\(item.brand?.lowercased() ?? "")"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }

        func score(_ item: FoodLibraryItem) -> Int {
            let name = item.name.lowercased()
            let brand = (item.brand ?? "").lowercased()
            var s = 0

            if isSingleTokenQuery {
                if brand.contains(token) { s += 150 }
                if name.hasPrefix(token) { s += 120 }
                if name.contains(token) { s += 80 }
                if item.isPerServing { s += 60 }
                if item.servingGrams != nil { s += 40 }
            } else {
                let joined = tokens.joined(separator: " ")
                if name.contains(joined) { s += 140 }
                if name.hasPrefix(joined) { s += 100 }
                s += tokens.reduce(0) { $0 + (name.contains($1) ? 30 : 0) }
                if (item.brand ?? "").isEmpty { s += 25 }
            }

            s -= min(name.count, 60) / 3
            return s
        }

        return deduped
            .sorted {
                let a = score($0)
                let b = score($1)
                if a != b { return a > b }
                return $0.name.count < $1.name.count
            }
            .prefix(12)
            .map { $0 }
    }
}

private struct FoodSearchRow: View {
    let item: FoodLibraryItem
    let subtitle: String
    let isSelected: Bool
    let onTap: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? SyncFitTheme.accent : Color(.tertiaryLabel))
                    .scaleEffect(isSelected ? 1.0 : 0.92)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? SyncFitTheme.accent.opacity(0.14) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? SyncFitTheme.accent : Color.clear,
                        lineWidth: isSelected ? 2 : 0
                    )
            )
            .scaleEffect(pressed ? 0.97 : 1)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.easeOut(duration: 0.12)) { pressed = true }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { pressed = false }
                }
        )
    }
}

private struct SelectedFoodCard: View {
    let item: FoodLibraryItem
    let calories: Int
    let protein: Int
    let pulse: Bool
    var isLoadingDetails = false
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(SyncFitTheme.accent)
                    .scaleEffect(pulse ? 1.15 : 1)
                    .animation(.spring(response: 0.35, dampingFraction: 0.55), value: pulse)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SyncFitTheme.accent)
                    Text(item.name)
                        .font(.headline)
                    if let brand = item.brand, !brand.isEmpty {
                        Text(brand)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if isLoadingDetails {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading nutrition…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button("Change", action: onChange)
                    .font(.subheadline.weight(.medium))
            }

            HStack(spacing: 20) {
                Label("\(calories) cal", systemImage: "flame.fill")
                Label("\(protein)g protein", systemImage: "bolt.fill")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(SyncFitTheme.accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(SyncFitTheme.accent.opacity(0.55), lineWidth: 2)
        )
        .transition(.asymmetric(
            insertion: .scale(scale: 0.94).combined(with: .opacity),
            removal: .opacity
        ))
    }
}

private enum LegacyFoodAmountUnit: String, CaseIterable, Identifiable {
    case oz
    case grams
    case servings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oz: return "oz"
        case .grams: return "g"
        case .servings: return "serv"
        }
    }

    func toGrams(_ value: Double, servingGrams: Double?) -> Double {
        switch self {
        case .oz: return value * 28.3495
        case .grams: return value
        case .servings: return value * (servingGrams ?? 0)
        }
    }
}

struct ManualFoodEntrySheet: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.dismiss) private var dismiss

    let logDate: Date
    var defaultMeal: MealType = .lunch
    var onLogged: (String) -> Void
    var onLogFailed: (String) -> Void

    @State private var name = ""
    @State private var calories = 0
    @State private var protein = 0
    @State private var carbs = 0
    @State private var fat = 0
    @State private var meal: MealType
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        logDate: Date = .now,
        defaultMeal: MealType = .lunch,
        onLogged: @escaping (String) -> Void = { _ in },
        onLogFailed: @escaping (String) -> Void = { _ in }
    ) {
        self.logDate = logDate
        self.defaultMeal = defaultMeal
        self.onLogged = onLogged
        self.onLogFailed = onLogFailed
        _meal = State(initialValue: defaultMeal)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                MacroEditorSection(
                    name: $name,
                    calories: $calories,
                    protein: $protein,
                    carbs: $carbs,
                    fat: $fat,
                    meal: $meal
                )

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(Color(red: 0.92, green: 0.45, blue: 0.42))
                            .accessibilityIdentifier("manualFoodLogError")
                    }
                }
            }
            .navigationTitle("Manual Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Logging…" : "Save") {
                        save()
                    }
                    .disabled(trimmedName.isEmpty || isSaving)
                }
            }
        }
    }

    private func save() {
        saveError = nil
        let entry = FoodEntry(
            name: trimmedName,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            meal: meal,
            date: Calendar.current.startOfDay(for: logDate)
        )
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await dataStore.addFoodAwaitingCloud(entry)
                onLogged(entry.name)
                dismiss()
            } catch {
                let message = error.localizedDescription
                saveError = message
                onLogFailed(message)
            }
        }
    }
}

struct EditFoodSheet: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.dismiss) private var dismiss

    let food: FoodEntry

    @State private var name: String
    @State private var calories: Int
    @State private var protein: Int
    @State private var carbs: Int
    @State private var fat: Int
    @State private var meal: MealType

    init(food: FoodEntry) {
        self.food = food
        _name = State(initialValue: food.name)
        _calories = State(initialValue: food.calories)
        _protein = State(initialValue: food.protein)
        _carbs = State(initialValue: food.carbs)
        _fat = State(initialValue: food.fat)
        _meal = State(initialValue: food.meal)
    }

    var body: some View {
        NavigationStack {
            Form {
                MacroEditorSection(
                    name: $name,
                    calories: $calories,
                    protein: $protein,
                    carbs: $carbs,
                    fat: $fat,
                    meal: $meal
                )
            }
            .navigationTitle("Edit Food")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", role: .destructive) {
                        dataStore.deleteFood(food)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let updated = FoodEntry(
                            id: food.id,
                            name: name.isEmpty ? "Custom Food" : name,
                            calories: calories,
                            protein: protein,
                            carbs: carbs,
                            fat: fat,
                            meal: meal,
                            date: food.date,
                            servingLabel: food.servingLabel
                        )
                        dataStore.updateFood(updated)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct SavedMealEditorSheet: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.dismiss) private var dismiss

    let existingMeal: SavedMeal?

    @State private var name: String
    @State private var calories: Int
    @State private var protein: Int
    @State private var carbs: Int
    @State private var fat: Int

    init(meal: SavedMeal? = nil) {
        self.existingMeal = meal
        _name = State(initialValue: meal?.name ?? "")
        // Totals are still persisted via a single MealComponent so logging /
        // list display (which sum components) keep working without ingredients UI.
        _calories = State(initialValue: meal?.totalCalories ?? 0)
        _protein = State(initialValue: meal?.totalProtein ?? 0)
        _carbs = State(initialValue: meal?.totalCarbs ?? 0)
        _fat = State(initialValue: meal?.totalFat ?? 0)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && calories > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Meal Name") {
                    TextField("e.g. Post-workout shake", text: $name)
                }

                Section("Meal Totals") {
                    mealTotalField(title: "Calories", value: $calories, suffix: "cal")
                    mealTotalField(title: "Protein", value: $protein, suffix: "g")
                    mealTotalField(title: "Carbs", value: $carbs, suffix: "g")
                    mealTotalField(title: "Fat", value: $fat, suffix: "g")
                }
            }
            .navigationTitle(existingMeal == nil ? "Create Meal" : "Edit Meal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard canSave else { return }

                        let meal = SavedMeal(
                            id: existingMeal?.id ?? UUID(),
                            name: trimmedName,
                            components: [
                                MealComponent(
                                    name: trimmedName,
                                    amount: "",
                                    calories: max(0, calories),
                                    protein: max(0, protein),
                                    carbs: max(0, carbs),
                                    fat: max(0, fat)
                                )
                            ]
                        )

                        if existingMeal == nil {
                            dataStore.addSavedMeal(meal)
                        } else {
                            dataStore.updateSavedMeal(meal)
                        }
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func mealTotalField(title: String, value: Binding<Int>, suffix: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 64)
            Text(suffix)
                .foregroundStyle(.secondary)
        }
    }
}

struct LogSavedMealSheet: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.dismiss) private var dismiss

    let meal: SavedMeal
    let logDate: Date
    var onLogged: (String) -> Void
    var onLogFailed: (String) -> Void

    @State private var mealType: MealType = .lunch
    @State private var isLogging = false
    @State private var logError: String?

    init(
        meal: SavedMeal,
        logDate: Date = .now,
        onLogged: @escaping (String) -> Void = { _ in },
        onLogFailed: @escaping (String) -> Void = { _ in }
    ) {
        self.meal = meal
        self.logDate = logDate
        self.onLogged = onLogged
        self.onLogFailed = onLogFailed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Meal") {
                    Text(meal.name)
                        .font(.headline)
                    // Only show a breakdown when the meal still has multiple
                    // ingredient rows (legacy ingredient-built meals).
                    if meal.components.count > 1 {
                        ForEach(meal.components) { component in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(component.amount.isEmpty ? component.name : "\(component.amount) \(component.name)")
                                Text("\(component.calories) cal · P \(component.protein)g")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Totals") {
                    LabeledContent("Calories", value: "\(meal.totalCalories)")
                    LabeledContent("Protein", value: "\(meal.totalProtein)g")
                    LabeledContent("Carbs", value: "\(meal.totalCarbs)g")
                    LabeledContent("Fat", value: "\(meal.totalFat)g")
                }

                Section("Log As") {
                    Picker("Meal", selection: $mealType) {
                        ForEach(MealType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                }

                if let logError {
                    Section {
                        Text(logError)
                            .font(.caption)
                            .foregroundStyle(Color(red: 0.92, green: 0.45, blue: 0.42))
                            .accessibilityIdentifier("logSavedMealError")
                    }
                }
            }
            .navigationTitle("Log Meal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isLogging)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isLogging ? "Logging…" : "Log") {
                        logMeal()
                    }
                    .disabled(isLogging)
                }
            }
        }
    }

    private func logMeal() {
        logError = nil
        isLogging = true
        Task { @MainActor in
            defer { isLogging = false }
            do {
                try await dataStore.logSavedMealAwaitingCloud(meal, as: mealType, on: logDate)
                onLogged(meal.name)
                dismiss()
            } catch {
                let message = error.localizedDescription
                logError = message
                onLogFailed(message)
            }
        }
    }
}

private struct MacroEditorSection: View {
    @Binding var name: String
    @Binding var calories: Int
    @Binding var protein: Int
    @Binding var carbs: Int
    @Binding var fat: Int
    @Binding var meal: MealType

    var body: some View {
        Section("Food") {
            TextField("Name", text: $name)
            Picker("Meal", selection: $meal) {
                ForEach(MealType.allCases) { meal in
                    Text(meal.rawValue).tag(meal)
                }
            }
        }
        Section("Macros") {
            EditableIntRow(title: "Calories", value: $calories, range: 0...5000, step: 10)
            EditableIntRow(title: "Protein", value: $protein, range: 0...500, suffix: "g")
            EditableIntRow(title: "Carbs", value: $carbs, range: 0...500, suffix: "g")
            EditableIntRow(title: "Fat", value: $fat, range: 0...300, suffix: "g")
        }
    }
}
