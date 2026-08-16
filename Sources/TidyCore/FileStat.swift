import Foundation

/// Uncached file metadata.
///
/// `URL.resourceValues` caches its answers on the URL instance, so asking the same URL for
/// a size or timestamp twice returns the first reading. Every repeated check - the settle
/// sampling and the rules-file change detection - has to go through here instead.
enum FileStat {
    static func size(of url: URL) -> Int64? {
        attributes(of: url)?[.size] as? Int64
    }

    static func modified(of url: URL) -> Date? {
        attributes(of: url)?[.modificationDate] as? Date
    }

    private static func attributes(of url: URL) -> [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: url.path)
    }
}
