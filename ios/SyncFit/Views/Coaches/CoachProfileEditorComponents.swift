import SwiftUI

struct CoachProfileSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CoachUIColor.subtitle)
            }

            content()
                .padding(12)
                .background(CoachUIColor.card)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(CoachUIColor.border, lineWidth: 0.5)
                )
        }
    }
}

struct CoachSpecialtyChip: View {
    let title: String
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? .black : CoachUIColor.chipInactiveText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? CoachUIColor.chipActive : CoachUIColor.chipInactiveBackground)
                .clipShape(Capsule())
                .overlay {
                    if !isSelected {
                        Capsule()
                            .strokeBorder(CoachUIColor.chipInactiveBorder, lineWidth: 0.5)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

private struct CoachAboutHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 80
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct CoachAboutEditor: View {
    @Binding var text: String
    private let limit = 500
    private let placeholder = "Tell clients about your experience, certifications, and coaching style."

    @State private var contentHeight: CGFloat = 80

    private var countColor: Color {
        let count = text.count
        if count >= 480 { return CoachUIColor.countRed }
        if count >= 400 { return CoachUIColor.countAmber }
        return CoachUIColor.muted
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Text(text.isEmpty ? placeholder : text)
                    .font(.system(size: 14))
                    .foregroundStyle(.clear)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(key: CoachAboutHeightKey.self, value: geometry.size.height)
                        }
                    )

                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14))
                        .foregroundStyle(CoachUIColor.muted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: limitedText)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(minHeight: max(80, contentHeight))
                    .padding(.horizontal, -4)
            }

            Text("\(text.count) / \(limit)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(countColor)
        }
        .onPreferenceChange(CoachAboutHeightKey.self) { contentHeight = $0 }
    }

    private var limitedText: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                text = String(newValue.prefix(limit))
            }
        )
    }
}

struct CoachRateField: View {
    @Binding var ratePerMonth: Int
    @FocusState private var isRateFocused: Bool
    @State private var rateText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("$")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CoachUIColor.muted)

                TextField("75", text: $rateText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .keyboardType(.numberPad)
                    .focused($isRateFocused)
                    .multilineTextAlignment(.leading)
                    .onChange(of: rateText) { _, newValue in
                        let digits = newValue.filter(\.isNumber)
                        if let value = Int(digits) {
                            ratePerMonth = min(max(value, 0), 9_999)
                            rateText = "\(ratePerMonth)"
                        } else if digits.isEmpty {
                            ratePerMonth = 0
                            rateText = ""
                        }
                    }

                Text("/mo")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CoachUIColor.muted)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isRateFocused = true
            }

            Text("Clients pay this monthly. SyncFit takes 15%.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CoachUIColor.muted)
        }
        .onAppear {
            rateText = ratePerMonth > 0 ? "\(ratePerMonth)" : ""
        }
        .onChange(of: ratePerMonth) { _, newValue in
            let formatted = newValue > 0 ? "\(newValue)" : ""
            if rateText != formatted {
                rateText = formatted
            }
        }
    }
}

struct CoachSaveProfileButton: View {
    @EnvironmentObject private var coachService: CoachService
    @State private var displayState: CoachProfileSaveState = .idle

    var body: some View {
        VStack(spacing: 8) {
            Button {
                Task { @MainActor in
                    await coachService.performProfileSave()
                }
            } label: {
                Text(buttonTitle(for: displayState))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(SyncFitTheme.accent.opacity(displayState == .saving ? 0.8 : 1))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(displayState == .saving || displayState == .saved)

            if displayState == .error {
                Text("Couldn't save. Check your connection.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CoachUIColor.errorRed)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onReceive(coachService.$profileSaveState) { newState in
            displayState = newState
        }
        .onAppear {
            displayState = coachService.profileSaveState
        }
    }

    private func buttonTitle(for state: CoachProfileSaveState) -> String {
        switch state {
        case .idle: return "Save profile"
        case .saving: return "Saving..."
        case .saved: return "Profile saved ✓"
        case .error: return "Save profile"
        }
    }
}

struct CoachTestimonialCard: View {
    @Binding var testimonial: CoachTestimonial

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Client name", text: $testimonial.clientName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)

            TextField(
                "What did they say about working with you?",
                text: $testimonial.quote,
                axis: .vertical
            )
            .lineLimit(2...5)
            .font(.system(size: 12))
            .foregroundStyle(.white)
        }
        .padding(12)
        .background(CoachUIColor.testimonialCard)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CoachUIColor.border, lineWidth: 0.5)
        )
    }
}
