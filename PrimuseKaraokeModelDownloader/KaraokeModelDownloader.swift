import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// Lets the system fetch the karaoke AI vocal model, an Apple-hosted
/// on-demand asset pack. The app asks for it through `AssetPackManager`;
/// this extension only has to exist, so the default behaviour is kept.
@main
struct KaraokeModelDownloader: StoreDownloaderExtension {
    func shouldDownload(_ assetPack: AssetPack) -> Bool {
        true
    }
}
