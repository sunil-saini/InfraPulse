import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel

    private var expiryMessage: String {
        switch model.status {
        case .signedOut, .expired:
            return "Run AWS Login to establish a session"
        case .unavailable:
            return "Unable to check AWS session expiry"
        default:
            return "AWS access is available; expiry is unavailable"
        }
    }

    private var expiryValue: String {
        switch model.status {
        case .expired:
            return "Expired"
        case .unavailable:
            return "Unavailable"
        case .signedOut:
            return "Signed out"
        case .valid, .expiring:
            return model.expiresAt == nil ? "Unavailable" : model.remainingTime
        case .waiting:
            return "Unavailable"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: model.status.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.status.color)
                    .frame(width: 28, height: 28)
                    .background(model.status.color.opacity(0.14), in: Circle())
                Text("InfraPulse")
                    .font(.headline)
                Spacer()
                Text(appVersion == "dev" ? "dev" : "v\(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.updateAvailable {
                    Button {
                        model.updateApplication()
                    } label: {
                        Label(
                            model.isUpdating ? "Updating…" : "Update",
                            systemImage: "arrow.down.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isUpdating)
                    .help("Update available: v\(model.latestReleaseVersion ?? "")")
                    .accessibilityLabel(model.isUpdating ? "Updating InfraPulse" : "Update InfraPulse")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("AWS Login Expiry:")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(expiryValue)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(model.status == .unavailable ? .orange : model.status.color)
                    Spacer()
                    Text(model.profile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .help("AWS profile: \(model.profile)")
                        .accessibilityLabel("AWS profile: \(model.profile)")
                }

                if model.expiresAt == nil {
                    Text(expiryMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        model.runLogin()
                    } label: {
                        Label(model.isLoggingIn ? "Starting…" : "Run AWS Login", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.isLoggingIn)

                    Spacer()

                    Button {
                        model.refreshNow()
                    } label: {
                        if model.isRefreshingSession {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 16, height: 16)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRefreshingSession)
                    .help("Check AWS session now")
                    .accessibilityLabel(
                        model.isRefreshingSession ? "Checking AWS session" : "Check AWS session now")
                }
            }
            .popoverCard()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("VPN")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(model.vpnState.title)
                        .font(.caption)
                        .foregroundStyle(model.vpnState.color)
                }

                if model.vpnState == .officeNetwork {
                    Text("Office network detected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

            }
            .popoverCard()

            if model.isKubernetesMonitoringEnabled {
                VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Kubernetes")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(model.isSwitchingKubernetesContext ? "Switching…" : model.kubernetesState.title)
                        .font(.caption)
                        .foregroundStyle(model.isSwitchingKubernetesContext ? .secondary : model.kubernetesState.color)
                }

                if !model.availableKubernetesContexts.isEmpty {
                    Picker(
                        "Context",
                        selection: Binding(
                            get: { model.kubernetesContext ?? "" },
                            set: { model.selectKubernetesContext($0) }
                        )
                    ) {
                        ForEach(model.availableKubernetesContexts, id: \.self) { context in
                            Text(model.kubernetesContextDisplay(for: context)).tag(context)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(model.isSwitchingKubernetesContext)
                } else if let context = model.kubernetesContextDisplay {
                    Text("Context: \(context)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                }
                .popoverCard()
            }

            Divider()

            HStack {
                Button {
                    AppWindow.settings.show(SettingsView(model: model))
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button {
                    model.quit()
                } label: {
                    Label("Quit InfraPulse", systemImage: "power")
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)

        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            model.checkForUpdatesIfNeeded(force: true)
        }
        .alert(item: $model.alert) { alert in
            if alert.offersAWSLogin {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Run AWS Login")) { model.runLogin() },
                    secondaryButton: .cancel())
            }
            // These alerts only report something; there is nothing to cancel.
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")))
        }
    }
}
