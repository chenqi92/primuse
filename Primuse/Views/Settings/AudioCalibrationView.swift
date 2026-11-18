import SwiftUI
import UniformTypeIdentifiers
import PrimuseKit

func EQText(_ key: String, _ arguments: CVarArg...) -> String {
    let value = Bundle.main.localizedString(forKey: key, value: key, table: "AudioCalibration")
    return arguments.isEmpty ? value : String(format: value, arguments: arguments)
}

struct AudioCalibrationControls: View {
    @Environment(EqualizerService.self) private var eq
    private struct LibrarySelection: Identifiable {
        let id = UUID()
        let deviceID: String?
    }
    @State private var selection: LibrarySelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { selection = LibrarySelection(deviceID: eq.currentOutputDevice?.id) } label: {
                Label(EQText("library"), systemImage: "headphones")
            }
            .accessibilityIdentifier("eq.calibration.library")
            .disabled(!eq.calibrationAvailable)
            if let peq = eq.currentPreset.parametric {
                Text(eq.currentPreset.localizedName).font(.headline)
                CalibrationResponseView(preset: eq.currentPreset, showsAxes: true).frame(height: 120)
                DisclosureGroup(EQText("parameters")) {
                  ScrollView {
                   VStack(alignment: .leading, spacing: 5) {
                    Text(String(format: "Preamp: %.1f dB", peq.preamp)).font(.caption.monospaced())
                    ForEach(Array(peq.filters.enumerated()), id: \.offset) { _, filter in
                        Text(String(format: "%@ %@ · %.0f Hz · %+.1f dB · Q %.2f",
                                    filter.enabled ? "ON" : "OFF", filter.kind.rawValue, filter.frequency, filter.gain, filter.q))
                            .font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                    }
                   }
                  }.frame(maxHeight: 180)
                }
            }
            CalibrationAvailabilityView()
        }
        .sheet(item: $selection) { request in
            AudioCalibrationLibraryView(purpose: .output(request.deviceID)).environment(eq)
        }
        .onChange(of: eq.currentOutputDevice?.id) { _, current in
            if let selection, selection.deviceID != current { self.selection = nil }
        }
        .onChange(of: eq.calibrationAvailable) { _, available in
            if !available { selection = nil }
        }
    }
}

struct CalibrationAvailabilityView: View {
    @Environment(EqualizerService.self) private var eq
    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine

