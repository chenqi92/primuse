#if canImport(AVFAudio) && !os(watchOS)
import AudioToolbox
import AVFAudio

/// A fixed processing chain. Owners serialize configuration with their playback graph.
public final class PlaybackTimePitchProcessor: @unchecked Sendable {
    public let timeDomainNode: AVAudioUnitTimeEffect?
    public let spectralNode: AVAudioUnitTimePitch
    public var inputNode: AVAudioNode { timeDomainNode ?? spectralNode }

    enum Algorithm { case bypass, timeDomain, spectral }
    private(set) var algorithm: Algorithm = .bypass
    private struct Configuration: Equatable {
        var rate: Float
        var pitch: Float
        var isSpokenWord: Bool
    }
    private var configuration: Configuration?

    public convenience init(spectralOverlap: Float = 8) {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter,
            componentSubType: kAudioUnitSubType_AUiPodTimeOther,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let node: AVAudioUnitTimeEffect?
        if AudioComponentFindNext(nil, &description) != nil {
            node = AVAudioUnitTimeEffect(audioComponentDescription: description)
        } else {
            node = nil
        }
        self.init(timeDomainNode: node, spectralOverlap: spectralOverlap)
    }

    init(timeDomainNode: AVAudioUnitTimeEffect?, spectralOverlap: Float = 8) {
        self.timeDomainNode = timeDomainNode
        spectralNode = AVAudioUnitTimePitch()
        spectralNode.overlap = spectralOverlap
        spectralNode.bypass = true
        timeDomainNode?.bypass = true
    }

    /// Speech and unpitched music acceleration use time-domain stretching. Music
    /// slowdown and key shifts retain spectral processing; only one unit stretches time.
    public func apply(rate: Float, pitchCents: Float = 0, isSpokenWord: Bool = false) {
        let next = Configuration(
            rate: rate.isFinite ? min(2, max(0.5, rate)) : 1,
            pitch: pitchCents.isFinite ? min(2400, max(-2400, pitchCents)) : 0,
            isSpokenWord: isSpokenWord
        )
        guard next != configuration else { return }
        configuration = next
        var target: Algorithm = .spectral
        if next.pitch == 0, next.rate == 1 {
            target = .bypass
        } else if next.pitch == 0, next.isSpokenWord || next.rate > 1,
                  let timeDomainNode,
                  AudioUnitSetParameter(
                    timeDomainNode.audioUnit, kTimePitchParam_Rate,
                    kAudioUnitScope_Global, 0, next.rate, 0
                  ) == noErr {
            target = .timeDomain
        }

        if target != algorithm {
            // Disable the outgoing unit before enabling another, so the rates
            // never multiply. A previously bypassed unit must not replay its tail.
            timeDomainNode?.bypass = true
            spectralNode.bypass = true
            switch target {
            case .timeDomain: timeDomainNode?.reset()
            case .spectral: spectralNode.reset()
            case .bypass: break
            }
        }
        spectralNode.rate = target == .spectral ? next.rate : 1
        spectralNode.pitch = target == .spectral ? next.pitch : 0
        spectralNode.bypass = target != .spectral
        timeDomainNode?.bypass = target != .timeDomain
        algorithm = target
    }

    /// Call while the graph is silent, alongside the other effects after seek or restart.
    public func reset() {
        timeDomainNode?.reset()
        spectralNode.reset()
    }
}
#endif
