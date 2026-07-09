import SwiftUI
import PhotosUI
import Charts

enum ProgressStyle {
    static let pageBackground = Color(red: 13 / 255, green: 13 / 255, blue: 13 / 255)
    static let cardBackground = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let cardBorder = Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
    static let heroBackground = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let segmentActive = Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255)
    static let segmentInactive = Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
    static let muted = Color(red: 136 / 255, green: 136 / 255, blue: 136 / 255)
    static let statLabel = Color(red: 68 / 255, green: 68 / 255, blue: 68 / 255)
    static let neutralDelta = Color(red: 85 / 255, green: 85 / 255, blue: 85 / 255)
    static let accentGreen = Color(red: 92 / 255, green: 219 / 255, blue: 110 / 255)
    static let barGreenDark = Color(red: 30 / 255, green: 58 / 255, blue: 34 / 255)
    static let proteinBlue = Color(red: 106 / 255, green: 171 / 255, blue: 238 / 255)
    static let track = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    static let unfavorable = Color(red: 235 / 255, green: 90 / 255, blue: 90 / 255)
    static let volumeNegative = Color(red: 224 / 255, green: 112 / 255, blue: 112 / 255)
    static let subtitleMuted = Color(red: 85 / 255, green: 85 / 255, blue: 85 / 255)
    static let prDateMuted = Color(red: 102 / 255, green: 102 / 255, blue: 102 / 255)
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

private struct ProgressStatLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(ProgressStyle.statLabel)
            .tracking(0.4)
    }
}

struct ProgressPageCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProgressStyle.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(ProgressStyle.cardBorder, lineWidth: 0.5)
            )
    }
}

struct ProgressHeaderView: View {
    let weeksTracked: Int

    var body: some View {
        VStack(spacing: 4) {
            Text("Progress")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
            if weeksTracked > 0 {
                Text("\(weeksTracked) week\(weeksTracked == 1 ? "" : "s") tracked")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ProgressStyle.muted)
            } else {
                Text("Start logging to track progress")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ProgressStyle.muted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}

struct ProgressTimeFilter: View {
    @Binding var selection: ProgressTimeRange

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ProgressTimeRange.allCases) { range in
                Button {
                    selection = range
                } label: {
                    Text(range.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == range ? .white : ProgressStyle.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selection == range ? ProgressStyle.segmentActive : ProgressStyle.segmentInactive)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ProgressHeroStatsRow: View {
    let bodyWeight: ProgressBodyWeightStat
    let volume: ProgressVolumeStat
    var onLogWeight: () -> Void

    private let blockHeight: CGFloat = 72

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onLogWeight) {
                bodyWeightBlock
            }
            .buttonStyle(.plain)

            volumeBlock
        }
    }

    private var bodyWeightBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bodyWeight.hasData ? (bodyWeight.valueText ?? "—") : "—")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            ProgressStatLabel(text: "BODY WEIGHT")

