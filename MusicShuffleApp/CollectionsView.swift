// filepath: /Users/akshayj/GitHubRepos/SmartShuffle/MusicShuffleApp/CollectionsView.swift
import SwiftUI
import MediaPlayer

struct CollectionsTabView: View {
    @EnvironmentObject private var collectionsStore: CollectionsStore
    @EnvironmentObject private var mediaStore: MediaLibraryStore
    @ObservedObject var musicPlayerHelper: MusicPlayerHelper

    @State private var showingEditor = false
    @State private var editorMode: EditorMode = .create
    @State private var editingCollection: PlaylistCollection? = nil
    @State private var showDeleteConfirm = false

    enum EditorMode { case create, edit }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationView {
            VStack(alignment: .leading) {
                HStack {
                    Text("Collections")
                        .font(.largeTitle).bold()
                    Spacer()
                    Button(action: {
                        editingCollection = nil
                        editorMode = .create
                        showingEditor = true
                    }) {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding([.top, .horizontal])

                if collectionsStore.collections.isEmpty {
                    VStack(spacing: 12) {
                        Text("No collections yet")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Button(action: {
                            editingCollection = nil
                            editorMode = .create
                            showingEditor = true
                        }) {
                            Label("Add Collection", systemImage: "plus")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(collectionsStore.collections) { col in
                                CollectionCard(collection: col,
                                               playlistsResolver: { ids in
                                                   resolvePlaylists(for: ids)
                                               },
                                               playAction: { playCollection(col) },
                                               editAction: {
                                                   editingCollection = col
                                                   editorMode = .edit
                                                   showingEditor = true
                                               },
                                               deleteAction: {
                                                   editingCollection = col
                                                   showDeleteConfirm = true
                                               })
                            }
                        }
                        .padding(12)
                    }
                }

                NowPlayingView(song: musicPlayerHelper.currentSong)
            }
            .onAppear {
                mediaStore.requestAuthorizationAndLoad()
            }
            .confirmationDialog("Delete Collection?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let target = editingCollection { collectionsStore.removeCollection(target) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will remove the collection from the app.")
            }
            .sheet(isPresented: $showingEditor) {
                CollectionsEditorView(mode: editorMode,
                                      original: editingCollection,
                                      onSave: { result in
                                          switch result {
                                          case .create(let name, let ids):
                                              collectionsStore.addCollection(name: name, playlistIDs: ids)
                                          case .edit(let updated):
                                              collectionsStore.updateCollection(updated)
                                          }
                                      })
                .environmentObject(mediaStore)
            }
        }
    }

    private func resolvePlaylists(for ids: [UInt64]) -> [MPMediaPlaylist] {
        let all = mediaStore.playlists
        let set = Set(ids)
        let found = all.filter { set.contains($0.persistentID) }
        return found
    }

    private func playCollection(_ collection: PlaylistCollection) {
        let candidates = resolvePlaylists(for: collection.playlistIDs)
        guard let random = candidates.randomElement() else { return }
        let songs = random.items
        guard !songs.isEmpty else { return }
        musicPlayerHelper.nonShuffledSongs = songs
        musicPlayerHelper.shuffleSongs()
        musicPlayerHelper.shuffledSongs = musicPlayerHelper.shuffledSongs
        musicPlayerHelper.playSongs()
    }
}

private struct CollectionCard: View {
    let collection: PlaylistCollection
    let playlistsResolver: ([UInt64]) -> [MPMediaPlaylist]
    let playAction: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        let playlists = playlistsResolver(collection.playlistIDs)
        let count = playlists.count

        VStack(alignment: .leading, spacing: 8) {
            Text(collection.name)
                .font(.headline)
                .foregroundColor(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            HStack {
                Label("\(count)", systemImage: "music.note.list")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.blue.opacity(0.18)))
        .onTapGesture { playAction() }
        .contextMenu {
            Button("Play Collection", action: playAction)
            Button("Edit Collection", action: editAction)
            Button(role: .destructive) { deleteAction() } label: { Text("Delete Collection") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Collection \(collection.name), \(count) playlists")
    }
}

// MARK: - Editor

struct CollectionsEditorView: View {
    enum Result {
        case create(name: String, playlistIDs: [UInt64])
        case edit(PlaylistCollection)
    }

    let mode: CollectionsTabView.EditorMode
    let original: PlaylistCollection?
    let onSave: (Result) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var mediaStore: MediaLibraryStore

    @State private var step: Int = 1 // 1=name, 2=select
    @State private var name: String = ""
    @State private var selectedIDs: Set<UInt64> = []

    var body: some View {
        NavigationView {
            Group {
                if step == 1 {
                    nameStep
                } else {
                    selectPlaylistsStep
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step == 1 {
                        Button("Next") { step = 2 }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button("Save") { save() }
                            .disabled(selectedIDs.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .onAppear {
            if mode == .edit, let original = original {
                name = original.name
                selectedIDs = Set(original.playlistIDs)
                step = 2
            }
        }
    }

    private var nameStep: some View {
        Form {
            Section(header: Text("Collection Name")) {
                TextField("Enter name", text: $name)
            }
            Section(footer: Text("You'll choose playlists next.")) { EmptyView() }
        }
    }

    private var selectPlaylistsStep: some View {
        List(mediaStore.playlists, id: \.persistentID) { pl in
            Button(action: {
                let id = pl.persistentID
                if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
            }) {
                HStack {
                    Image(systemName: selectedIDs.contains(pl.persistentID) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selectedIDs.contains(pl.persistentID) ? .blue : .gray)
                    Text(pl.name ?? "Unknown")
                    Spacer()
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Select Playlists")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(name).font(.headline)
            }
        }
    }

    private func save() {
        let ids = Array(selectedIDs)
        switch mode {
        case .create:
            onSave(.create(name: name, playlistIDs: ids))
        case .edit:
            if var original = original {
                original.name = name
                original.playlistIDs = ids
                onSave(.edit(original))
            } else {
                onSave(.create(name: name, playlistIDs: ids))
            }
        }
        dismiss()
    }
}
