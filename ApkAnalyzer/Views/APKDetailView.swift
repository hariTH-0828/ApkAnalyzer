import SwiftUI

struct APKDetailView: View {
    let metadata: APKMetadata

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // App icon + App Name header
                HStack(spacing: 16) {
                    if let icon = metadata.icon {
                        Image(uiImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(radius: 3)
                    } else {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: 72, height: 72)
                            .overlay {
                                Image(systemName: "app.dashed")
                                    .font(.title)
                                    .foregroundStyle(.secondary)
                            }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(metadata.appName)
                            .font(.title2.bold())
                            .textSelection(.enabled)

                        Text(metadata.packageName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer()
                }

                Divider()

                // 1. App Information
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        InfoRow(label: "Bundle Name", value: metadata.appName)
                        InfoRow(label: "Bundle Identifier", value: metadata.packageName)
                        InfoRow(label: "Bundle Version (Short)", value: metadata.versionName)
                        InfoRow(label: "Bundle Version", value: metadata.versionCode)
                        InfoRow(label: "Minimum OS Version", value: "API \(metadata.minSDK)")
                        InfoRow(label: "Target OS Version", value: "API \(metadata.targetSDK)")
                        if !metadata.deviceCompatibility.isEmpty {
                            InfoRow(label: "Device Compatibility", value: metadata.deviceCompatibility.joined(separator: ", "))
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    SectionHeader(title: "App Information", icon: "info.circle.fill", color: .blue)
                }

                // 2. Features and Permissions
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        // Permissions
                        if !metadata.permissions.isEmpty {
                            Text("Permissions (\(metadata.permissions.count))")
                                .font(.subheadline.bold())
                                .padding(.top, 4)

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(metadata.permissions, id: \.self) { permission in
                                    HStack(spacing: 6) {
                                        Image(systemName: "lock.shield")
                                            .foregroundStyle(.orange)
                                            .font(.caption)
                                        Text(permission)
                                            .font(.system(.callout, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        } else {
                            Text("No permissions declared.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        }

                        // Uses Features
                        if !metadata.usesFeatures.isEmpty {
                            Divider()
                            Text("User Features (\(metadata.usesFeatures.count))")
                                .font(.subheadline.bold())

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(metadata.usesFeatures, id: \.self) { feature in
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.caption)
                                        Text(feature)
                                            .font(.system(.callout, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }

                        // Not Required Features
                        if !metadata.notRequiredFeatures.isEmpty {
                            Divider()
                            Text("Not Required Features (\(metadata.notRequiredFeatures.count))")
                                .font(.subheadline.bold())

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(metadata.notRequiredFeatures, id: \.self) { feature in
                                    HStack(spacing: 6) {
                                        Image(systemName: "minus.circle")
                                            .foregroundStyle(.gray)
                                            .font(.caption)
                                        Text(feature)
                                            .font(.system(.callout, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    SectionHeader(title: "Features and Permissions", icon: "shield.lefthalf.filled", color: .orange)
                }

                // 3. Signature
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        InfoRow(label: "Signer", value: metadata.signer)
                        InfoRow(label: "Signing Schemes", value: metadata.signingSchemes)
                    }
                    .padding(.vertical, 4)
                } label: {
                    SectionHeader(title: "Signature", icon: "signature", color: .purple)
                }
            }
            .padding()
        }
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundStyle(color)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
