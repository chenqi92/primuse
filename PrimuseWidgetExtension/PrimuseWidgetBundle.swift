import WidgetKit
import SwiftUI

@main
struct PrimuseWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        QuickAccessWidget()
    }
}
