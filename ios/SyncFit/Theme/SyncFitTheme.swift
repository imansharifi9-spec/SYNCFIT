import SwiftUI

enum SyncFitTheme {
    /// Canonical primary-action green (Home "Start workout", sticky CTAs, PrimaryButtonStyle).
    /// RGB(92, 219, 110) / #5CDB6E — the deeper SyncFit brand green.
    static let primaryAction = Color(red: 92 / 255, green: 219 / 255, blue: 110 / 255)

    static let accent = Color(red: 0.18, green: 0.72, blue: 0.45)
    static let accentBright = Color(red: 0.32, green: 0.92, blue: 0.58)
    static let accentDark = Color(red: 0.10, green: 0.48, blue: 0.32)
    static let protein = Color(red: 0.30, green: 0.62, blue: 0.98)
    static let carbs = Color(red: 0.92, green: 0.32, blue: 0.32)
    static let fat = Color(red: 168 / 255, green: 85 / 255, blue: 247 / 255)
    static let calorieOver = Color(red: 230 / 255, green: 180 / 255, blue: 80 / 255)
    static let background = Color(.systemGroupedBackground)
    static let card = Color(.secondarySystemGroupedBackground)
    /// iMessage-style unread indicator (matches Home notification bell).
    static let unreadDot = Color.red

    static let headlineFont = Font.system(.title2, design: .rounded).weight(.bold)
    static let bodyFont = Font.system(.body, design: .default)

    static let itemHeading = accent

    static func detailText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : Color(.secondaryLabel)
    }
}


/// Small filled red circle — present/absent only (no count).
struct UnreadDotBadge: View {
    var size: CGFloat = 8
    var offset: CGSize = CGSize(width: 3, height: -3)

    var body: some View {
        Circle()
            .fill(SyncFitTheme.unreadDot)
            .frame(width: size, height: size)
            .offset(offset)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Overlays an iMessage-style red unread dot at the top-trailing corner.
    func unreadDotBadge(isVisible: Bool, size: CGFloat = 8) -> some View {
        overlay(alignment: .topTrailing) {
            if isVisible {
                UnreadDotBadge(size: size)
            }
        }
    }
}

enum SyncFitFormat {
    static let maxDecimalPlaces = 3

    static func round(_ value: Double, places: Int = maxDecimalPlaces) -> Double {
        let clampedPlaces = min(max(places, 0), maxDecimalPlaces)
        let factor = pow(10.0, Double(clampedPlaces))
        return (value * factor).rounded() / factor
    }

