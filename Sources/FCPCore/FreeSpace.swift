import Foundation

extension Doctor {
    /// Automatic backups that can go: for each folder of backups, everything but the newest `keep`.
    /// Final Cut names them by date (20261029_1123_GMT+1.fcpbundle), so the name sorts by age.
    public static func oldBackups(_ backups: [Library], keep: Int = 3) -> [Library] {
        let byFolder = Dictionary(grouping: backups) { $0.url.deletingLastPathComponent() }
        return byFolder.values.flatMap { group in
            group.sorted { $0.name > $1.name }.dropFirst(max(0, keep))
        }.sorted { $0.url.path < $1.url.path }
    }
}
