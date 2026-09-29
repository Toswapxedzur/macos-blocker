import Foundation
import MacBlockerCore
import VaultClassifierApp

/// Records watched videos' authors — name and icon — into the Activity store
/// (owner 2026-09-29), from what Mac Vault's classifier collected. Runs when a
/// watched record arrives and again when Activity shows videos whose author or
/// icon is still missing (the icon may still have been downloading).
@MainActor
enum WatchedAuthorRecorder {
    static func record(keys: [String], in store: ActivityStore) {
        guard !keys.isEmpty else { return }
        let found = VaultClassifierPage.shared.watchedAuthors(keys: keys)
        store.recordAuthors(found.compactMap { key, author in
            guard let id = author["id"], let name = author["name"] else { return nil }
            return ActivityAuthorEntry(videoKey: key, authorID: id, name: name, icon: author["icon"])
        })
    }
}