    static func formattedInteger(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func decimal(_ value: Double, maxPlaces: Int = maxDecimalPlaces) -> String {
        let rounded = round(value, places: maxPlaces)
        let places = min(max(maxPlaces, 0), maxDecimalPlaces)
        var text = String(format: "%.\(places)f", rounded)
        if text.contains(".") {
            while text.last == "0" { text.removeLast() }
            if text.last == "." { text.removeLast() }
        }
        return text
    }
}

enum SyncFitInput {
    static func resignKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
    }
}

struct SyncFitCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SyncFitTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(SyncFitTheme.primaryAction.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(SyncFitTheme.accent)
            .frame(maxWidth: .infinity)
            .padding()
            .background(SyncFitTheme.accent.opacity(configuration.isPressed ? 0.15 : 0.1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ProgressRingView<Center: View>: View {
    let progress: Double
    let color: Color
    var lineWidth: CGFloat = 8
    var size: CGFloat = 72
    @ViewBuilder var center: () -> Center

    private var ringProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center()
        }
        .frame(width: size, height: size)
    }
}

enum SyncFitPlusBrand {
    static let name = "SyncFit+"
    static let labeledTitle = "✦ SyncFit+"
    static let subscriberTagline = "Your personal coach"
    static let freeUserPitch =
        "Your workouts and nutrition, finally talking to each other. Unlock AI coaching that knows both."
    static let unlockButton = "Unlock SyncFit+ →"
    static let upgradeButton = "Upgrade to SyncFit+"
    static let viewPlanButton = "View plan →"
}

struct CalorieGoalDisplay {
    let current: Int
    let target: Int

    private var ratio: Double {
        guard target > 0 else { return 0 }
        return Double(current) / Double(target)
    }

    var isOverTarget: Bool {
        target > 0 && ratio > 1.05
    }

    var isOnTrack: Bool {
        target > 0 && ratio >= 0.95 && ratio <= 1.05
    }

    var ringColor: Color {
        isOverTarget ? SyncFitTheme.calorieOver : SyncFitTheme.accentBright
    }

    var ringProgress: Double {
        guard target > 0 else { return 0 }
        return min(ratio, 1)
    }

    var subtitle: String {
        if isOverTarget {
            return "+\(SyncFitFormat.formattedInteger(max(current - target, 0))) over"
        }
        return "of \(SyncFitFormat.formattedInteger(target)) cal"
    }

    var formattedCurrent: String {
        SyncFitFormat.formattedInteger(current)
    }

    /// Home stat tile — value color
    var tileValueColor: Color {
        if current == 0 { return .white }
        if isOverTarget { return SyncFitTheme.calorieOver }
        return SyncFitTheme.accentBright
    }

    /// Home stat tile — bottom label text
    var tileSubtitle: String {
        if current == 0 { return "Log meal →" }
        if isOverTarget { return subtitle }
        return "cal today"
    }

    /// Home stat tile — bottom label color
    var tileSubtitleColor: Color {
        if current == 0 { return SyncFitTheme.accentBright }
        if isOverTarget { return SyncFitTheme.calorieOver }
        return ConsistencyVisualStyle.labelMuted
    }

    var tileSubtitleIsAction: Bool {
        current == 0
    }
}

enum ConsistencyVisualStyle {
    static let workoutGreen = SyncFitTheme.primaryAction
    static let proteinBlue = Color(red: 106 / 255, green: 171 / 255, blue: 238 / 255)
    static let emptyDot = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    static let labelMuted = Color(red: 136 / 255, green: 136 / 255, blue: 136 / 255)
    static let divider = Color.white.opacity(0.08)

    static func fractionLabel(completed: Int, total: Int) -> String {
        "\(completed) / \(total) days"
    }
}

struct ConsistencyMetricRow: View {
    let title: String
    let completedDays: Int
    let totalDays: Int
    let dayStates: [Bool]
    let fillColor: Color
    var showWeekdayLabels: Bool = false
    var todayIndex: Int? = nil
    var dotSize: CGFloat = 7

    private let weekdayLabels = DayHistory.weekdayLabels

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ConsistencyVisualStyle.labelMuted)
                Spacer()
                Text(ConsistencyVisualStyle.fractionLabel(completed: completedDays, total: totalDays))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }

            if showWeekdayLabels {
                HStack(spacing: 0) {
                    ForEach(weekdayLabels.indices, id: \.self) { index in
                        Text(weekdayLabels[index])
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(ConsistencyVisualStyle.labelMuted)
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Capsule()
                .fill(ConsistencyVisualStyle.divider)
                .frame(height: 1)

            HStack(spacing: dotSize <= 5 ? 2 : 0) {
                ForEach(dayStates.indices, id: \.self) { index in
                    consistencyDot(filled: dayStates[index], isToday: index == todayIndex)
                        .frame(maxWidth: dotSize <= 5 ? nil : .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: showWeekdayLabels ? .center : .leading)
        }
    }

    @ViewBuilder
    private func consistencyDot(filled: Bool, isToday: Bool) -> some View {
        Circle()
            .fill(filled ? fillColor : ConsistencyVisualStyle.emptyDot)
            .frame(width: dotSize, height: dotSize)
            .overlay {
                Circle()
                    .strokeBorder(
                        isToday
                            ? Color.white.opacity(0.85)
                            : (filled
                                ? fillColor.opacity(0.5)
                                : ConsistencyVisualStyle.emptyDot.opacity(0.8)),
                        lineWidth: isToday ? 1.5 : 1
                    )
            }
    }
}

struct EditableIntRow: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...9999
    var suffix: String = ""
    var step: Int = 1

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            ModernQuantityStepper(
                value: $value,
                range: range,
                step: step,
                suffix: suffix
            )
        }
    }
}

