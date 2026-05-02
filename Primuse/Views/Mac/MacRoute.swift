#if os(macOS)
import Foundation

enum MacRoute: Hashable {
    case home
    case section(LibrarySection)
    case source(String)
}
#endif
