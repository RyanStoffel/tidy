import Foundation
import TidyCore

/// Watches one directory for changes using kernel file-system events via DispatchSource.
/// No polling: the handler fires as soon as an entry is added, removed or renamed.
final class DirectoryWatcher {
    let url: URL
    private let descriptor: Int32
    private var source: DispatchSourceFileSystemObject?

    /// `onChange` fires when the directory's contents change. `onInvalidate` fires when the
    /// directory itself is deleted or renamed, meaning the watch has to be re-established.
    init?(
        url: URL,
        queue: DispatchQueue,
        onChange: @escaping (URL) -> Void,
        onInvalidate: @escaping (URL) -> Void
    ) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.url = url
        descriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak source] in
            guard let events = source?.data else { return }
            if events.contains(.write) { onChange(url) }
            if !events.isDisjoint(with: [.delete, .rename, .revoke]) { onInvalidate(url) }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    func cancel() {
        source?.cancel()
        source = nil
    }
}

/// Keeps one watcher per directory alive, adding and dropping them as rules change or as
/// directories appear and disappear.
final class WatchSet {
    private var watchers: [String: DirectoryWatcher] = [:]
    private let queue: DispatchQueue
    private let onChange: (URL) -> Void

    init(queue: DispatchQueue, onChange: @escaping (URL) -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    var watchedCount: Int { watchers.count }

    /// Watches exactly the directories in `urls` that currently exist. Called on launch,
    /// after a rules reload, and on a timer so folders created later get picked up.
    func reconcile(_ urls: [URL]) {
        let wanted = Dictionary(
            urls.map { (Paths.canonical($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (key, watcher) in watchers where wanted[key] == nil {
            watcher.cancel()
            watchers[key] = nil
        }
        for (key, url) in wanted where watchers[key] == nil {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            watchers[key] = DirectoryWatcher(
                url: url,
                queue: queue,
                onChange: onChange,
                onInvalidate: { [weak self] invalidated in
                    DispatchQueue.main.async { self?.drop(invalidated) }
                }
            )
        }
    }

    func cancelAll() {
        watchers.values.forEach { $0.cancel() }
        watchers.removeAll()
    }

    private func drop(_ url: URL) {
        let key = Paths.canonical(url)
        watchers[key]?.cancel()
        watchers[key] = nil
    }
}
