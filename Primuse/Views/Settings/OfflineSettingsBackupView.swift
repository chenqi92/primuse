#if os(iOS) || os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import PrimuseKit

enum OfflineSettingsBackupAction { case `export`, `import` }

struct OfflineSettingsBackupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var action: OfflineSettingsBackupAction?
    var body: some View {
        NavigationStack {
            Form {
                Button("settings_backup_export", systemImage: "square.and.arrow.up") { action = .export }
                    .accessibilityIdentifier("settings.backup.export")
                Button("settings_backup_import", systemImage: "square.and.arrow.down") { action = .import }
                    .accessibilityIdentifier("settings.backup.import")
            }
            .formStyle(.grouped)
            .navigationTitle("settings_backup_title")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 280)
        #endif
        .offlineSettingsBackup(action: $action)
    }
}

extension View {
    func offlineSettingsBackup(action: Binding<OfflineSettingsBackupAction?>) -> some View {
        modifier(OfflineSettingsBackupModifier(action: action))
    }
}

private struct OfflineSettingsBackupModifier: ViewModifier {
    @Binding var action: OfflineSettingsBackupAction?
    @State private var exporting = false
    @State private var importing = false
    @State private var busy = false
    @State private var document: SettingsBackupDocument?
    @State private var pending: OfflineSettingsBackup?
    @State private var confirmsImport = false
    @State private var message: String?
    @State private var failure: String?

    @State private var incoming: ListeningShareCoordinator.Incoming?

    func body(content: Content) -> some View {
        content
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .onChange(of: action) { _, requested in
            guard let requested else { return }
            action = nil
            switch requested {
            case .import: importing = true
            case .export:
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        document = SettingsBackupDocument(data: try await OfflineSettingsBackupService.export())
                        exporting = true
                    } catch { show(error) }
                }
            }
        }
        .sheet(item: $incoming) { ListeningShareImportView(incoming: $0) }
        .alert("settings_backup_title", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) { Button("ok", role: .cancel) {} } message: { Text(message ?? "") }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "Primuse-Settings-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)))") { result in
            document = nil
            if case .failure(let error) = result { show(error) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .primuseShare, .data]) { result in
            switch result {
            case .success(let url):
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        if url.pathExtension.lowercased() == "primuseshare" {
                            incoming = try await ListeningShareCoordinator.shared.stage(url)
                        } else {
                            do {
                                pending = try await OfflineSettingsBackupService.read(url)
                                confirmsImport = true
                            } catch OfflineSettingsBackupError.invalidFile {
                                incoming = try await ListeningShareCoordinator.shared.stage(url)
                            }
                        }
                    } catch { show(error) }
                }
            case .failure(let error): show(error)
            }
        }
        .alert("settings_backup_confirm_title", isPresented: $confirmsImport) {
            Button("cancel", role: .cancel) { pending = nil }
            Button("settings_backup_import", role: .destructive) {
                guard let backup = pending else { return }
                pending = nil
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        try await OfflineSettingsBackupService.restore(backup)
                        message = String(localized: "settings_backup_imported")
                    } catch { show(error) }
                }
            }
            .accessibilityIdentifier("settings.backup.confirm")
        } message: {
            if let pending {
                Text(pending.createdAt.formatted(date: .abbreviated, time: .shortened)
                     + " · " + pending.platform + "\n\n" + String(localized: "settings_backup_confirm_message"))
            }
        }
        .alert("settings_backup_failed", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("ok", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func show(_ error: Error) {
        if (error as NSError).code == CocoaError.userCancelled.rawValue { return }
        switch error as? OfflineSettingsBackupError {
        case .unsupportedVersion: failure = String(localized: "settings_backup_newer_version")
        case .tooLarge: failure = String(localized: "settings_backup_too_large")
        case .invalidFile, .invalidSetting, .invalidAsset: failure = String(localized: "settings_backup_invalid")
        case nil: failure = ListeningShareText.error(error)
        }
    }
}

private struct SettingsBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw OfflineSettingsBackupError.invalidFile }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
#endif
