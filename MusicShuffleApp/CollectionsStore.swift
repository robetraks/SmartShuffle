// filepath: /Users/akshayj/GitHubRepos/SmartShuffle/MusicShuffleApp/CollectionsStore.swift
import Foundation
import MediaPlayer
import Combine

struct PlaylistCollection: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var playlistIDs: [UInt64]
}

final class CollectionsStore: ObservableObject {
    @Published var collections: [PlaylistCollection] = [] {
        didSet { save() }
    }

    private let storageKey = "PlaylistCollections_v1"

    init() {
        load()
    }

    func addCollection(name: String, playlistIDs: [UInt64]) {
        let c = PlaylistCollection(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), playlistIDs: playlistIDs)
        collections.append(c)
    }

    func updateCollection(_ collection: PlaylistCollection) {
        if let idx = collections.firstIndex(where: { $0.id == collection.id }) {
            collections[idx] = collection
        }
    }

    func removeCollection(_ collection: PlaylistCollection) {
        collections.removeAll { $0.id == collection.id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(collections) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([PlaylistCollection].self, from: data) {
            collections = decoded
        }
    }
}