            if let delta = bodyWeight.deltaText {
                Text(delta)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(bodyWeightDeltaColor(bodyWeight.deltaStyle))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else if !bodyWeight.hasData {
                Text("tap to log")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(ProgressStyle.muted)
                    .lineLimit(1)
            } else {
                Text(" ")
                    .font(.system(size: 9))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: blockHeight, maxHeight: blockHeight, alignment: .topLeading)
        .background(ProgressStyle.heroBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var volumeBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(volume.hasData ? (volume.valueText ?? "—") : "—")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            ProgressStatLabel(text: "WEEKLY VOLUME")

            if let delta = volume.deltaText {
                Text(delta)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(volumeDeltaColor(volume))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                Text(" ")
                    .font(.system(size: 9))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: blockHeight, maxHeight: blockHeight, alignment: .topLeading)
        .background(ProgressStyle.heroBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func bodyWeightDeltaColor(_ style: ProgressDeltaStyle) -> Color {
        switch style {
        case .positiveGreen: return ProgressStyle.accentGreen
        case .negativeRed: return ProgressStyle.unfavorable
        case .neutral: return ProgressStyle.neutralDelta
        }
    }

    private func volumeDeltaColor(_ volume: ProgressVolumeStat) -> Color {
        guard let delta = volume.deltaText else { return ProgressStyle.neutralDelta }
        if delta == "—" || delta == "— no change" {
            return ProgressStyle.neutralDelta
        }
        return volume.deltaIsPositive ? ProgressStyle.accentGreen : ProgressStyle.volumeNegative
    }
}

struct ProgressStrengthCard: View {
    let chart: StrengthChartData
    var onChangeLift: () -> Void

    var body: some View {
        ProgressPageCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(chart.exerciseName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Change lift", action: onChangeLift)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ProgressStyle.accentGreen)
                }

                if chart.isEmpty {
                    Text("Start logging workouts to track strength.")
                        .font(.system(size: 12))
                        .foregroundStyle(ProgressStyle.muted)
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .center)
                } else {
                    StrengthAreaChart(points: chart.points)
                        .frame(height: 70)

                    HStack {
                        if let start = chart.startCaption {
                            Text(start)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(ProgressStyle.muted)
                        }
                        Spacer()
                        if let end = chart.endCaption {
                            Text(end)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(ProgressStyle.accentGreen)
                        }
                    }

                    if chart.showsTrendHint {
                        Text("Log more sessions to see your trend")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(ProgressStyle.muted)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
    }
}

private struct StrengthAreaChart: View {
    let points: [StrengthChartPoint]

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.maxWeight)
        guard let min = values.min(), let max = values.max() else {
            return 0...100
        }
        if min == max {
            return (min - 10)...(max + 10)
        }
        let padding = Swift.max((max - min) * 0.12, 5)
        return (min - padding)...(max + padding)
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Session", point.sessionIndex),
                    y: .value("Weight", point.maxWeight)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            ProgressStyle.accentGreen.opacity(0.25),
                            ProgressStyle.accentGreen.opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Session", point.sessionIndex),
                    y: .value("Weight", point.maxWeight)
                )
                .foregroundStyle(ProgressStyle.accentGreen)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }

            if let last = points.last {
                PointMark(
                    x: .value("Session", last.sessionIndex),
                    y: .value("Weight", last.maxWeight)
                )
                .foregroundStyle(ProgressStyle.accentGreen)
                .symbolSize(64)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

struct ProgressPersonalRecordsCard: View {
    let records: [ExercisePRRow]
    var onViewAll: () -> Void

    var body: some View {
        ProgressPageCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Personal records")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("All PRs →", action: onViewAll)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ProgressStyle.accentGreen)
                }

                if records.isEmpty {
                    Text("Complete your first workout to set PRs.")
                        .font(.system(size: 12))
                        .foregroundStyle(ProgressStyle.muted)
                } else {
                    ForEach(records) { record in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.exerciseName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(ProgressAnalytics.prSetDateLabel(record.prDate))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(ProgressStyle.prDateMuted)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(SyncFitFormat.decimal(record.prWeight)) lbs")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                Text(record.deltaText)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(
                                        record.deltaUsesAccentGreen
                                            ? ProgressStyle.accentGreen
                                            : ProgressStyle.muted
                                    )
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ProgressPhotosCard: View {
    @EnvironmentObject private var dataStore: FitnessDataStore

    let photos: [ProgressPhotoEntry]
    var onViewAll: () -> Void

    @State private var showingSourcePicker = false
    @State private var showingCameraPermission = false
    @State private var showingCamera = false
    @State private var showingLibraryPicker = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var capturedImage: UIImage?
    @State private var selectedPhoto: ProgressPhotoEntry?
    @State private var showingCompare = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    private let slotHeight: CGFloat = 70
    private let maxVisibleSlots = 6

    private var sortedPhotos: [ProgressPhotoEntry] {
        photos.sorted { $0.date < $1.date }
    }

    private var rowCount: Int {
        sortedPhotos.isEmpty ? 1 : 2
    }

    private var visibleSlotCount: Int {
        rowCount * 3
    }

    var body: some View {
        ProgressPageCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Progress photos")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Add photo") {
                        showingSourcePicker = true
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ProgressStyle.accentGreen)
                }

                Text("Track your visual transformation over time.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProgressStyle.subtitleMuted)

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(0..<visibleSlotCount, id: \.self) { index in
                        if index < min(sortedPhotos.count, maxVisibleSlots) {
                            let photo = sortedPhotos[index]
                            Button {
                                selectedPhoto = photo
                            } label: {
                                ProgressPhotoSlot(
                                    photo: photo,
                                    dateLabel: photo.date.formatted(.dateTime.month(.abbreviated).day()),
                                    slotHeight: slotHeight
                                )
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                showingSourcePicker = true
                            } label: {
                                EmptyPhotoSlot(height: slotHeight)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if photos.count > maxVisibleSlots {
                    Button(action: onViewAll) {
                        Text("View all \(photos.count) photos →")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ProgressStyle.accentGreen)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .confirmationDialog("Add progress photo", isPresented: $showingSourcePicker, titleVisibility: .visible) {
            Button("Take photo") {
                showingCameraPermission = true
            }
            Button("Choose from library") {
                showingLibraryPicker = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Private progress photos", isPresented: $showingCameraPermission) {
            Button("Continue") {
                showingCamera = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SyncFit uses your camera to capture progress photos stored privately in the app.")
        }
        .photosPicker(isPresented: $showingLibraryPicker, selection: $pickerItem, matching: .images)
        .fullScreenCover(isPresented: $showingCamera) {
            ProgressCameraCapture(image: $capturedImage)
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            ProgressPhotoDetailView(
                photo: photo,
                allPhotos: photos,
                onCompare: {
                    selectedPhoto = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showingCompare = true
                    }
                },
                onDelete: {
                    dataStore.deleteProgressPhoto(photo)
                    selectedPhoto = nil
                }
            )
        }
        .sheet(isPresented: $showingCompare) {
            ProgressPhotoComparisonView(photos: photos)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        savePhoto(image)
                        pickerItem = nil
                    }
                }
            }
        }
        .onChange(of: capturedImage) { _, image in
            guard let image else { return }
            savePhoto(image)
            capturedImage = nil
        }
    }

    private func savePhoto(_ image: UIImage) {
        try? dataStore.addProgressPhoto(image, date: .now)
    }
}

struct ProgressPhotoDetailView: View {
    let photo: ProgressPhotoEntry
    let allPhotos: [ProgressPhotoEntry]
    var onCompare: () -> Void
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                ProgressStyle.pageBackground.ignoresSafeArea()
                if let image = ProgressPhotoStorage.loadImage(fileName: photo.fileName, userId: photo.userId) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                }
            }
            .navigationTitle(photo.date.formatted(date: .abbreviated, time: .omitted))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if allPhotos.count >= 2 {
                            Button("Compare", action: onCompare)
                        }
                        Button("Delete", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog(
                "Delete this progress photo?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Photo", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            }
        }
    }
}

private struct ProgressPhotoSlot: View {
    let photo: ProgressPhotoEntry
    let dateLabel: String
    let slotHeight: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            if let image = ProgressPhotoStorage.loadImage(fileName: photo.fileName, userId: photo.userId) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: slotHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ProgressStyle.track)
                    .frame(height: slotHeight)
            }
            Text(dateLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ProgressStyle.muted)
                .lineLimit(1)
        }
    }
}

