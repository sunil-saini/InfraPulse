import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedProfile = "default"
    @State private var newOfficePublicIP = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 25))
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("AWS profile")
                                .font(.body.weight(.medium))
                            Text("Used for AWS Login and session status")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            model.refreshProfiles()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh AWS profiles")
                    }

                    HStack(spacing: 10) {
                        Picker("Profile", selection: $selectedProfile) {
                            ForEach(model.availableProfiles, id: \.self) { profile in
                                Text(profile).tag(profile)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(model.availableProfiles.isEmpty)

                        if !model.availableProfiles.isEmpty {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 7, height: 7)
                                Text("Currently selected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(model.profile)
                                    .font(.caption.weight(.medium))
                            }
                            .fixedSize()
                        }
                    }

                    if model.availableProfiles.isEmpty {
                        Label("No configured AWS profiles found. Check that AWS CLI is installed and configured.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .settingsCard()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "network")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Office public IPs")
                            .font(.body.weight(.medium))
                        Text("VPN is not required when your public IP matches one of these addresses")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                ForEach(model.officePublicIPs, id: \.self) { address in
                    HStack {
                        Text(address)
                            .font(.body.monospaced())
                        Spacer()
                        Button {
                            model.removeOfficePublicIP(address)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove office IP")
                    }
                }

                HStack(spacing: 8) {
                    TextField("Public IPv4 address", text: $newOfficePublicIP)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addOfficePublicIP)

                    Button("Add", action: addOfficePublicIP)
                        .disabled(!canAddOfficePublicIP)
                }
            }
            .settingsCard()
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Kubernetes monitoring")
                            .font(.body.weight(.medium))
                        Text("Monitor kubectl context and cluster connectivity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { model.isKubernetesMonitoringEnabled },
                        set: { model.setKubernetesMonitoringEnabled($0) }
                    ))
                    .labelsHidden()
                }
            }
            .settingsCard()
            .padding(.top, 12)

            Spacer(minLength: 18)

            HStack {
                Text("Changes are saved automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 520)
        .onAppear {
            selectedProfile = model.profile
            model.refreshProfiles()
        }
        .onChange(of: selectedProfile) { newProfile in
            model.selectProfile(newProfile)
        }
        .onChange(of: model.profile) { newProfile in
            selectedProfile = newProfile
        }
    }

    private var canAddOfficePublicIP: Bool {
        let trimmedAddress = newOfficePublicIP.trimmingCharacters(in: .whitespacesAndNewlines)
        return VPNDetector.isValidIPv4Address(trimmedAddress)
            && !model.officePublicIPs.contains(trimmedAddress)
    }

    private func addOfficePublicIP() {
        if model.addOfficePublicIP(newOfficePublicIP) {
            newOfficePublicIP = ""
        }
    }
}