struct EditableDoubleRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...9999
    var suffix: String = ""
    var step: Double = 1
    var decimalPlaces: Int = SyncFitFormat.maxDecimalPlaces

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            ModernQuantityStepper(
                value: $value,
                range: range,
                step: step,
                suffix: suffix,
                decimalPlaces: min(decimalPlaces, SyncFitFormat.maxDecimalPlaces)
            )
        }
    }
}

private struct StepperDoubleTextField: View {
    @Binding var value: Double?
    let range: ClosedRange<Double>
    let decimalPlaces: Int

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("0", text: $text)
            .keyboardType(.decimalPad)
            .focused($isFocused)
            .onAppear { syncFromValue() }
            .onChange(of: value) { _, _ in
                if isFocused {
                    reconcileStepperChange()
                } else {
                    syncFromValue()
                }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onChange(of: text) { _, newText in
                commitIfComplete(newText)
            }
    }

    private func syncFromValue() {
        guard let value else {
            text = ""
            return
        }
        text = SyncFitFormat.decimal(value, maxPlaces: decimalPlaces)
    }

    private func reconcileStepperChange() {
        guard let value else { return }
        let formatted = SyncFitFormat.decimal(value, maxPlaces: decimalPlaces)
        guard let parsed = parseDouble(text) else {
            text = formatted
            return
        }
        if abs(SyncFitFormat.round(parsed, places: decimalPlaces) - value) > 0.000_001 {
            text = formatted
        }
    }

    private func commitIfComplete(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasSuffix(".") { return }
        guard let parsed = parseDouble(trimmed) else { return }
        let clamped = min(
            max(SyncFitFormat.round(parsed, places: decimalPlaces), range.lowerBound),
            range.upperBound
        )
        if value != clamped {
            value = clamped
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            syncFromValue()
            return
        }
        guard let parsed = parseDouble(trimmed) else {
            syncFromValue()
            return
        }
        let clamped = min(
            max(SyncFitFormat.round(parsed, places: decimalPlaces), range.lowerBound),
            range.upperBound
        )
        value = clamped
        text = SyncFitFormat.decimal(clamped, maxPlaces: decimalPlaces)
    }

    private func parseDouble(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: ""))
    }
}

private struct ModernStepperButton: View {
    let systemName: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isEnabled ? SyncFitTheme.accent : Color(.tertiaryLabel))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isEnabled ? SyncFitTheme.accent.opacity(0.14) : Color(.tertiarySystemFill))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isEnabled ? SyncFitTheme.accent.opacity(0.28) : Color(.separator).opacity(0.25),
                            lineWidth: 1
                        )
                )
                .scaleEffect(pressed ? 0.9 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .animation(.spring(response: 0.22, dampingFraction: 0.62), value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}

struct ModernQuantityStepper: View {
    @Binding var intValue: Int?
    @Binding var doubleValue: Double?
    let rangeInt: ClosedRange<Int>?
    let rangeDouble: ClosedRange<Double>?
    let stepInt: Int
    let stepDouble: Double
    let suffix: String
    let decimalPlaces: Int

    init(
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        suffix: String = ""
    ) {
        _intValue = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = $0 ?? value.wrappedValue }
        )
        _doubleValue = .constant(nil)
        rangeInt = range
        rangeDouble = nil
        stepInt = step
        stepDouble = 1
        self.suffix = suffix
        decimalPlaces = 0
    }

    init(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1,
        suffix: String = "",
        decimalPlaces: Int = 0
    ) {
        _intValue = .constant(nil)
        _doubleValue = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = $0 ?? value.wrappedValue }
        )
        rangeInt = nil
        rangeDouble = range
        stepInt = 1
        stepDouble = step
        self.suffix = suffix
        self.decimalPlaces = min(decimalPlaces, SyncFitFormat.maxDecimalPlaces)
    }

    var body: some View {
        HStack(spacing: 8) {
            ModernStepperButton(systemName: "minus", isEnabled: canDecrement, action: decrement)

            Group {
                if let rangeInt, let binding = intBinding {
                    TextField("0", value: binding, format: .number)
                        .keyboardType(.numberPad)
                } else if let rangeDouble {
                    StepperDoubleTextField(
                        value: $doubleValue,
                        range: rangeDouble,
                        decimalPlaces: decimalPlaces
                    )
                }
            }
            .font(.body.weight(.semibold).monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: fieldWidth)
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            )
            .onChange(of: intValue) { _, newValue in
                guard let newValue, let rangeInt else { return }
                intValue = min(max(newValue, rangeInt.lowerBound), rangeInt.upperBound)
            }

            if !suffix.isEmpty {
                Text(suffix)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            ModernStepperButton(systemName: "plus", isEnabled: canIncrement, action: increment)
        }
    }

    private var intBinding: Binding<Int>? {
        guard rangeInt != nil else { return nil }
        return Binding(
            get: { intValue ?? 0 },
            set: { intValue = $0 }
        )
    }

    private var fieldWidth: CGFloat {
        if rangeDouble != nil {
            switch decimalPlaces {
            case 0: return 48
            case 1: return 56
            case 2: return 68
            default: return 80
            }
        }
        return 48
    }

    private var canDecrement: Bool {
        if let value = intValue, let rangeInt { return value > rangeInt.lowerBound }
        if let value = doubleValue, let rangeDouble { return value > rangeDouble.lowerBound }
        return false
    }

    private var canIncrement: Bool {
        if let value = intValue, let rangeInt { return value < rangeInt.upperBound }
        if let value = doubleValue, let rangeDouble { return value < rangeDouble.upperBound }
        return false
    }

    private func decrement() {
        if let value = intValue, let rangeInt {
            intValue = max(rangeInt.lowerBound, value - stepInt)
        } else if let value = doubleValue, let rangeDouble {
            let next = max(rangeDouble.lowerBound, value - stepDouble)
            doubleValue = SyncFitFormat.round(next, places: decimalPlaces)
        }
    }

    private func increment() {
        if let value = intValue, let rangeInt {
            intValue = min(rangeInt.upperBound, value + stepInt)
        } else if let value = doubleValue, let rangeDouble {
            let next = min(rangeDouble.upperBound, value + stepDouble)
            doubleValue = SyncFitFormat.round(next, places: decimalPlaces)
        }
    }
}

