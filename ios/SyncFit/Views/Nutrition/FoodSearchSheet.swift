import SwiftUI

enum FoodSearchTab: String, CaseIterable, Identifiable {
    case search = "Search results"
    case recent = "Recent"
    case myMeals = "My meals"

    var id: String { rawValue }
}

struct FoodSearchSheet: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.dismiss) private var dismiss

    let logDate: Date
    var scopedMeal: MealType?
    var onIngredientAdded: ((MealComponent) -> Void)?

    @State private var searchText = ""
    @State private var selectedTab: FoodSearchTab = .search
    @State private var selectedMeal: MealType
    @State private var navigationPath = NavigationPath()
    @State private var showingScanner = false
    @State private var showingManualEntry = false
    @State private var barcodeNotFound = false
    @State private var isSearching = false
    @State private var searchResults: [FoodLibraryItem] = []
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var editingSavedMeal: SavedMeal?
    @State private var loggingSavedMeal: SavedMeal?
    @State private var showingCreateMealSheet = false
    @FocusState private var searchFocused: Bool

    init(
        logDate: Date = .now,
        scopedMeal: MealType? = nil,
        onIngredientAdded: ((MealComponent) -> Void)? = nil
    ) {
        self.logDate = logDate
        self.scopedMeal = scopedMeal
        self.onIngredientAdded = onIngredientAdded
        _selectedMeal = State(initialValue: scopedMeal ?? MealType.contextualDefault())
    }

    private var isIngredientMode: Bool { onIngredientAdded != nil }

    private var sheetTitle: String {
        if isIngredientMode { return "Add Ingredient" }
        if let scopedMeal {
            return "Add to \(scopedMeal.sectionTitle)"
        }
        return "Log food"
    }

    private var searchTabs: [FoodSearchTab] {
        isIngredientMode ? [.search, .recent] : FoodSearchTab.allCases
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                searchBar
                tabPicker
                tabContent
            }
            .background(SyncFitTheme.background)
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .navigationDestination(for: FoodLibraryItem.self) { item in
                FoodPortionView(
                    item: item,
                    logDate: logDate,
                    selectedMeal: selectedMeal,
                    locksMeal: scopedMeal != nil || isIngredientMode,
                    onIngredientAdded: onIngredientAdded,
                    onLogged: { dismiss() }
                )
            }
            .fullScreenCover(isPresented: $showingScanner) {
                BarcodeScannerView(
                    onBarcode: { code in
                        showingScanner = false
                        lookupBarcode(code)
                    },
                    onCancel: { showingScanner = false }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingManualEntry) {
                ManualFoodEntrySheet(logDate: logDate, defaultMeal: selectedMeal)
            }
            .sheet(item: $editingSavedMeal) { meal in
                SavedMealEditorSheet(meal: meal)
            }
            .sheet(item: $loggingSavedMeal) { meal in
                LogSavedMealSheet(meal: meal, logDate: logDate)
            }
            .sheet(isPresented: $showingCreateMealSheet) {
                SavedMealEditorSheet()
            }
            .onAppear {
                if isIngredientMode {
                    selectedTab = .search
                } else if let scopedMeal {
                    selectedMeal = scopedMeal
                } else {
                    selectedMeal = MealType.contextualDefault()
                }
                runSearch()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    searchFocused = true
                }
            }
            .onChange(of: searchText) { _, _ in
                runSearch()
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search foods, meals, or scan barcode", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
            Button {
                showingScanner = true
            } label: {
                Image(systemName: "barcode.viewfinder")
                    .font(.title3)
                    .foregroundStyle(SyncFitTheme.accent)
            }
            .accessibilityLabel("Scan barcode")
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var tabPicker: some View {
        Picker("Tab", selection: $selectedTab) {
            ForEach(searchTabs) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .search:
            searchTabContent
        case .recent:
            recentTabContent
        case .myMeals:
            if isIngredientMode {
                searchTabContent
            } else {
                myMealsTabContent
            }
        }
    }

    private var searchTabContent: some View {
        List {
            if barcodeNotFound {
                Section {
                    Text("Food not found — search manually")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let searchError {
                Section {
                    Text(searchError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isSearching {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if searchResults.isEmpty, !isSearching {
                    emptySearchState
                } else {
                    ForEach(searchResults) { item in
                        NavigationLink(value: item) {
                            FoodSearchResultRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if searchResults.isEmpty, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    Button {
                        showingManualEntry = true
                    } label: {
                        Label("Enter food manually", systemImage: "square.and.pencil")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var recentTabContent: some View {
        List {
            let recent = dataStore.recentlyUsedFoods(limit: 10)
            if recent.isEmpty {
                Section {
                    Text("Foods you log will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(recent) { item in
                        NavigationLink(value: item) {
                            FoodSearchResultRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var myMealsTabContent: some View {
        List {
            if dataStore.savedMeals.isEmpty {
                Section {
                    Text("Save meals you eat often for one-tap logging.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(dataStore.savedMeals) { meal in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meal.name)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white)
                                Text("\(meal.totalCalories) cal · \(meal.totalProtein)g protein")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Log") {
                                loggingSavedMeal = meal
                            }
                            .font(.caption.weight(.semibold))
                            Menu {
                                Button("Edit") { editingSavedMeal = meal }
                                Button("Delete", role: .destructive) {
                                    dataStore.deleteSavedMeal(meal)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    showingCreateMealSheet = true
                } label: {
                    Label("Create meal", systemImage: "plus")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var emptySearchState: some View {
        VStack(spacing: 8) {
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
    }

    private var emptyMessage: String {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Search the food database to get started."
        }
        return "No matches — try a different search or enter manually."
    }

    private func runSearch() {
        barcodeNotFound = false
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        searchTask?.cancel()

        guard !query.isEmpty else {
            searchResults = []
            searchError = nil
            isSearching = false
            return
        }

        guard AppConfig.isFoodSearchEnabled else {
            searchResults = []
            searchError = "Food search is temporarily unavailable."
            isSearching = false
            return
        }

        searchTask = Task { @MainActor in
            isSearching = true
            searchError = nil
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            do {
                searchResults = try await USDAFoodDataCentralService.searchFoods(
                    query: query,
                    apiKey: AppConfig.usdaApiKey,
                    pageSize: 25
                )
            } catch {
                searchResults = []
                searchError = "Search failed. Check your connection."
            }
            isSearching = false
        }
    }

    private func lookupBarcode(_ code: String) {
        Task { @MainActor in
            isSearching = true
            barcodeNotFound = false
            defer { isSearching = false }

            if let off = try? await OpenFoodFactsService.lookupBarcode(code) {
                if let item = off.item {
                    navigationPath.append(item)
                    return
                }

                if let fallbackName = off.fallbackSearchName,
                   AppConfig.isFoodSearchEnabled,
                   let usdaMatch = try? await USDAFoodDataCentralService.searchFoods(
                       query: fallbackName,
                       apiKey: AppConfig.usdaApiKey,
                       pageSize: 8
                   ),
                   let item = usdaMatch.first {
                    navigationPath.append(item)
                    return
                }
            }

            barcodeNotFound = true
            selectedTab = .search
            searchText = code
            searchFocused = true
            runSearch()
        }
    }
}

private struct FoodSearchResultRow: View {
    let item: FoodLibraryItem

    var body: some View {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                    if let brand = item.brand, !brand.isEmpty, brand != "Recent" {
                        Text(brand)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(nutritionLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 136 / 255, green: 136 / 255, blue: 136 / 255))
                    .multilineTextAlignment(.trailing)
            }
    }

    private var nutritionLabel: String {
        let cal = Int(item.calories.rounded())
        let protein = Int(item.protein.rounded())
        if item.isPerServing {
            return "\(cal) cal · \(protein)g protein"
        }
        if cal > 0 {
            return "\(cal) cal · \(protein)g protein"
        }
        return "—"
    }
}
