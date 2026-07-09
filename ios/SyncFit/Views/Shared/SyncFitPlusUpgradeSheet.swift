import SwiftUI

struct SyncFitPlusUpgradeSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var highlight: SyncFitPlusFeature = .general

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    featuresCard
                    pricingCard
                    Button(SyncFitPlusBrand.upgradeButton) {
                        appState.presentSyncFitPlusUpgradeConfirmed()
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Text("Payment integration coming soon. Preview unlocks SyncFit+ on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .padding(.bottom, 24)
            }
            .background(SyncFitTheme.background)
            .navigationTitle("SyncFit+")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [SyncFitTheme.accentBright.opacity(0.35), SyncFitTheme.accent.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(SyncFitTheme.accentBright)
            }

            Text(headerTitle)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var headerTitle: String {
        switch highlight {
        case .personalizedRoutines:
            return "Personalised routines built for you"
        case .general:
            return "Train and eat smarter"
        }
    }

    private var headerSubtitle: String {
        switch highlight {
        case .personalizedRoutines:
            return "SyncFit+ analyses your goals, experience, and recovery to generate workout plans that adapt as you progress."
        case .general:
            return "Daily AI coaching, smarter nutrition guidance, and plans that match how you actually train."
        }
    }

    private var featuresCard: some View {
        SyncFitCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("What's included")
                    .font(.headline)

                featureRow(
                    icon: "figure.strengthtraining.traditional",
                    title: "Personalised routines",
                    detail: "AI-built push/pull/legs and goal-specific templates",
                    emphasized: highlight == .personalizedRoutines
                )
                featureRow(
                    icon: "brain.head.profile",
                    title: "AI coach notes",
                    detail: "Daily insights on protein, volume, and recovery"
                )
                featureRow(
                    icon: "fork.knife",
                    title: "Smarter nutrition",
                    detail: "Meal suggestions to close macro gaps faster"
                )
                featureRow(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "Adaptive pacing",
                    detail: "Weekly mission tracking tuned to your goal"
                )
            }
        }
    }

    private func featureRow(icon: String, title: String, detail: String, emphasized: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(emphasized ? SyncFitTheme.accentBright : SyncFitTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(emphasized ? SyncFitTheme.accentBright : SyncFitTheme.detailText(for: colorScheme))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(emphasized ? 10 : 0)
        .background {
            if emphasized {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SyncFitTheme.accent.opacity(0.10))
            }
        }
    }

    private var pricingCard: some View {
        SyncFitCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SyncFit+ Monthly")
                        .font(.subheadline.weight(.semibold))
                    Text("Cancel anytime")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("$9.99")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(SyncFitTheme.accent)
                Text("/mo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
    }
}

enum SyncFitPlusFeature {
    case general
    case personalizedRoutines
}

struct SyncFitPlusRoutinePromo: View {
    let onUpgrade: () -> Void

    var body: some View {
        Button(action: onUpgrade) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    SyncFitTheme.accent.opacity(0.22),
                                    SyncFitTheme.accentDark.opacity(0.35)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                    Image(systemName: "sparkles")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(SyncFitTheme.accentBright)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Unlock personalised routines")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("SyncFit+ builds plans around your goal and experience.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SyncFitTheme.accent)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(SyncFitTheme.accent.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(SyncFitTheme.accent.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
