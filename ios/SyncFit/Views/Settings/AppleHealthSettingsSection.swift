import SwiftUI

struct AppleHealthSettingsSection: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dataStore: FitnessDataStore
    @EnvironmentObject private var healthKit: HealthKitService

    var body: some View {
        SyncFitCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                    Text("Apple Health")
                        .font(.headline)
                }

                Text("Keep SyncFit and Apple Health in sync — workouts, nutrition, and weight flow both ways.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !healthKit.isAvailable {
                    Label("Apple Health isn't available on this device.", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Sync with Apple Health", isOn: Binding(
                        get: { appState.appleHealthSyncEnabled },
                        set: { newValue in
                            Task {
                                await handleToggle(newValue)
                            }
                        }
                    ))
                    .tint(SyncFitTheme.accentBright)

                    statusRow

                    if let statusMessage = healthKit.statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if appState.appleHealthSyncEnabled, healthKit.connectionStatus == .connected {
                        VStack(alignment: .leading, spacing: 8) {
                            syncDetailRow("Writes", value: "Workouts, meals, weight")
                            syncDetailRow("Reads", value: "Steps, active calories, weight")

                            if let lastSync = healthKit.lastSyncDate {
                                syncDetailRow("Last sync", value: lastSync.formatted(date: .abbreviated, time: .shortened))
                            }

                            Button {
                                Task {
                                    await healthKit.syncNow(dataStore: dataStore)
                                }
                            } label: {
                                HStack {
                                    if healthKit.isSyncing {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                    Text(healthKit.isSyncing ? "Syncing…" : "Sync Now")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(healthKit.isSyncing)
                        }
                    }
                }
            }
        }
        .onAppear {
            healthKit.refreshConnectionStatus(isEnabled: appState.appleHealthSyncEnabled)
        }
        .onChange(of: appState.appleHealthSyncEnabled) { _, enabled in
            healthKit.refreshConnectionStatus(isEnabled: enabled)
        }
    }

    private var statusRow: some View {
        HStack {
            Text("Status")
                .foregroundStyle(.secondary)
            Spacer()
            Label(statusLabel, systemImage: statusIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
        }
        .font(.subheadline)
    }

    private var statusLabel: String {
        switch healthKit.connectionStatus {
        case .unavailable: return "Unavailable"
        case .notConnected: return "Off"
        case .connected: return "Connected"
        case .denied: return "Access Denied"
        }
    }

    private var statusIcon: String {
        switch healthKit.connectionStatus {
        case .connected: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        default: return "circle"
        }
    }

    private var statusColor: Color {
        switch healthKit.connectionStatus {
        case .connected: return SyncFitTheme.accentBright
        case .denied: return .orange
        default: return .secondary
        }
    }

    private func syncDetailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func handleToggle(_ enabled: Bool) async {
        if enabled {
            appState.setAppleHealthSyncEnabled(true)
            await healthKit.connect(dataStore: dataStore)
            if healthKit.connectionStatus != .connected {
                appState.setAppleHealthSyncEnabled(false)
            }
        } else {
            appState.setAppleHealthSyncEnabled(false)
            healthKit.disconnect()
        }
    }
}
