#if os(macOS)
import SwiftUI

/// macOS-native trusted domains pane. Apple-Music style grouped Form —
/// section with domains as rows (each with an inline delete), section
/// footer with help text, and a single + button at the top of the
/// section header. Replaces the standalone Table + bottom button bar so
/// the visual matches Playback / iCloud Sync etc.
struct MacTrustedDomainsView: View {
    @State private var newDomain = ""
    @State private var showAddSheet = false
    /// Bumped after every mutation so SwiftUI re-reads the singleton store.
    @State private var refreshTick: Int = 0

    private var domains: [String] {
        _ = refreshTick
        return SSLTrustStore.shared.trustedDomains
    }

    var body: some View {
        Form {
            Section {
                if domains.isEmpty {
                    HStack {
                        Text("no_trusted_domains")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Spacer()
                    }
                } else {
                    ForEach(domains, id: \.self) { domain in
                        HStack {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(.tint)
                                .frame(width: 22)
                            Text(domain).monospaced()
                            Spacer()
                            Button(role: .destructive) {
                                untrust(domain)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(Text("delete"))
                        }
                    }
                }
            } header: {
                HStack {
                    Text("trusted_domains")
                    Spacer()
                    Button {
                        newDomain = ""
                        showAddSheet = true
                    } label: {
                        Label("add", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(Text("add_trusted_domain"))
                }
            } footer: {
                Text("trusted_domains_desc")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddSheet) { addSheet }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("add_trusted_domain")
                .font(.headline)
            Text("add_trusted_domain_message")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("domain_placeholder", text: $newDomain)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { commitAdd() }

            HStack {
                Spacer()
                Button("cancel", role: .cancel) {
                    newDomain = ""
                    showAddSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("add") { commitAdd() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(newDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func commitAdd() {
        let domain = newDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty else { return }
        SSLTrustStore.shared.trust(domain: domain)
        newDomain = ""
        showAddSheet = false
        refreshTick &+= 1
    }

    private func untrust(_ domain: String) {
        SSLTrustStore.shared.untrust(domain: domain)
        refreshTick &+= 1
    }
}
#endif