private struct EmptyPhotoSlot: View {
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                ProgressStyle.segmentActive,
                style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])
            )
            .frame(height: height)
            .overlay {
                Text("+ Add")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProgressStyle.muted)
            }
    }
}

struct ProgressConsistencyCard: View {
    let stats: ConsistencyStats

    private var todayIndex: Int? {
        guard !stats.workoutDayFlags.isEmpty else { return nil }
        return stats.workoutDayFlags.count - 1
    }

    var body: some View {
        ProgressPageCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Consistency")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                ConsistencyMetricRow(
                    title: "Workouts",
                    completedDays: stats.workoutDays,
                    totalDays: stats.totalDays,
                    dayStates: stats.workoutDayFlags,
                    fillColor: ConsistencyVisualStyle.workoutGreen,
                    todayIndex: todayIndex,
                    dotSize: stats.workoutDayFlags.count > 14 ? 5 : 7
                )

                ConsistencyMetricRow(
                    title: "Protein goal",
                    completedDays: stats.proteinGoalDays,
                    totalDays: stats.totalDays,
                    dayStates: stats.proteinDayFlags,
                    fillColor: ConsistencyVisualStyle.proteinBlue,
                    todayIndex: todayIndex,
                    dotSize: stats.proteinDayFlags.count > 14 ? 5 : 7
                )
            }
        }
    }
}

