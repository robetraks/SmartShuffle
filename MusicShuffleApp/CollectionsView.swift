// filepath: /Users/akshayj/GitHubRepos/SmartShuffle/MusicShuffleApp/CollectionsView.swift
import SwiftUI
import MediaPlayer
import UIKit

struct CollectionsTabView: View {
    @EnvironmentObject private var collectionsStore: CollectionsStore
    @EnvironmentObject private var mediaStore: MediaLibraryStore
    @ObservedObject var musicPlayerHelper: MusicPlayerHelper

    @State private var showingEditor = false
    @State private var editorMode: EditorMode = .create
    @State private var editingCollection: PlaylistCollection? = nil
    @State private var showDeleteConfirm = false

    enum EditorMode { case create, edit }

    // Use adaptive grid for better density on wider screens
    private let gridColumns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 12)
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
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Group playlists into collections and play one at random.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        Button(action: {
                            editingCollection = nil
                            editorMode = .create
                            showingEditor = true
                        }) {
                            Label("Create your first collection", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
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
        // Haptic pre-play feedback
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        musicPlayerHelper.nonShuffledSongs = songs
        musicPlayerHelper.shuffleSongs()
        musicPlayerHelper.shuffledSongs = musicPlayerHelper.shuffledSongs
        musicPlayerHelper.playSongs()
        // Success haptic
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

private struct CollectionCard: View {
    let collection: PlaylistCollection
    let playlistsResolver: ([UInt64]) -> [MPMediaPlaylist]
    let playAction: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void

    @State private var tapBump: Bool = false

    var body: some View {
        let playlists = playlistsResolver(collection.playlistIDs)
        let count = playlists.count
        let totalTracks = playlists.reduce(0) { $0 + $1.items.count }
        let hueColor = colorForString(collection.name)
        let bgGradient = LinearGradient(colors: [hueColor.opacity(0.30), hueColor.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
        let collage = artworkImages(from: playlists)

        ZStack(alignment: .bottomTrailing) {
            // Background layer with gradient, subtle stroke and shadow
            RoundedRectangle(cornerRadius: 16)
                .fill(bgGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 8) {
                // Artwork collage
                if !collage.isEmpty {
                    ArtworkCollageView(images: collage)
                        .frame(height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(LinearGradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.15)], startPoint: .top, endPoint: .bottom))
                        )
                } else {
                    // Placeholder symbol when no artwork
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.08))
                        Image(systemName: "square.grid.2x2")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .frame(height: 72)
                }

                // Title
                Text(collection.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)

                // Metadata chips: playlists + total tracks
                HStack(spacing: 8) {
                    Chip(text: "\(count) playlists")
                    Chip(text: "\(totalTracks) tracks")
                    Spacer()
                }
            }
            .padding(12)

            // Play affordance glyph
            Image(systemName: "play.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                .padding(10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .scaleEffect(tapBump ? 0.98 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: tapBump)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture {
            tapBump = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                tapBump = false
            }
            playAction()
        }
        .contextMenu {
            Button(action: playAction) { Label("Play Collection", systemImage: "play.circle") }
            Button(action: editAction) { Label("Edit Collection", systemImage: "pencil") }
            Button(role: .destructive) { deleteAction() } label: { Label("Delete Collection", systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Collection \(collection.name), \(count) playlists, \(totalTracks) tracks")
    }

    private func colorForString(_ s: String) -> Color {
        var hasher = Hasher()
        hasher.combine(s)
        let hash = hasher.finalize()
        let hue = Double(abs(hash % 360)) / 360.0
        return Color(hue: hue, saturation: 0.65, brightness: 0.70)
    }

    private func artworkImages(from playlists: [MPMediaPlaylist]) -> [UIImage] {
        var images: [UIImage] = []
        for pl in playlists {
            if images.count >= 4 { break }
            if let img = pl.items.first?.artwork?.image(at: CGSize(width: 80, height: 80)) {
                images.append(img)
            }
        }
        return images
    }
}

private struct ArtworkCollageView: View {
    let images: [UIImage]
    var body: some View {
        let imgs = Array(images.prefix(4))
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let halfW = w / 2
            let halfH = h / 2
            ZStack {
                if imgs.indices.contains(0) {
                    Image(uiImage: imgs[0]).resizable().scaledToFill()
                        .frame(width: halfW, height: halfH).clipped()
                        .position(x: halfW/2, y: halfH/2)
                }
                if imgs.indices.contains(1) {
                    Image(uiImage: imgs[1]).resizable().scaledToFill()
                        .frame(width: halfW, height: halfH).clipped()
                        .position(x: w - halfW/2, y: halfH/2)
                }
                if imgs.indices.contains(2) {
                    Image(uiImage: imgs[2]).resizable().scaledToFill()
                        .frame(width: halfW, height: halfH).clipped()
                        .position(x: halfW/2, y: h - halfH/2)
                }
                if imgs.indices.contains(3) {
                    Image(uiImage: imgs[3]).resizable().scaledToFill()
                        .frame(width: halfW, height: halfH).clipped()
                        .position(x: w - halfW/2, y: h - halfH/2)
                }
            }
        }
    }
}

private struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.white.opacity(0.95))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.25)))
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
