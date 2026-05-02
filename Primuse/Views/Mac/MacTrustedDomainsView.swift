#if os(macOS)
import SwiftUI

/// macOS-native trusted domains pane. Replaces the iOS list-with-swipe
/// approach with a `Table` (multi-select + delete via context menu / button)
/// and a standard plus button on the toolbar of the table.
struct MacTrustedDomainsView: View {
    private struct Row: Identifiable, Hashable {
        let id: String   // domain itself doubles as id
    }

    @State private var newDomain = ""
    @State private var showAddSheet = false
    @State private var selection = Set<String>()
    /// Bumped after every mutation so SwiftUI re-reads the singleton store.
    @State private var refreshTick: Int = 0

    private var domains: [Row] {
        _ = refreshTick
        return SSLTrustStore.shared.trustedDomains.map(Row.init)
    }
    private var hasDomains: Bool { !SSLTrustStore.shared.trustedDomains.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("trusted_domains_desc")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Table(domains, selection: $selection) {
                TableColumn(String(localized: "domain")) { row in
                    Text(row.id).monospaced()
                }
            }
            .frame(minHeight: 240)
            .overlay {
                if !hasDomains {
                    ContentUnavailableView {
                        Label("no_trusted_domains", systemImage: "lock.shield")
                    } description: {
                        Text("trusted_domains_desc").font(.callout)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    newDomain = ""
                    showAddSheet = true
                } label: {
                    Label("add", systemImage: "plus")
                }
                .controlSize(.regular)

                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Label("delete", systemImage: "minus")
                }
                .controlSize(.regular)
                .disabled(selection.isEmpty)

                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    private func deleteSelected() {
        for domain in selection {
            SSLTrustStore.shared.untrust(domain: domain)
        }
        selection.removeAll()
        refreshTick &+= 1
    }
}
#endif