struct WorkoutNumpadIntRow: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...100

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Button {
                isFocused = true
            } label: {
                HStack {
                    Text("\(value)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "keyboard")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                )
            }
            .buttonStyle(.plain)

            TextField("", value: $value, format: .number)
                .keyboardType(.numberPad)
                .focused($isFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onChange(of: value) { _, newValue in
                    value = min(max(newValue, range.lowerBound), range.upperBound)
                }

            HStack(spacing: 8) {
                quickAdjust("+1") { value = min(range.upperBound, value + 1) }
                quickAdjust("+5") { value = min(range.upperBound, value + 5) }
            }
        }
    }

    private func quickAdjust(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SyncFitTheme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(SyncFitTheme.accent.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct WorkoutNumpadDoubleRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1000
    var quickIncrements: [Double] = [2.5, 5, 10]

    @FocusState private var isFocused: Bool
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Button {
                text = SyncFitFormat.decimal(value)
                isFocused = true
            } label: {
                HStack {
                    Text(SyncFitFormat.decimal(value))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text("lb")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "keyboard")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                )
            }
            .buttonStyle(.plain)

            TextField("", text: $text)
                .keyboardType(.decimalPad)
                .focused($isFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onAppear { text = SyncFitFormat.decimal(value) }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commitText() }
                }
                .onChange(of: text) { _, newText in
                    guard isFocused, let parsed = Double(newText.replacingOccurrences(of: ",", with: "")) else { return }
                    let clamped = min(max(SyncFitFormat.round(parsed), range.lowerBound), range.upperBound)
                    if value != clamped { value = clamped }
                }

            HStack(spacing: 8) {
                ForEach(quickIncrements, id: \.self) { increment in
                    quickAdjust("+\(SyncFitFormat.decimal(increment))") {
                        value = min(range.upperBound, SyncFitFormat.round(value + increment))
                        text = SyncFitFormat.decimal(value)
                    }
                }
            }
        }
    }

    private func quickAdjust(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SyncFitTheme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(SyncFitTheme.accent.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func commitText() {
        if let parsed = Double(text.replacingOccurrences(of: ",", with: "")) {
            value = min(max(SyncFitFormat.round(parsed), range.lowerBound), range.upperBound)
        }
        text = SyncFitFormat.decimal(value)
    }
}