    var body: some View {
        if eq.currentPreset.parametric != nil {
            if player.isAppleMusicMode || player.isCastingMode || player.isSystemMediaPlaybackActive {
                Text(EQText("unavailablePlayback")).font(.caption).foregroundStyle(.secondary)
            } else if engine.outputMode == .highFidelity {
                Text(EQText("effectsRequired")).font(.caption).foregroundStyle(.secondary)
            } else if eq.unsupportedSampleRate {
                Text(EQText("unsupportedRate")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private actor CalibrationModelSearch {
    static let shared = CalibrationModelSearch()

    func entries(for ids: [String]) -> [String: EQCalibrationCatalog.Entry] {
        var entries: [String: EQCalibrationCatalog.Entry] = [:]
        for id in ids {
            if Task.isCancelled { break }
            entries[id] = EQCalibrationCatalog.entry(withID: id)
        }
        return entries
    }

    func results(for query: String) -> EQCalibrationCatalog.SearchResults? {
        guard !Task.isCancelled else { return nil }
        return EQCalibrationCatalog.matchingModels(query)
    }

    func page(_ range: Range<Int>, in results: EQCalibrationCatalog.SearchResults) -> [EQCalibrationCatalog.ModelResult] {
        guard !Task.isCancelled else { return [] }
        return results.models(in: range)
    }
}

struct HeadphonePresetRow<UserPresetMenu: View>: View {
    @Environment(EqualizerService.self) private var eq
    @ViewBuilder let userPresetMenu: (EQPreset) -> UserPresetMenu
    @State private var showingLibrary = false
    @State private var catalog: [String: EQCalibrationCatalog.Entry] = [:]

    var body: some View {
        let ids = eq.library.headphonePresetIDs ?? []
        let catalogIDs = ids.filter { $0.hasPrefix("autoeq.") }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(EQText("headphonePresets")).font(.headline)
                Spacer()
                Button { showingLibrary = true } label: {
                    Label("add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("eq.headphones.add")
            }
            if !ids.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(ids, id: \.self) { id in
                            if let preset = eq.library.userPreset(id: id) {
                                chip(id: id, name: preset.name, source: preset.parametric?.source)
                            } else if let entry = catalog[id] {
                                chip(id: id, name: entry.name, source: entry.measurement)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .task(id: catalogIDs) {
            let entries = await CalibrationModelSearch.shared.entries(for: catalogIDs)
            if !Task.isCancelled { catalog = entries }
        }
        .sheet(isPresented: $showingLibrary) {
            AudioCalibrationLibraryView(purpose: .addHeadphone).environment(eq)
        }
    }

    private func chip(id: String, name: String, source: String?) -> some View {
        let selected = eq.calibrationAvailable && eq.currentPreset.id == id
        return HStack(spacing: 0) {
            Button { eq.selectHeadphonePreset(id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "headphones")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: name).font(.subheadline).lineLimit(2)
                        if let source, !source.isEmpty {
                            Text(verbatim: source).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 240, alignment: .leading)
                    .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(.tint.opacity(selected ? 0.15 : 0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!eq.calibrationAvailable)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("eq.headphones." + id)
        }
        .contextMenu {
            Button("remove", systemImage: "minus.circle") { eq.removeHeadphonePreset(id) }
            if let preset = eq.library.userPreset(id: id) {
                Divider()
                userPresetMenu(preset)
            }
        }
    }
}

struct AudioCalibrationLibraryView: View {
    @Environment(EqualizerService.self) private var eq
    @Environment(\.dismiss) private var dismiss
    enum Purpose {
        case output(String?)
        case addHeadphone
    }
    let purpose: Purpose
    private var addingHeadphone: Bool { if case .addHeadphone = purpose { true } else { false } }
    @State private var curveToSave: EQPreset?
    @State private var headphoneName = ""
    @State private var query = ""
    @State private var showingFile = false
    @State private var showingImport = false
    @State private var text = ""
    @State private var name = ""
    @State private var error: String?
    @State private var showingLicense = false

    private static let pageSize = 64
    @State private var builtIn: [EQCalibrationCatalog.ModelResult] = []
    @State private var loadedQuery: String?
    @State private var results: EQCalibrationCatalog.SearchResults?
    @State private var expandedModels = Set<String>()
    private var imported: [EQPreset] { eq.userPresets.filter { (addingHeadphone || $0.parametric != nil) && matches($0) } }
    private func matches(_ preset: EQPreset) -> Bool {
        query.isEmpty || preset.name.localizedStandardContains(query)
            || (preset.parametric?.source?.localizedStandardContains(query) ?? false)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    switch purpose {
                    case .output(let deviceID):
                        Button(EQText("none")) {
                            eq.declineCalibration(for: deviceID)
                            dismiss()
                        }
                        .accessibilityIdentifier("eq.calibration.none")
                    case .addHeadphone:
                        Button(EQText("saveHeadphoneCurve")) {
                            headphoneName = ""
                            curveToSave = eq.currentPreset
                        }
                        .disabled(!eq.canAddPreset)
                        .accessibilityIdentifier("eq.headphones.saveCurrent")
                    }
                }
                if !imported.isEmpty {
                    Section(addingHeadphone ? String(localized: "eq_preset") : EQText("imported")) {
                        ForEach(imported) { preset in
                            row(preset, source: preset.parametric?.source)
                        }
                        .onDelete(perform: addingHeadphone ? nil : { offsets in
                            let ids = offsets.map { imported[$0].id }
                            for id in ids { eq.deletePreset(id: id) }
                        })
                    }
                }
                if loadedQuery == query, let results {
                    Section("\(EQText("builtIn")) · \(results.count.formatted())") {
                        ForEach(builtIn) { model in
                            VStack(alignment: .leading, spacing: 8) { modelRow(model) }
                        }
                        if builtIn.count < results.count {
                            ProgressView().task(id: builtIn.count) { [query] in
                                let offset = builtIn.count
                                let page = await CalibrationModelSearch.shared.page(offset..<(offset + Self.pageSize), in: results)
                                guard !Task.isCancelled, self.query == query, loadedQuery == query, builtIn.count == offset else { return }
                                builtIn.append(contentsOf: page)
                            }
                        }
                    }
                    if imported.isEmpty && builtIn.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    ProgressView()
                }
                Section {
                    Button("AutoEq · MIT") { showingLicense = true }
                }
            }
            .searchable(text: $query, prompt: EQText("search"))
            .navigationTitle(EQText(addingHeadphone ? "headphonePresets" : "library"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(EQText("done")) { dismiss() }
                        .accessibilityIdentifier("eq.calibration.library.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(EQText("importFile")) { showingFile = true }
                        Button(EQText("paste")) { text = ""; name = ""; showingImport = true }
                    } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel(EQText("importFile"))
                }
            }
            .fileImporter(isPresented: $showingFile, allowedContentTypes: [.plainText, .text], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        let data = try handle.read(upToCount: EqualizerAPOParser.maximumBytes + 1) ?? Data()
                        guard data.count <= EqualizerAPOParser.maximumBytes else { throw PEQImportError.tooLarge }
                        guard let contents = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                            throw PEQImportError.empty
                        }
                        text = contents
                        name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ParametricEQ", with: "")
                        showingImport = true
                    } catch { self.error = importMessage(error) }
                case .failure(let error): self.error = error.localizedDescription
                }
            }
            .sheet(isPresented: $showingImport) { importSheet }
            .sheet(isPresented: $showingLicense) {
                NavigationStack {
                    ScrollView { Text(license).font(.caption).textSelection(.enabled).padding() }
                        .navigationTitle("AutoEq · MIT")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(EQText("done")) { showingLicense = false } } }
                }
                .frame(minWidth: 300, minHeight: 320)
            }
            .alert(EQText("importFailed"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(EQText("done"), role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .alert(EQText("saveHeadphoneCurve"), isPresented: Binding(
                get: { curveToSave != nil }, set: { if !$0 { curveToSave = nil } }
            ), presenting: curveToSave) { curve in
                TextField("eq_preset_name_placeholder", text: $headphoneName)
                Button("save") {
                    _ = eq.saveHeadphoneCurve(curve, named: headphoneName)
                }
                .disabled(EQPresetLibrary.normalizedName(headphoneName) == nil || !eq.canAddPreset)
                Button("cancel", role: .cancel) {}
            }
        }
        .frame(minWidth: 300, minHeight: 400)
        .task(id: query) { [query] in
            guard let matches = await CalibrationModelSearch.shared.results(for: query), !Task.isCancelled else { return }
            let first = await CalibrationModelSearch.shared.page(0..<Self.pageSize, in: matches)
            guard !Task.isCancelled else { return }
            if loadedQuery == nil { plog("EQ calibration picker ready models=\(matches.count) rows=\(first.count)") }
            results = matches
            builtIn = first
            loadedQuery = query
        }
    }

    @ViewBuilder
    private func modelRow(_ model: EQCalibrationCatalog.ModelResult) -> some View {
        let selected = model.alternatives.first { $0.id == eq.currentPreset.id }
        let primary = selected ?? model.primary
        let expanded = expandedModels.contains(model.id)
        HStack {
            catalogRow(primary, title: primary.name)
            if !model.alternatives.isEmpty {
                Button {
                    if expanded { expandedModels.remove(model.id) } else { expandedModels.insert(model.id) }
                } label: {
                    HStack(spacing: 4) {
                        Text((model.alternatives.count + 1).formatted())
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.footnote)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(EQText(expanded ? "hideSources" : "showSources", primary.name))
                .accessibilityIdentifier("eq.calibration.sources." + model.primary.id)
            }
        }
        if expanded {
            ForEach(([model.primary] + model.alternatives).filter { $0.id != primary.id }) { entry in
                catalogRow(entry, title: entry.measurement, showsSource: false)
                    .padding(.leading, 16)
            }
        }
    }

    private func catalogRow(_ entry: EQCalibrationCatalog.Entry, title: String, showsSource: Bool = true) -> some View {
        row(id: entry.id, name: title, source: showsSource ? entry.measurement : nil) { select(entry.id, preset: entry.preset) }
            .contextMenu {
                if let url = URL(string: entry.url) { Link(EQText("source"), destination: url) }
            }
    }

    private func row(_ preset: EQPreset, source: String?) -> some View {
        row(id: preset.id, name: preset.name, source: source) { select(preset.id, preset: preset) }
    }

    private func row(id: String, name: String, source: String?, action: @escaping () -> Void) -> some View {
        let selected = addingHeadphone ? eq.library.headphonePresetIDs?.contains(id) == true : eq.currentPreset.id == id
        return Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).foregroundStyle(.primary)
                    if let source { Text(source).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("eq.calibration.preset.\(id)")
    }

    private func select(_ id: String, preset: @autoclosure () -> EQPreset) {
        switch purpose {
        case .output(let deviceID):
            eq.chooseCalibration(preset(), for: deviceID)
            dismiss()
        case .addHeadphone:
            if eq.library.headphonePresetIDs?.contains(id) == true { eq.removeHeadphonePreset(id) }
            else { eq.addHeadphonePreset(id) }
        }
    }

    private var importSheet: some View {
        NavigationStack {
            Form {
                TextField(EQText("name"), text: $name)
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 220)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(EQText("pasteParameters"))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(EQText("parameters"))
            }
            .navigationTitle(EQText("importFile"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(EQText("cancel")) { showingImport = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(addingHeadphone ? String(localized: "add") : EQText("apply")) {
                        do {
                            let preset = try eq.importCalibration(name: name, text: text)
                            showingImport = false
                            select(preset.id, preset: preset)
                        } catch { self.error = importMessage(error); showingImport = false }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.isEmpty)
                }
            }
        }
        .frame(minWidth: 300, minHeight: 380)
    }

    private func importMessage(_ error: Error) -> String {
        switch error {
        case PEQImportError.unsupportedLine(let line): return EQText("unsupportedLine", line)
        case PEQImportError.invalidValue(let line): return EQText("invalidValue", line)
        case PEQImportError.tooManyFilters: return EQText("tooManyFilters", ParametricEQ.maximumFilters)
        case PEQImportError.tooLarge: return EQText("tooLarge")
        case PEQImportError.empty: return EQText("empty")
        case EqualizerService.CalibrationLibraryError.cannotSave: return EQText("cannotSave")
        default: return error.localizedDescription
        }
    }

    private var license: String {
        guard let url = Bundle.main.url(forResource: "AutoEq-LICENSE", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return "https://github.com/jaakkopasanen/AutoEq" }
        return contents
    }
}

#if DEBUG && os(iOS)
struct CalibrationTestHost: View {
    @State private var eq: EqualizerService
    @State private var engine: AudioEngine

    init() {
        let defaults = UserDefaults(suiteName: "primuse.calibration.ui-tests")!
        let restoring = ProcessInfo.processInfo.environment["PRIMUSE_EQ_TEST_RELAUNCH"] == "1"
        if !restoring { defaults.removePersistentDomain(forName: "primuse.calibration.ui-tests") }
        let engine = AudioEngine(volumeDefaults: defaults, outputDefaults: defaults)
        _engine = State(initialValue: engine)
        let service = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false)
        if !restoring { service.setEnabled(true) }
        _eq = State(initialValue: service)
    }

    var body: some View {
        NavigationStack {
            EqualizerView()
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Sony") { eq.outputDeviceDidChange(EQOutputDevice(id: "test.sony", name: "WH-1000XM5", kind: .bluetooth)) }
                            .accessibilityIdentifier("eq.test.connect")
                        Button("DAC") { eq.outputDeviceDidChange(EQOutputDevice(id: "test.dac", name: "USB DAC", kind: .usb)) }
                            .accessibilityIdentifier("eq.test.dac")
                        Button("Off") { eq.outputDeviceDidChange(EQOutputDevice(id: "builtin", name: "Speaker", kind: .builtInSpeaker)) }
                            .accessibilityIdentifier("eq.test.disconnect")
                    }
                }
        }
        .calibrationPromptHost()
        .environment(eq)
        .environment(engine)
    }
}
#endif

struct CalibrationResponseView: View {
    @Environment(AudioEngine.self) private var engine
    let preset: EQPreset
    var showsAxes = false

    private var sampleRate: Double { engine.outputFormat?.sampleRate ?? 48_000 }
    private var upperFrequency: Double { min(20_000, sampleRate * 0.49) }
    private var coefficients: [EQBiquad]? {
        guard let peq = preset.parametric else { return nil }
        let enabled = peq.filters.filter(\.enabled)
        guard enabled.allSatisfy({ $0.frequency < sampleRate / 2 }) else { return nil }
        return enabled.map { EQBiquad(filter: $0, sampleRate: sampleRate) }
    }

    var body: some View {
        let rate = sampleRate
        let upper = upperFrequency
        let filters = coefficients
        let ticks = [100.0, 1_000, 10_000].filter { $0 <= upper }
        let labels = ticks.map { $0 < 1_000 ? "\(Int($0)) Hz" : "\(Int($0 / 1_000)) kHz" }
        Canvas { context, size in
            guard let filters else { return }
            let labelStyle = Font.caption2.monospacedDigit()
            func label(_ value: String) -> GraphicsContext.ResolvedText {
                context.resolve(Text(verbatim: value).font(labelStyle).foregroundStyle(.secondary))
            }
            let zeroLabel = label("0 dB")
            let labelSize = zeroLabel.measure(in: size)
            let left = showsAxes ? labelSize.width + 6 : 0
            let bottom = size.height - (showsAxes ? labelSize.height + 5 : 0)
            guard size.width > left, bottom > 0 else { return }
            let width = size.width - left
            var zero = Path()
            zero.move(to: CGPoint(x: left, y: bottom / 2))
            zero.addLine(to: CGPoint(x: size.width, y: bottom / 2))
            context.stroke(zero, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            if showsAxes {
                context.draw(zeroLabel, at: CGPoint(x: 0, y: bottom / 2), anchor: .leading)
                for (frequency, title) in zip(ticks, labels) {
                    let x = left + width * log(frequency / 20) / log(upper / 20)
                    let resolved = label(title)
                    let half = resolved.measure(in: size).width / 2
                    context.draw(resolved, at: CGPoint(x: min(size.width - half, max(half, x)), y: size.height), anchor: .bottom)
                }
            }
            let count = 240
            let values = (0..<count).map { i in
                let frequency = 20 * pow(upper / 20, Double(i) / Double(count - 1))
                return filters.reduce(0) { $0 + $1.gainDB(frequency: frequency, sampleRate: rate) }
            }
            let limit = max(12, values.map(abs).max() ?? 12)
            var curve = Path()
            for (i, value) in values.enumerated() {
                let point = CGPoint(x: left + Double(i) / Double(count - 1) * width,
                                    y: (0.5 - value / (2 * limit)) * bottom)
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(.accentColor), lineWidth: 2)
        }
        .accessibilityLabel(EQText("response"))
        .accessibilityValue(Text(verbatim: showsAxes && filters != nil ? zip(ticks, labels).map { frequency, title in
            let gain = filters?.reduce(0) { $0 + $1.gainDB(frequency: frequency, sampleRate: rate) } ?? 0
            return "\(title), \(gain.formatted(.number.precision(.fractionLength(1)))) dB"
        }.joined(separator: ", ") : preset.name))
    }
}
