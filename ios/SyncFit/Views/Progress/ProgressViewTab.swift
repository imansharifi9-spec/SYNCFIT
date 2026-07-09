import SwiftUI

struct ProgressViewTab: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @EnvironmentObject private var appState: AppState

    @State private var timeRange: ProgressTimeRange = .oneMonth
    @State private var selectedLift: String?
    @State private var showingWeightSheet = false
    @State private var showingLiftPicker = false
    @State private var showingAllPRs = false
    @State private var showingPhotoGallery = false

    private var dataSource: ProgressDataSource {
        ProgressDataSource.current(dataStore: dataStore, profile: appState.profile)
    }

    private var activeLift: String? {
        selectedLift ?? ProgressAnalytics.defaultStrengthExercise(source: dataSource)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ProgressHeaderView(weeksTracked: ProgressAnalytics.weeksTracked(source: dataSource))

                    ProgressTimeFilter(selection: $timeRange)
                        .padding(.top, 16)

                    ProgressHeroStatsRow(
                        bodyWeight: ProgressAnalytics.bodyWeightStat(
                            source: dataSource,
                            range: timeRange
                        ),
                        volume: ProgressAnalytics.weeklyVolumeStat(
                            source: dataSource,
                            range: timeRange
                        ),
                        onLogWeight: { showingWeightSheet = true }
                    )

                    if let lift = activeLift {
                        ProgressStrengthCard(
                            chart: ProgressAnalytics.strengthChart(
                                exerciseName: lift,
                                source: dataSource,
                                range: timeRange
                            ),
                            onChangeLift: { showingLiftPicker = true }
                        )
                    } else {
                        ProgressStrengthCard(
                            chart: StrengthChartData(
                                exerciseName: "—",
                                points: [],
                                startCaption: nil,
                                endCaption: nil,
                                isEmpty: true,
                                showsTrendHint: false
                            ),
                            onChangeLift: { showingLiftPicker = true }
                        )
                    }

                    ProgressPersonalRecordsCard(
                        records: ProgressAnalytics.topPersonalRecords(source: dataSource),
                        onViewAll: { showingAllPRs = true }
                    )

                    ProgressPhotosCard(
                        photos: dataSource.progressPhotos,
                        onViewAll: { showingPhotoGallery = true }
                    )

                    ProgressConsistencyCard(
                        stats: ProgressAnalytics.consistencyStats(
                            source: dataSource,
                            range: timeRange
                        )
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(ProgressStyle.pageBackground)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingWeightSheet) {
                LogWeightSheet()
            }
            .sheet(isPresented: $showingLiftPicker) {
                ProgressLiftPickerSheet(
                    exercises: ProgressAnalytics.loggedExerciseNames(source: dataSource),
                    selection: $selectedLift
                )
            }
            .sheet(isPresented: $showingAllPRs) {
                AllPRsListView(records: ProgressAnalytics.allPersonalRecords(source: dataSource))
            }
            .sheet(isPresented: $showingPhotoGallery) {
                ProgressPhotoGalleryView(photos: dataSource.progressPhotos)
            }
        }
    }
}

private let bodyWeightRange: ClosedRange<Double> = 30...1000

struct LogWeightSheet: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var firestore: FirestoreDatabaseManager
    @Environment(\.dismiss) private var dismiss
    @State private var weight: Double

    init() {
        _weight = State(initialValue: 175)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                WorkoutNumpadDoubleRow(
                    title: "Today's weight",
                    value: $weight,
                    range: bodyWeightRange,
                    quickIncrements: [0.5, 1, 5]
                )
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Button("Save Weight") {
                    let rounded = min(
                        max(SyncFitFormat.round(weight), bodyWeightRange.lowerBound),
                        bodyWeightRange.upperBound
                    )
                    dataStore.addWeight(WeightEntry(weight: rounded))
                    var updated = appState.profile
                    updated.setBodyWeight(lbs: rounded)
                    appState.updateProfile(updated)
                    Task {
                        try? await firestore.saveUserProfile(
                            updated,
                            hasCompletedOnboarding: appState.hasCompletedOnboarding
                        )
                    }
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 20)

                Spacer()
            }
            .padding(.top, 12)
            .navigationTitle("Log Weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let latest = dataStore.weights.first {
                    weight = SyncFitFormat.round(latest.weight)
                } else {
                    weight = SyncFitFormat.round(appState.profile.bodyWeightLbs)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    ProgressViewTab()
        .environmentObject(FitnessDataStore.preview())
        .environmentObject(AppState.preview())
}
