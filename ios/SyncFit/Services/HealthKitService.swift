import Foundation
import HealthKit

enum AppleHealthConnectionStatus: Equatable {
    case unavailable
    case notConnected
    case connected
    case denied
}

@MainActor
final class HealthKitService: ObservableObject {
    @Published private(set) var connectionStatus: AppleHealthConnectionStatus = .notConnected
    @Published private(set) var todaysSteps: Int?
    @Published private(set) var todaysActiveCalories: Int?
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var isSyncing = false
    @Published var statusMessage: String?

    private let store = HKHealthStore()
    private static let entryMetadataKey = "com.syncfit.entryID"
    private static let syncedEntriesDefaultsKey = "healthKitSyncedEntryIDs"

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        types.insert(HKObjectType.workoutType())
        for identifier in [
            HKQuantityTypeIdentifier.bodyMass,
            .activeEnergyBurned,
            .stepCount,
            .dietaryEnergyConsumed,
            .dietaryProtein,
            .dietaryCarbohydrates,
            .dietaryFatTotal
        ] {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        return types
    }

    private var writeTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>()
        types.insert(HKObjectType.workoutType())
        for identifier in [
            HKQuantityTypeIdentifier.bodyMass,
            .activeEnergyBurned,
            .dietaryEnergyConsumed,
            .dietaryProtein,
            .dietaryCarbohydrates,
            .dietaryFatTotal
        ] {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        return types
    }

    func refreshConnectionStatus(isEnabled: Bool) {
        guard isAvailable else {
            connectionStatus = .unavailable
            return
        }

        guard isEnabled else {
            connectionStatus = .notConnected
            return
        }

        if hasWriteAuthorization {
            connectionStatus = .connected
        } else {
            connectionStatus = .denied
        }
    }

    func connect(dataStore: FitnessDataStore) async {
        guard isAvailable else {
            connectionStatus = .unavailable
            statusMessage = "Apple Health isn't available on this device."
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            try await requestAuthorization()
            refreshConnectionStatus(isEnabled: true)

            guard connectionStatus == .connected else {
                statusMessage = "Apple Health access wasn't granted. Enable it in Settings → Health → Data Access."
                return
            }

            let imported = await importRecentWeight(into: dataStore)
            await syncAllExistingData(dataStore: dataStore)
            await refreshTodayActivity()
            lastSyncDate = .now

            if imported > 0 {
                statusMessage = "Connected. Imported \(imported) weight \(imported == 1 ? "entry" : "entries") from Apple Health."
            } else {
                statusMessage = "Connected to Apple Health."
            }
        } catch {
            connectionStatus = .denied
            statusMessage = error.localizedDescription
        }
    }

    func disconnect() {
        connectionStatus = .notConnected
        todaysSteps = nil
        todaysActiveCalories = nil
        statusMessage = "Apple Health sync turned off."
    }

    func syncNow(dataStore: FitnessDataStore) async {
        guard connectionStatus == .connected else { return }

        isSyncing = true
        defer { isSyncing = false }

        await syncAllExistingData(dataStore: dataStore)
        await refreshTodayActivity()
        lastSyncDate = .now
        statusMessage = "Synced with Apple Health."
    }

