import SwiftUI
import CopilotSDK

/// Settings section for pairing with a Neo desktop instance via relay.
public struct NeoDesktopSettingsSection: View {
    @ObservedObject var coordinator: BaseCoordinator
    @State private var pairingCode: String = ""
    @State private var isPairing = false
    @State private var pairingError: String?
    @State private var pairingSuccess: String?

    public init(coordinator: BaseCoordinator) {
        self._coordinator = ObservedObject(wrappedValue: coordinator)
    }

    public var body: some View {
        Section {
            if let secret = coordinator.neoDesktopPairingSecret, !secret.isEmpty {
                // Already paired
                HStack {
                    Label(coordinator.neoDesktopName ?? "Neo Desktop", systemImage: "desktopcomputer")
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(coordinator.neoDesktopOnline ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(coordinator.neoDesktopOnline ? "Desktop online" : "Desktop offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Toggle("Use Neo Desktop", isOn: $coordinator.useNeoDesktop)
                    .onChange(of: coordinator.useNeoDesktop) { _ in
                        coordinator.saveSharedSettings()
                    }

                if coordinator.useNeoDesktop {
                    Text("Chat messages are sent to your Neo desktop via relay. Questions are answered on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    coordinator.unpairNeoDesktop()
                    pairingCode = ""
                    pairingError = nil
                    pairingSuccess = nil
                } label: {
                    Label("Unpair", systemImage: "xmark.circle")
                }
            } else {
                // Not paired — show code entry
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter the 6-digit code shown on your Neo desktop")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("000000", text: $pairingCode)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                            .autocorrectionDisabled()

                        Button {
                            Task { await pair() }
                        } label: {
                            if isPairing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Pair")
                            }
                        }
                        .disabled(pairingCode.count != 6 || isPairing)
                        .buttonStyle(.borderedProminent)
                    }
                }

                if let error = pairingError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let success = pairingSuccess {
                    Text(success)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        } header: {
            Text("Neo Desktop")
        } footer: {
            Text("Pair with a Neo desktop to use its AI tools remotely")
        }
        .task(id: coordinator.neoDesktopPairingSecret) {
            guard coordinator.neoDesktopPairingSecret != nil else { return }
            while !Task.isCancelled {
                await coordinator.refreshNeoDesktopStatus()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func pair() async {
        isPairing = true
        pairingError = nil
        pairingSuccess = nil

        do {
            let name = try await coordinator.pairWithNeoDesktop(code: pairingCode)
            pairingSuccess = "Paired with \(name)"
            pairingCode = ""
        } catch {
            pairingError = error.localizedDescription
        }

        isPairing = false
    }
}