struct ProgressLiftPickerSheet: View {
    let exercises: [String]
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(exercises, id: \.self) { name in
                    Button {
                        selection = name
                        dismiss()
                    } label: {
                        HStack {
                            Text(name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selection == name {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(ProgressStyle.accentGreen)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose Lift")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct AllPRsListView: View {
    let records: [ExercisePRRow]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if records.isEmpty {
                    Text("Complete your first workout to set PRs.")
                        .foregroundStyle(ProgressStyle.muted)
                } else {
                    ForEach(records) { record in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.exerciseName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(ProgressAnalytics.prSetDateLabel(record.prDate))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(ProgressStyle.prDateMuted)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(SyncFitFormat.decimal(record.prWeight)) lbs")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                Text(record.deltaText)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(
                                        record.deltaUsesAccentGreen
                                            ? ProgressStyle.accentGreen
                                            : ProgressStyle.muted
                                    )
                            }
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(ProgressStyle.pageBackground)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ProgressStyle.pageBackground)
            .navigationTitle("All PRs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ProgressStyle.pageBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationBackground(ProgressStyle.pageBackground)
    }
}

struct ProgressPhotoGalleryView: View {
    let photos: [ProgressPhotoEntry]
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    private var sorted: [ProgressPhotoEntry] {
        photos.sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(sorted) { photo in
                        VStack(spacing: 4) {
                            if let image = ProgressPhotoStorage.loadImage(
                                fileName: photo.fileName,
                                userId: photo.userId
                            ) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(height: 110)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            Text(photo.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Progress Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ProgressPhotoComparisonView: View {
    let photos: [ProgressPhotoEntry]
    @State private var leftID: UUID?
    @State private var rightID: UUID?
    @Environment(\.dismiss) private var dismiss

    private var sorted: [ProgressPhotoEntry] {
        photos.sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if sorted.count >= 2 {
                    HStack(spacing: 12) {
                        photoPicker(title: "Before", selection: $leftID)
                        photoPicker(title: "After", selection: $rightID)
                    }
                    .padding(.horizontal)

                    HStack(spacing: 8) {
                        comparisonImage(for: leftID)
                        comparisonImage(for: rightID)
                    }
                    .padding(.horizontal)
                } else {
                    Text("Add at least two photos to compare.")
                        .foregroundStyle(.secondary)
                        .padding()
                }
                Spacer()
            }
            .padding(.top, 12)
            .navigationTitle("Compare Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                leftID = sorted.first?.id
                rightID = sorted.last?.id
            }
        }
    }

    @ViewBuilder
    private func photoPicker(title: String, selection: Binding<UUID?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(sorted) { photo in
                    Text(photo.date.formatted(date: .abbreviated, time: .omitted))
                        .tag(Optional(photo.id))
                }
            }
            .pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func comparisonImage(for id: UUID?) -> some View {
        if let id, let photo = sorted.first(where: { $0.id == id }),
           let image = ProgressPhotoStorage.loadImage(fileName: photo.fileName, userId: photo.userId) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ProgressStyle.track)
                .frame(maxWidth: .infinity)
                .frame(height: 280)
        }
    }
}

private struct ProgressCameraCapture: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ProgressCameraCapture

        init(_ parent: ProgressCameraCapture) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
