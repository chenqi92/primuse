import Foundation
import Testing
@testable import PrimuseKit

@Suite("Parametric equalizer")
struct ParametricEQTests {
    @Test func parserKeepsPreampBypassAndShelfQ() throws {
        let peq = try EqualizerAPOParser.parse("\u{FEFF}# Imported\r\nPreamp: -4 dB\r\nPreamp: -1 dB\r\nFilter 1: ON LSC Fc 105 Hz Gain 4.8 dB Q 0.70\r\nFilter 2: OFF PK Fc 5059 Hz Gain -1.9 dB Q 5.33 # optional\r\nFilter: ON HSC Fc 10000 Hz Gain -3 dB Q 1.3")
        #expect(peq.preamp == -5)
        #expect(peq.filters.count == 3)
        #expect(peq.filters[0].kind == .lowShelf)
        #expect(!peq.filters[1].enabled)
        #expect(peq.filters[2].q == 1.3)
    }

    @Test(arguments: ["Channel: L", "Include: other.txt", "GraphicEQ: 20 3; 100 4", "Filter: ON LS Fc 100 Hz Gain 3 dB", "Filter: ON PK Fc 1000 Hz Gain 3 dB Q NaN"])
    func parserNeverSilentlyDropsCommands(_ command: String) {
        #expect(throws: PEQImportError.self) { try EqualizerAPOParser.parse("Filter: ON PK Fc 100 Hz Gain 3 dB Q 1\n" + command) }
    }

