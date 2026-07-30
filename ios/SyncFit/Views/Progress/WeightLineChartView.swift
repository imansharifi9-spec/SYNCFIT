import SwiftUI
import Charts

struct WeightLineChartView: View {
    let entries: [WeightEntry]

    private var sortedEntries: [WeightEntry] {
        entries.sorted { $0.date < $1.date }
    }

    private var isFlat: Bool {
        guard let first = sortedEntries.first?.weight else { return true }
        return sortedEntries.allSatisfy { abs($0.weight - first) < 0.001 }
    }

    private var yDomain: ClosedRange<Double> {
        let values = sortedEntries.map(\.weight)
        guard let min = values.min(), let max = values.max() else {
            return 150...200
        }
        if min == max {
            return (min - 5)...(max + 5)
        }
        let padding = Swift.max((max - min) * 0.12, 1)
        return (min - padding)...(max + padding)
    }

    var body: some View {
        Group {
            if sortedEntries.count < 2 {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Log at least 2 weights to see your trend line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
            } else {
                Chart(sortedEntries) { entry in
                    AreaMark(
                        x: .value("Date", entry.date),
                        y: .value("Weight", entry.weight)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                SyncFitTheme.accent.opacity(0.28),
                                SyncFitTheme.accent.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(isFlat ? .linear : .catmullRom)

                    LineMark(
                        x: .value("Date", entry.date),
                        y: .value("Weight", entry.weight)
                    )
                    .foregroundStyle(SyncFitTheme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(isFlat ? .linear : .catmullRom)

                    PointMark(
                        x: .value("Date", entry.date),
                        y: .value("Weight", entry.weight)
                    )
                    .foregroundStyle(SyncFitTheme.accentBright)
                    .symbolSize(36)
                }
                .chartYScale(domain: yDomain)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color(.separator).opacity(0.35))
                        AxisValueLabel {
                            if let weight = value.as(Double.self) {
                                Text("\(SyncFitFormat.decimal(weight))")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color(.separator).opacity(0.25))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(.caption2)
                    }
                }
                .frame(height: 200)
            }
        }
    }
}
