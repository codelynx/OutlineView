import Foundation

/// A node in the file browser tree.
///
/// `children` lazily lists the directory on access. SwiftUI only reads it for
/// rows it actually renders, so this is fine for typical browsing; we'll add
/// caching if it ever becomes a hot path.
struct FileNode: Identifiable, Hashable {
    let url: URL

    var id: URL { url }
    var name: String { url.lastPathComponent }

    var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    var children: [FileNode]? {
        guard isDirectory else { return nil }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return contents
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(FileNode.init(url:))
    }
}
