import Foundation

/// Keeps the selected immersive group stable. Missing lyrics or artwork are
/// handled inside the scene so choosing one group never opens another group.
public enum ImmersivePresentationFallbackPolicy {
    public static func effectiveEffectRawValue(
        selectedRawValue: String,
        hasSynchronizedLyrics: Bool,
        hasArtwork: Bool
    ) -> String {
        _ = hasSynchronizedLyrics
        _ = hasArtwork
        let supported = [
            "native", "coverGallery", "flowingLines", "radialPulse",
            "vinylDeck", "auroraVeil", "spectrumHorizon", "particleBloom",
            "albumFlow", "chladniPlate", "fireflySync", "flyBrain",
            "kineticLyrics", "watercolorStorybook", "watercolorTheater",
        ]
        if supported.contains(selectedRawValue) {
            return selectedRawValue
        }

        switch selectedRawValue {
        case "coverFlow", "cover", "deepField", "ambientBloom", "amberDust", "jadeMoss", "sectionIndigo",
             "duotone", "daylight", "ambientRefined", "editorial", "coverDriven":
            return "coverGallery"
        case "coverWall":
            return "coverGallery"
        case "contour":
            return "flowingLines"
        case "lightRhythm", "lightField", "liquidChrome":
            return "auroraVeil"
        case "auroraDrift", "starryNight", "starField":
            return "auroraVeil"
        case "kineticTitle", "typography", "typeWall", "lyricStage", "lyrics":
            return "flowingLines"
        case "radialSpectrum":
            return "radialPulse"
        case "vinyl", "compactDisc":
            return "vinylDeck"
        case "liveWaveform", "spectrum", "visualizer", "mirrorStage":
            return "spectrumHorizon"
        default:
            return "coverGallery"
        }
    }
}
