import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// Lets the system fetch the app's Apple-hosted on-demand asset packs: the
/// karaoke AI vocal model and the offline lyric translation model. The app
/// asks for them through `AssetPackManager`; this extension only has to
/// exist, so the default behaviour is kept.
@main
struct KaraokeModelDownloader: StoreDownloaderExtension {
    func shouldDownload(_ assetPack: AssetPack) -> Bool {
        true
    }
}