    func syncFood(_ entry: FoodEntry) async {
        guard connectionStatus == .connected, !isSynced(entry.id) else { return }

        let metadata = entryMetadata(for: entry.id)
        let start = entry.date
        let end = start.addingTimeInterval(60)

        var samples: [HKQuantitySample] = []

        if entry.calories > 0,
           let type = HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed) {
            samples.append(
                HKQuantitySample(
                    type: type,
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: Double(entry.calories)),
                    start: start,
                    end: end,
                    metadata: metadata
                )
            )
        }

        if entry.protein > 0,
           let type = HKQuantityType.quantityType(forIdentifier: .dietaryProtein) {
            samples.append(
                HKQuantitySample(
                    type: type,
                    quantity: HKQuantity(unit: .gram(), doubleValue: Double(entry.protein)),
                    start: start,
                    end: end,
                    metadata: metadata
                )
            )
        }

        if entry.carbs > 0,
           let type = HKQuantityType.quantityType(forIdentifier: .dietaryCarbohydrates) {
            samples.append(
                HKQuantitySample(
                    type: type,
                    quantity: HKQuantity(unit: .gram(), doubleValue: Double(entry.carbs)),
                    start: start,
                    end: end,
                    metadata: metadata
                )
            )
        }

        if entry.fat > 0,
           let type = HKQuantityType.quantityType(forIdentifier: .dietaryFatTotal) {
            samples.append(
                HKQuantitySample(
                    type: type,
                    quantity: HKQuantity(unit: .gram(), doubleValue: Double(entry.fat)),
                    start: start,
                    end: end,
                    metadata: metadata
                )
            )
        }

        guard !samples.isEmpty else { return }

        do {
            try await save(samples)
            markSynced(entry.id)
            lastSyncDate = .now
        } catch {
            statusMessage = "Couldn't save nutrition to Apple Health."
        }
    }

    func syncWeight(_ entry: WeightEntry) async {
        guard connectionStatus == .connected, !isSynced(entry.id) else { return }
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return }

        let kilograms = entry.weight * 0.45359237
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kilograms),
            start: entry.date,
            end: entry.date,
            metadata: entryMetadata(for: entry.id)
        )

        do {
            try await save([sample])
            markSynced(entry.id)
            lastSyncDate = .now
        } catch {
            statusMessage = "Couldn't save weight to Apple Health."
        }
    }

    func syncWorkoutSession(_ result: WorkoutSessionResult, on date: Date) async {
        guard connectionStatus == .connected else { return }

        let syncID = workoutDaySyncID(for: date)
        guard !isSyncedString(syncID) else { return }

        let end = Date()
        let start = end.addingTimeInterval(-Double(result.durationMinutes * 60))
        let energy = HKQuantity(unit: .kilocalorie(), doubleValue: Double(result.estimatedCaloriesBurned))

        var metadata = entryMetadata(for: result.id)
        metadata[HKMetadataKeyWorkoutBrandName] = "SyncFit"
        metadata["sessionName"] = result.sessionName

        let workout = HKWorkout(
            activityType: .traditionalStrengthTraining,
            start: start,
            end: end,
            workoutEvents: nil,
            totalEnergyBurned: energy,
            totalDistance: nil,
            metadata: metadata
        )

        do {
            try await save([workout])
            markSyncedString(syncID)
            lastSyncDate = .now
        } catch {
            statusMessage = "Couldn't save workout to Apple Health."
        }
    }

    func syncDayWorkout(on date: Date, dataStore: FitnessDataStore) async {
        guard connectionStatus == .connected else { return }

        let syncID = workoutDaySyncID(for: date)
        guard !isSyncedString(syncID) else { return }

        let dayWorkouts = dataStore.workouts(on: date)
        guard !dayWorkouts.isEmpty else { return }

        let minutes = max(dataStore.estimatedWorkoutMinutes(on: date), 1)
        let calories = max(minutes * 8, 120)
        let sessionName = dataStore.sessionName(for: date) ?? "Strength Training"
        let dayStart = Calendar.current.startOfDay(for: date)
        let end = dayStart.addingTimeInterval(Double(minutes * 60))
        let energy = HKQuantity(unit: .kilocalorie(), doubleValue: Double(calories))

        var metadata = entryMetadata(for: UUID())
        metadata[HKMetadataKeyWorkoutBrandName] = "SyncFit"
        metadata["sessionName"] = sessionName

        let workout = HKWorkout(
            activityType: .traditionalStrengthTraining,
            start: dayStart,
            end: end,
            workoutEvents: nil,
            totalEnergyBurned: energy,
            totalDistance: nil,
            metadata: metadata
        )

        do {
            try await save([workout])
            markSyncedString(syncID)
            lastSyncDate = .now
        } catch {
            statusMessage = "Couldn't save workout to Apple Health."
        }
    }

    func importRecentWeight(into dataStore: FitnessDataStore) async -> Int {
        guard connectionStatus == .connected,
              let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return 0 }

        let start = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        let samples: [HKQuantitySample]
        do {
            samples = try await fetchQuantitySamples(type: type, predicate: predicate, sortDescriptors: [sort])
        } catch {
            return 0
        }

        let calendar = Calendar.current
        var imported = 0

        for sample in samples {
            let pounds = sample.quantity.doubleValue(for: .gramUnit(with: .kilo)) / 0.45359237
            let sampleDay = calendar.startOfDay(for: sample.startDate)

            let alreadyLogged = dataStore.weights.contains {
                calendar.isDate($0.date, inSameDayAs: sampleDay)
            }
            guard !alreadyLogged else { continue }

            dataStore.addWeight(
                WeightEntry(weight: SyncFitFormat.round(pounds), date: sample.startDate),
                skipHealthSync: true
            )
            markSyncedString(sample.uuid.uuidString)
            imported += 1
        }

        return imported
    }

    func refreshTodayActivity() async {
        guard connectionStatus == .connected else {
            todaysSteps = nil
            todaysActiveCalories = nil
            return
        }

        let start = Calendar.current.startOfDay(for: .now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now, options: .strictStartDate)

        if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            todaysSteps = Int(await sumQuantity(type: stepType, predicate: predicate, unit: .count()))
        }

        if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            let total = await sumQuantity(type: energyType, predicate: predicate, unit: .kilocalorie())
            todaysActiveCalories = Int(total.rounded())
        }
    }

    func syncAllExistingData(dataStore: FitnessDataStore) async {
        guard connectionStatus == .connected else { return }

        for entry in dataStore.weights {
            await syncWeight(entry)
        }

        for entry in dataStore.foods {
            await syncFood(entry)
        }

        let workoutDays = Set(dataStore.workouts.map { Calendar.current.startOfDay(for: $0.date) })
        for day in workoutDays {
            await syncDayWorkout(on: day, dataStore: dataStore)
        }
    }

    // MARK: - Private

    private var hasWriteAuthorization: Bool {
        guard let bodyMass = HKObjectType.quantityType(forIdentifier: .bodyMass) else { return false }
        return store.authorizationStatus(for: bodyMass) == .sharingAuthorized
    }

    private func requestAuthorization() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: writeTypes, read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitServiceError.authorizationDenied)
                }
            }
        }
    }

    private func save(_ samples: [HKSample]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.save(samples) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitServiceError.saveFailed)
                }
            }
        }
    }

    private func fetchQuantitySamples(
        type: HKQuantityType,
        predicate: NSPredicate,
        sortDescriptors: [NSSortDescriptor]
    ) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sortDescriptors
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
                }
            }
            store.execute(query)
        }
    }

    private func sumQuantity(type: HKQuantityType, predicate: NSPredicate, unit: HKUnit) async -> Double {
        await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in
                let value = statistics?.sumQuantity()?.doubleValue(for: unit) ?? 0
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func entryMetadata(for id: UUID) -> [String: Any] {
        [Self.entryMetadataKey: id.uuidString]
    }

    private func workoutDaySyncID(for date: Date) -> String {
        let day = Calendar.current.startOfDay(for: date)
        return "workout-day-\(day.timeIntervalSince1970)"
    }

    private func isSynced(_ id: UUID) -> Bool {
        isSyncedString(id.uuidString)
    }

    private func isSyncedString(_ key: String) -> Bool {
        syncedEntryIDs.contains(key)
    }

    private func markSynced(_ id: UUID) {
        markSyncedString(id.uuidString)
    }

    private func markSyncedString(_ key: String) {
        var entries = syncedEntryIDs
        entries.insert(key)
        syncedEntryIDs = entries
    }

    private var syncedEntryIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.syncedEntriesDefaultsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.syncedEntriesDefaultsKey) }
    }

    static func preview() -> HealthKitService {
        HealthKitService()
    }
}

private enum HealthKitServiceError: LocalizedError {
    case authorizationDenied
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Apple Health access wasn't granted."
        case .saveFailed:
            return "Couldn't save data to Apple Health."
        }
    }
}
