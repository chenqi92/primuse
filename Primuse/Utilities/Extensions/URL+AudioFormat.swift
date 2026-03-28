import Foundation
import PrimuseKit

extension URL {
    var audioFormat: AudioFormat? {
        AudioFormat.from(fileExtension: pathExtension)
    }

    var isAudioFile: Bool {
        PrimuseConstants.supportedAudioExtensions.contains(pathExtension.lowercased())
    }
}
