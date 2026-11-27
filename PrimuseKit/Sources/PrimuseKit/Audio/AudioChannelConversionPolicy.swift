import Foundation

public enum AudioChannelConversionPolicy {
    public static func requiresDownmix(
        sourceChannelCount: Int,
        outputChannelCount: Int
    ) -> Bool {
        sourceChannelCount > outputChannelCount && outputChannelCount > 0
    }
}
