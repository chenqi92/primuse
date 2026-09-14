import Foundation
import Testing
@testable import PrimuseKit

struct ServerCatalogAutoRefreshPolicyTests {
    @Test func everySubsonicFamilyMemberGetsTheStatusProbe() {
        // All four are served by the same connector, which implements
        // getScanStatus, so the capability is family-wide.
        for type in [MusicSourceType.subsonic, .navidrome, .airsonic, .gonic] {
            #expect(ServerCatalogAutoRefreshPolicy.supportsStatusProbe(type))
            #expect(ServerCatalogAutoRefreshPolicy.supportsServerScanRequest(type))
        }
    }

    @Test func sourcesThatCanOnlyRelistStayBehindAnExplicitScan() {
        // A directory walk is a scan however incrementally it reconciles, and a
        // background wake must never turn into a NAS-wide traversal.
        for type in [
            MusicSourceType.webdav, .smb, .ftp, .sftp, .nfs, .s3, .upnp,
            .synology, .qnap, .ugreen, .fnos, .local, .baiduPan,
        ] {
            #expect(!ServerCatalogAutoRefreshPolicy.supportsStatusProbe(type))
        }
    }

    @Test func mediaServersWithoutAChangeMarkerAreNotProbedYet() {
        // Jellyfin/Emby/Plex have no equivalent of getScanStatus wired up, so
        // they must not be treated as probe-capable.
        for type in [MusicSourceType.jellyfin, .emby, .plex, .fnMusic, .daoliyu, .songloft] {
            #expect(!ServerCatalogAutoRefreshPolicy.supportsStatusProbe(type))
        }
    }

    @Test func nativeCursorSourcesKeepTheirOwnPeriodicPath() {
        // Cloud drives refresh from a durable changes cursor on a 6-hour
        // cadence; they must not also be pulled into the status-probe path.
        for type in [MusicSourceType.dropbox, .googleDrive, .oneDrive] {
            #expect(SourcePeriodicSyncPolicy.supportsAutomaticRefresh(type))
            #expect(!ServerCatalogAutoRefreshPolicy.supportsStatusProbe(type))
        }
    }

    @Test func theTwoAutomaticPathsNeverOverlap() {
        for type in MusicSourceType.allCases {
            #expect(!(
                ServerCatalogAutoRefreshPolicy.supportsStatusProbe(type)
                    && SourcePeriodicSyncPolicy.supportsAutomaticRefresh(type)
            ))
        }
    }

    @Test func probeCooldownStaysConservative() {
        #expect(ServerCatalogAutoRefreshPolicy.checkCooldown == 15 * 60)
    }
}
