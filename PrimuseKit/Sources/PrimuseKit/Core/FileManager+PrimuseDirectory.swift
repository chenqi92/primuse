import Foundation

public extension FileManager {
    /// Search-path APIs normally return one URL on Apple platforms, but using
    /// `.first!` turns an unusual container/filesystem failure into a process
    /// trap. Temporary storage is a safe last-resort location for startup.
    func primuseDirectoryURL(for directory: SearchPathDirectory) -> URL {
        urls(for: directory, in: .userDomainMask).first ?? temporaryDirectory
    }
}
