import Foundation
import XCTest
@testable import TidyCore

enum TestSupport {
    static func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TidyTests-\(UUID().uuidString)", isDirectory: true)
        return try makeDirectory(url)
    }

    @discardableResult
    static func makeDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func makeFile(_ url: URL, contents: String = "x") throws -> URL {
        try Data(contents.utf8).write(to: url)
        return url
    }

    static func facts(_ url: URL) throws -> FileFacts {
        try XCTUnwrap(FileFacts.read(url))
    }

    /// Sets both timestamps; FileManager can only set the modification date.
    static func setTimes(_ url: URL, modified: Date, accessed: Date) {
        var times = [
            timeval(tv_sec: Int(accessed.timeIntervalSince1970), tv_usec: 0),
            timeval(tv_sec: Int(modified.timeIntervalSince1970), tv_usec: 0),
        ]
        utimes(url.path, &times)
    }

    /// Downloads-style routing with a catch-all last, mirroring the shipped rules.
    static func downloadRules(in downloads: URL) -> [Rule] {
        [
            Rule(
                name: "code",
                watch: [downloads.path],
                match: Match(extensions: ["py", "js", "json"]),
                destination: downloads.path + "/Code"
            ),
            Rule(
                name: "images",
                watch: [downloads.path],
                match: Match(extensions: ["png", "jpg"]),
                destination: downloads.path + "/Images"
            ),
            Rule(
                name: "other",
                watch: [downloads.path],
                destination: downloads.path + "/Random"
            ),
        ]
    }
}