    @Test func parserLimits() {
        #expect(throws: PEQImportError.unsupportedLine(2)) {
            try EqualizerAPOParser.parse("Preamp: -3 dB\r\nChannel: L")
        }
        #expect(throws: PEQImportError.tooManyFilters) {
            try EqualizerAPOParser.parse(Array(repeating: "Filter: ON PK Fc 100 Hz Gain 3 dB Q 1", count: 17).joined(separator: "\n"))
        }
        #expect(throws: PEQImportError.invalidValue(1)) { try EqualizerAPOParser.parse("Filter: ON PK Fc 100 Hz Gain 3 dB Q 0") }
        #expect(throws: PEQImportError.tooLarge) { try EqualizerAPOParser.parse(String(repeating: " ", count: 65_537)) }
    }

    @Test func builtinCatalogIsCompleteAndValid() {
        #expect(EQCalibrationCatalog.entries.count == 8850)
        #expect(EQCalibrationCatalog.recommendedCount == 6033)
        #expect(Set(EQCalibrationCatalog.entries.map(\.measurementSource)).count == 23)
        #expect(Set(EQCalibrationCatalog.entries.map(\.id)).count == 8850)
        #expect(EQCalibrationCatalog.snapshotRevision == "7ae0f56d53074872b028649617a22bbb4232feb7")
        for entry in EQCalibrationCatalog.entries {
            #expect(entry.preset.isValid)
            #expect(entry.revision.count == 40)
            #expect(entry.url.hasPrefix("https://github.com/jaakkopasanen/AutoEq/"))
        }
        let sony = EQOutputDevice(id: "bluetooth-1", name: "WH-1000XM5", kind: .bluetooth)
        #expect(EQCalibrationCatalog.automaticPreset(for: sony)?.name == "Sony WH-1000XM5")
        #expect(EQCalibrationCatalog.automaticPreset(for: EQOutputDevice(id: "dac", name: "USB Audio DAC", kind: .usb)) == nil)
        #expect(EQCalibrationCatalog.automaticPreset(for: EQOutputDevice(id: "dac", name: "Simgot Audio EA500LM", kind: .usb)) == nil)
    }

    @Test func compressedCatalogDecompressesReusesCacheAndPrunesStaleCopies() throws {
        let compressed = try #require(Bundle.primuseKit.url(forResource: "AutoEqCatalog.sqlite", withExtension: "lzma"))
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-autoeq-cache-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let stale = cacheDir.appendingPathComponent("AutoEqCatalog-0000000000000000.sqlite")
        try Data("stale".utf8).write(to: stale)

        let first = try EQCalibrationCatalog.prepareDatabaseURL(compressedURL: compressed, cacheDirectory: cacheDir)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        let firstMTime = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date

        let second = try EQCalibrationCatalog.prepareDatabaseURL(compressedURL: compressed, cacheDirectory: cacheDir)
        #expect(second == first)
        let secondMTime = try FileManager.default.attributesOfItem(atPath: second.path)[.modificationDate] as? Date
        #expect(secondMTime == firstMTime)
    }

    @Test func modelSearchRanksExactMatchesAndKeepsEveryMeasurementSelectable() throws {
        let groups = EQCalibrationCatalog.searchModels("")
        #expect(groups.count == EQCalibrationCatalog.recommendedCount)
        #expect(groups.allSatisfy { $0.primary.recommended })
        #expect(Set(groups.flatMap { [$0.primary.id] + $0.alternatives.map(\.id) }).count == EQCalibrationCatalog.entries.count)
        #expect(EQCalibrationCatalog.searchModels("HD800S oratory1990").first?.id == "Sennheiser HD 800 S")
        let nozzles = EQCalibrationCatalog.searchModels("EA500LM")
        #expect(nozzles.count == 5)
        let black = try #require(nozzles.first { $0.id.contains("black nozzle") })
        #expect(black.primary.id == "autoeq.simgot.audio.ea500lm.black.nozzle")
        #expect(black.alternatives.count == 7)
        let filtered = EQCalibrationCatalog.searchModels("EA500LM black nozzle Harpo")
        #expect(filtered.count == 1)
        #expect(filtered.first?.primary.measurementSource == "Harpo")
        #expect(filtered.first?.alternatives.isEmpty == true)
    }

    @Test func pagesPreserveModelOrderAndSelectedMeasurementWithoutLoadingAllRows() throws {
        let results = EQCalibrationCatalog.matchingModels("")
        #expect(results.count == 6033)
        let first = results.models(in: 0..<64)
        let next = results.models(in: 64..<128)
        #expect(first.count == 64 && next.count == 64)
        #expect(Set((first + next).map(\.id)).count == 128)
        #expect(results.models(in: 63..<65).map(\.id) == [first.last?.id, next.first?.id])
        #expect(results.models(in: 6032..<6096).count == 1)
        #expect(results.models(in: 6096..<6100).isEmpty)
        let filtered = EQCalibrationCatalog.matchingModels("EA500LM black nozzle Harpo")
        #expect(filtered.models(in: 0..<64).first?.primary.measurementSource == "Harpo")
        #expect(EQCalibrationCatalog.automaticPreset(for: EQOutputDevice(id: "usb", name: "DTC480", kind: .usb)) == nil)
    }

    @Test func fullCatalogSearchKeepsSourcesVariantsAndExistingBindings() throws {
        let hd800 = EQCalibrationCatalog.search("HD800S oratory1990")
        #expect(hd800.contains { $0.name == "Sennheiser HD 800 S" && $0.recommended })
        #expect(hd800.allSatisfy { $0.measurementSource == "oratory1990" })
        #expect(EQCalibrationCatalog.search("Audeze Maxwell").count == 8)
        #expect(EQCalibrationCatalog.search("EA500LM black nozzle").count > 1)
        #expect(EQCalibrationCatalog.search("not-a-headphone-934875").isEmpty)
        let legacyIDs = ["autoeq.akg.k371", "autoeq.apple.airpods.3rd.generation", "autoeq.apple.airpods.4",
                         "autoeq.apple.airpods.max", "autoeq.apple.airpods.pro", "autoeq.apple.airpods.pro.2",
                         "autoeq.beyerdynamic.dt.770.pro.250.ohm", "autoeq.beyerdynamic.dt.770.pro.80.ohm",
                         "autoeq.moondrop.aria", "autoeq.sennheiser.hd.560s", "autoeq.sennheiser.hd.600",
                         "autoeq.sennheiser.hd.650", "autoeq.simgot.audio.ea500lm.black.nozzle",
                         "autoeq.simgot.audio.ea500lm.bronze.nozzle", "autoeq.simgot.audio.ea500lm.gold.nozzle",
                         "autoeq.simgot.audio.ea500lm.red.nozzle", "autoeq.sony.wf.1000xm4", "autoeq.sony.wf.1000xm5",
                         "autoeq.sony.wh.1000xm4", "autoeq.sony.wh.1000xm5", "autoeq.truthear.hexa"]
        var library = EQPresetLibrary()
        for id in legacyIDs {
            let preset = try #require(EQPreset.builtInPreset(withID: id))
            #expect(preset.parametric != nil)
            library.setBinding(device: EQOutputDevice(id: id, name: preset.name, kind: .usb), presetID: id)
        }
        #expect(EQPresetLibrary.decode(library.encoded()).bindings.count == 21)
    }

    @Test func oldLibraryAndParametricRoundTrip() throws {
        let old = Data(#"{"userPresets":[{"id":"user.old","name":"Old","bands":[0,0,0,0,0,0,0,0,0,0],"isBuiltIn":false}],"bindings":[],"currentBelongsToBoundDevice":false}"#.utf8)
        var library = EQPresetLibrary.decode(old)
        #expect(library.userPresets.count == 1)
        let peq = try EqualizerAPOParser.parse("Preamp: -5 dB\nFilter: ON PK Fc 5059 Hz Gain -3 dB Q 5.33")
        let added = library.addPreset(named: "My speakers", parametric: peq)
        let imported = try #require(added)
        let dac = EQOutputDevice(id: "dac", name: "USB DAC", kind: .usb)
        library.setBinding(device: dac, presetID: imported.id)
        library.customParametric = peq
        let restored = EQPresetLibrary.decode(library.encoded())
        #expect(restored == library)
        #expect(restored.userPreset(id: imported.id)?.parametric?.preamp == -5)
        #expect(restored.binding(for: "dac")?.presetID == imported.id)
    }

    @Test(arguments: [44_100.0, 48_000, 96_000, 192_000])
    func referenceResponsesAndNyquist(_ rate: Double) throws {
        let peak = EQBiquad(filter: PEQFilter(kind: .peak, frequency: 5059, gain: -6, q: 5.33), sampleRate: rate)
        #expect(abs(peak.gainDB(frequency: 5059, sampleRate: rate) + 6) < 1e-7)
        for kind in [PEQFilter.Kind.lowShelf, .highShelf] {
            let shelf = EQBiquad(filter: PEQFilter(kind: kind, frequency: 1000, gain: 6, q: 1.3), sampleRate: rate)
            #expect(abs(shelf.gainDB(frequency: 1000, sampleRate: rate) - 3) < 1e-7)
            let plateau = kind == .lowShelf ? 0.0 : rate / 2
            #expect(abs(shelf.gainDB(frequency: plateau, sampleRate: rate) - 6) < 1e-7)
        }
        let invalid = EQPreset(name: "Above Nyquist", bands: [], parametric: ParametricEQ(filters: [PEQFilter(kind: .peak, frequency: rate / 2, gain: 3, q: 1)]))
        #expect(EQRenderConfiguration.make(preset: invalid, sampleRate: rate, enabled: true) == nil)
    }

    @Test func headroomCoversResonanceAndPreservesImportedAttenuation() throws {
        let peq = ParametricEQ(preamp: -20, filters: [PEQFilter(kind: .highShelf, frequency: 17_000, gain: 8, q: 8)])
        let preset = EQPreset(name: "Shelf", bands: [], parametric: peq)
        let config = try #require(EQRenderConfiguration.make(preset: preset, sampleRate: 48_000, enabled: true))
        #expect(config.preampDB <= -20)
        for i in 0...12_000 {
            let frequency = Double(i) * 2
            let gain = config.filters.reduce(config.preampDB) { $0 + $1.gainDB(frequency: frequency, sampleRate: 48_000) }
            #expect(gain <= -0.99)
        }
    }

    #if os(iOS) || os(macOS)
    @Test func reallocatedRendererKeepsLastPublishedCurve() {
        let mailbox = EQRenderMailbox()
        mailbox.publish(EQRenderConfiguration(filters: [], preampDB: -6))
        do {
            let first = EQRealtimeProcessor(mailbox: mailbox, sampleRate: 48_000, channels: 1)
            first.beginBlock()
            #expect(abs(first.process(1, channel: 0) - 0.5011872) < 1e-6)
            first.endFrame()
        }
        let replacement = EQRealtimeProcessor(mailbox: mailbox, sampleRate: 48_000, channels: 1)
        replacement.beginBlock()
        #expect(abs(replacement.process(1, channel: 0) - 0.5011872) < 1e-6)
        replacement.endFrame()
    }
    @Test func streamingImpulseMatchesTransferFunctionAndChannelsStayIndependent() throws {
        let filter = EQBiquad(filter: PEQFilter(kind: .peak, frequency: 3000, gain: -9, q: 2), sampleRate: 48_000)
        let mailbox = EQRenderMailbox()
        mailbox.publish(EQRenderConfiguration(filters: [filter], preampDB: 0))
        let renderer = EQRealtimeProcessor(mailbox: mailbox, sampleRate: 48_000, channels: 2)
        var real = 0.0, imaginary = 0.0
        for i in 0..<16_384 {
            if i % 127 == 0 { renderer.beginBlock() }
            let left = renderer.process(i == 0 ? 1 : 0, channel: 0)
            #expect(renderer.process(0, channel: 1) == 0)
            renderer.endFrame()
            let phase = 2 * Double.pi * 3000 * Double(i) / 48_000
            real += Double(left) * cos(phase); imaginary -= Double(left) * sin(phase)
        }
        #expect(abs(20 * log10(hypot(real, imaginary)) + 9) < 0.0001)
    }

    @Test func rapidChangesRemainFiniteAndSettleToLatestPlan() {
        let mailbox = EQRenderMailbox()
        mailbox.publish(.flat)
        let renderer = EQRealtimeProcessor(mailbox: mailbox, sampleRate: 48_000, channels: 1)
        var previous: Float = 0.25
        for i in 0..<30_000 {
            if i > 0, i < 10_000, i % 31 == 0 {
                mailbox.publish(EQRenderConfiguration(filters: [], preampDB: i % 2 == 0 ? -12 : 0))
            }
            if i == 10_000 { mailbox.publish(EQRenderConfiguration(filters: [], preampDB: -6)) }
            if i % 64 == 0 { renderer.beginBlock() }
            let y = renderer.process(0.25, channel: 0)
            renderer.endFrame()
            #expect(y.isFinite && y >= 0 && y <= 0.25)
            #expect(abs(y - previous) < 0.001)
            previous = y
        }
        #expect(abs(previous - Float(0.25 * pow(10, -6.0 / 20))) < 1e-6)
    }
    #endif
}
