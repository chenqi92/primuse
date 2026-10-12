import AVFoundation

extension AVAudioConverter {
    /// Switches a playback converter to the mastering-grade sample rate
    /// converter. The default (normal algorithm, medium quality) starts rolling
    /// off around 18 kHz and is 7 dB down at 20 kHz going 44.1 → 48 kHz, in
    /// either direction; mastering at high quality stays flat to 20 kHz. Output
    /// frame count and alignment are the same, so gapless boundaries and the
    /// playback clock are unaffected. Cost measured on macOS 27: about 6 ms of
    /// CPU per second of 44.1 ↔ 48 kHz stereo, 24 ms for 192 → 48 kHz.
    /// Converters that keep the sample rate are left as they are.
    func usePlaybackResampling() {
        guard abs(inputFormat.sampleRate - outputFormat.sampleRate) >= 1 else { return }
        sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        sampleRateConverterQuality = AVAudioQuality.high.rawValue
    }
}
