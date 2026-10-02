#if canImport(BackgroundAssets) && !os(watchOS)
import BackgroundAssets

@available(iOS 26.4, macOS 26.4, tvOS 26.4, *)
public enum AppleHostedAssetPackResolver {
    public static func assetPack(withID id: String, manager: AssetPackManager) async throws -> AssetPack {
        try await resolve(
            withID: id,
            lookup: { try await manager.assetPack(withID: $0) },
            refresh: { _ = try await manager.checkForUpdates() }
        )
    }

    static func resolve<Pack: Sendable>(
        withID id: String,
        lookup: @Sendable (String) async throws -> Pack,
        refresh: @Sendable () async throws -> Void
    ) async throws -> Pack {
        try Task.checkCancellation()
        do {
            return try await lookup(id)
        } catch ManagedBackgroundAssetsError.assetPackNotFound(let missingID) where missingID == id {
            // A pack published after installation can be absent from the cached manifest.
            // Refresh once; repeating the cached lookup alone never discovers that pack.
            try Task.checkCancellation()
            try await refresh()
            try Task.checkCancellation()
            return try await lookup(id)
        }
    }
}
#endif
