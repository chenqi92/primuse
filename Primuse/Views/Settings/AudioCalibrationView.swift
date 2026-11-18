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
            AudioCalibrationLibraryView(deviceID: request.deviceID).environment(eq)
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

struct AudioCalibrationLibraryView: View {
    @Environment(EqualizerService.self) private var eq
    @Environment(\.dismiss) private var dismiss
    let deviceID: String?
    @State private var query = ""
    @State private var showingFile = false
    @State private var showingImport = false
    @State private var text = ""
    @State private var name = ""
    @State private var error: String?
    @State private var showingLicense = false

    @State private var expandedModels = Set<String>()
    private var imported: [EQPreset] { eq.userPresets.filter { $0.parametric != nil && matches($0) } }
    private func matches(_ preset: EQPreset) -> Bool {
        query.isEmpty || preset.name.localizedStandardContains(query)
            || (preset.parametric?.source?.localizedStandardContains(query) ?? false)
    }

    var body: some View {
        let builtIn = EQCalibrationCatalog.searchModels(query)
        NavigationStack {
            List {
                Section {
                    Button(EQText("none")) { select(.flat) }
                }
                if !imported.isEmpty {
                    Section(EQText("imported")) {
                        ForEach(imported) { preset in
                            row(preset, source: preset.parametric?.source)
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { imported[$0].id }
                            for id in ids { eq.deletePreset(id: id) }
                        }
                    }
                }
                Section("\(EQText("builtIn")) · \(builtIn.count.formatted())") {
                    ForEach(builtIn) { model in
                        modelRow(model)
                    }
                }
                if imported.isEmpty && builtIn.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                Section {
                    Button("AutoEq · MIT") { showingLicense = true }
                }
            }
            .searchable(text: $query, prompt: EQText("search"))
            .navigationTitle(EQText("library"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(EQText("done")) { dismiss() } }
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
        }
        .frame(minWidth: 300, minHeight: 400)
        .onChange(of: eq.currentOutputDevice?.id) { _, current in
            if let deviceID, current != deviceID { dismiss() }
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
        row(id: entry.id, name: title, source: showsSource ? entry.measurement : nil) { select(entry.preset) }
            .contextMenu {
                if let url = URL(string: entry.url) { Link(EQText("source"), destination: url) }
            }
    }

    private func row(_ preset: EQPreset, source: String?) -> some View {
        row(id: preset.id, name: preset.name, source: source) { select(preset) }
    }

    private func row(id: String, name: String, source: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).foregroundStyle(.primary)
                    if let source { Text(source).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if eq.currentPreset.id == id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("eq.calibration.preset.\(id)")
    }

    private func select(_ preset: EQPreset) {
        eq.chooseCalibration(preset, for: deviceID)
        dismiss()
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
                    Button(EQText("apply")) {
                        do {
                            let preset = try eq.importCalibration(name: name, text: text)
                            showingImport = false
                            select(preset)
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
        defaults.removePersistentDomain(forName: "primuse.calibration.ui-tests")
        let engine = AudioEngine(volumeDefaults: defaults, outputDefaults: defaults)
        _engine = State(initialValue: engine)
        _eq = State(initialValue: EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false))
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
