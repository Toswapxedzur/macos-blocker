import Foundation
import MacBlockerCore
import VaultClassifierApp

/// Saves watched videos' authors (name and icon) and tags into the Activity
/// store (owner 2026-09-29), from what Mac Vault's classifier already knows —
/// it is only read, never asked to tag anything. Runs when a watched record
/// arrives, and again when Activity shows videos whose author icon or tags are
/// still missing (the classifier may have tagged the video since).
@MainActor
enum WatchedFactsRecorder {
    static func record(keys: [String], in store: ActivityStore) {
        guard !keys.isEmpty else { return }
        let authors = VaultClassifierPage.shared.watchedAuthors(keys: keys)
        let tags = VaultClassifierPage.shared.watchedTags(keys: keys)
        store.recordWatchedFacts(keys.compactMap { key in
            let author = authors[key]
            let found = tags[key]?.map { ActivityTag(id: $0["id"] ?? "", name: $0["name"] ?? "", color: $0["color"] ?? "") }
            guard author != nil || found != nil else { return nil }
            return ActivityWatchedEntry(videoKey: key, authorID: author?["id"], authorName: author?["name"],
                                        authorIcon: author?["icon"], tags: found)
        })
    }
}
