#if os(macOS)
import SwiftUI
import PrimuseKit

struct MacSidebar: View {
    @Binding var selection: MacRoute
    @Environment(SourcesStore.self) private var sourcesStore

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("home_title", systemImage: "house.fill")
                    .tag(MacRoute.home)
                Label("search_title", systemImage: "magnifyingglass")
                    .tag(MacRoute.search)
            }

            Section("library_title") {
                ForEach(LibrarySection.allCases, id: \.self) { section in
                    Label {
                        Text(section.title)
                    } icon: {
                        Image(systemName: section.icon)
                            .foregroundStyle(section.color)
                    }
                    .tag(MacRoute.section(section))
                }
            }

            if !sourcesStore.sources.isEmpty {
                Section("manage_sources") {
                    ForEach(sourcesStore.sources, id: \.id) { source in
                        Label {
                            Text(source.name)
                        } icon: {
                            Image(systemName: source.type.iconName)
                                .foregroundStyle(.secondary)
                        }
                        .tag(MacRoute.source(source.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
#endif
