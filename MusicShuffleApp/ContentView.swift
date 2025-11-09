import SwiftUI
import MediaPlayer
import AVFoundation
import UIKit

@main
struct MusicShuffleApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var mediaStore = MediaLibraryStore()
    // Add CollectionsStore so Collections tab can access persisted collections
    @StateObject private var collectionsStore = CollectionsStore()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mediaStore)
                .environmentObject(collectionsStore)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Take snapshot asynchronously to avoid blocking the main thread at activation
                PlayCountSnapshotStore.shared.ensureRecentSnapshot()
            }
        }
    }
}
func calculatePPM(_ song: MPMediaItem) -> Double {
    guard let addedDate = song.value(forKey: "dateAdded") as? Date else { return .nan }
    let months = Calendar.current.dateComponents([.month], from: addedDate, to: Date()).month ?? 0
    if months == 0 { return .nan }
    return Double(song.playCount - song.skipCount) / Double(months)
}

struct ContentView: View {
    @EnvironmentObject private var mediaStore: MediaLibraryStore
    @State private var selectedPlaylist: MPMediaPlaylist? = nil
    @State private var showError = false
    @State private var errorMessage = ""
    @StateObject private var musicPlayerHelper = MusicPlayerHelper()
    
    var body: some View {
        TabView {
            // Tab 1: Playlists (existing functionality)
            NavigationView {
                VStack {
                    PlaylistStatsView(selectedPlaylist: $selectedPlaylist, playlists: mediaStore.playlists, musicPlayerHelper: musicPlayerHelper)
                        .onAppear {
                            mediaStore.requestAuthorizationAndLoad()
                        }
                    NowPlayingView(song: musicPlayerHelper.currentSong)
                }
            }
            .tabItem {
                Label("Playlists", systemImage: "music.note.list")
            }

            // New Tab: Collections
            NavigationView {
                CollectionsTabView(musicPlayerHelper: musicPlayerHelper)
            }
            .tabItem {
                Label("Collections", systemImage: "square.grid.2x2")
            }

            // Tab 2: Stats
            NavigationView {
                VStack {
                    StatsView()
                    NowPlayingView(song: musicPlayerHelper.currentSong)
                }
            }
            .tabItem {
                Label("Stats", systemImage: "chart.bar")
            }
        }
        .onChange(of: mediaStore.authorizationErrorMessage) { _, newMsg in
            if let msg = newMsg {
                errorMessage = msg
                showError = true
            } else {
                showError = false
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }
}

 // MARK: - Play History Store

 struct PlayEvent: Codable, Hashable {
     let songPersistentID: UInt64
     let timestamp: Date
 }

 final class PlayHistoryStore: ObservableObject {
     static let shared = PlayHistoryStore()
     private let storageKey = "PlayHistoryEvents_v1"
     @Published private(set) var events: [PlayEvent] = []

     private init() {
         load()
     }

     func recordPlay(_ item: MPMediaItem?) {
         guard let item = item else { return }
         let ev = PlayEvent(songPersistentID: item.persistentID, timestamp: Date())
         events.append(ev)
         save()
     }

     func reset(from date: Date) {
         // No-op: we keep all events; filtering is done at query time relative to a "custom start" date
         // Keeping events lets us show stats for any window later.
     }

     private func save() {
         do {
             let data = try JSONEncoder().encode(events)
             UserDefaults.standard.set(data, forKey: storageKey)
         } catch {
             // Ignore save failures silently for now
         }
     }

     private func load() {
         guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
         if let loaded = try? JSONDecoder().decode([PlayEvent].self, from: data) {
             events = loaded
         }
     }
 }

// MARK: - System PlayCount Snapshot Store (system-history only)
struct PlayCountSnapshot: Codable {
    let date: Date
    let counts: [UInt64: Int]  // persistentID -> playCount
}

final class PlayCountSnapshotStore: ObservableObject {
    static let shared = PlayCountSnapshotStore()
    private let snapshotsKey = "PlayCountSnapshots_v1"
    private let customBaselineKey = "CustomBaselineSnapshot_v1"
    @Published private(set) var snapshots: [PlayCountSnapshot] = [] // sorted asc; at most 1/day; up to ~90 days retained
    @Published var isSnapshotInProgress: Bool = false

    private func isSameDay(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, inSameDayAs: b)
    }

    private init() { load() }

    // Take a new snapshot from system media library
    @discardableResult
    func takeSnapshot(date: Date = Date()) -> PlayCountSnapshot? {
        let songs = MPMediaQuery.songs().items ?? []
        guard !songs.isEmpty else { return nil }
        var map: [UInt64: Int] = [:]
        map.reserveCapacity(songs.count)
        for it in songs {
            map[it.persistentID] = it.playCount
        }
        let snap = PlayCountSnapshot(date: date, counts: map)

        // Keep at most one snapshot per calendar day: replace the existing one for today if present
        if let idx = snapshots.lastIndex(where: { isSameDay($0.date, date) }) {
            snapshots[idx] = snap
        } else {
            snapshots.append(snap)
        }
        snapshots.sort { $0.date < $1.date }

        // Trim by number of distinct days retained (e.g., last 90 days)
        trimByDays(maxDays: 90)
        save()
        return snap
    }

    // Async variant: performs the heavy media query on a background queue and updates snapshots on the main actor.
    func takeSnapshotAsync(date: Date = Date()) {
        // Prevent concurrent runs
        if isSnapshotInProgress {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.isSnapshotInProgress = true
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let songs = MPMediaQuery.songs().items ?? []
            if songs.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.isSnapshotInProgress = false
                }
                return
            }
            var map: [UInt64: Int] = [:]
            map.reserveCapacity(songs.count)
            for it in songs {
                map[it.persistentID] = it.playCount
            }
            let snap = PlayCountSnapshot(date: date, counts: map)

            DispatchQueue.main.async {
                // Update snapshots on main thread to keep @Published consistent
                if let idx = self.snapshots.lastIndex(where: { self.isSameDay($0.date, date) }) {
                    self.snapshots[idx] = snap
                } else {
                    self.snapshots.append(snap)
                }
                self.snapshots.sort { $0.date < $1.date }
                self.trimByDays(maxDays: 90)
                self.save()
                self.isSnapshotInProgress = false
            }
        }
    }
    
    // Ensure we have a recent snapshot (e.g., at least one per day)
    func ensureRecentSnapshot(maxAge hours: Double = 24) {
        let now = Date()
        if let last = snapshots.last {
            // If we don't have a snapshot for today, take one now
            if !Calendar.current.isDate(last.date, inSameDayAs: now) {
                takeSnapshotAsync(date: now)
            } else {
                // Optional: If you want to refresh the time within the same day, you could call takeSnapshotAsync here.
                // Currently we keep at most one per day and skip if already taken today.
            }
        } else {
            takeSnapshotAsync(date: now)
        }
    }

    func snapshot(beforeOrOn date: Date) -> PlayCountSnapshot? {
        return snapshots.last(where: { $0.date <= date })
    }

    // Custom baseline (used for resettable custom stats)
    func setCustomBaselineNow() {
        let snap = takeSnapshot() ?? PlayCountSnapshot(date: Date(), counts: [:])
        saveCustomBaseline(snap)
    }

    func getCustomBaseline() -> PlayCountSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: customBaselineKey) else { return nil }
        return try? JSONDecoder().decode(PlayCountSnapshot.self, from: data)
    }

    private func saveCustomBaseline(_ snap: PlayCountSnapshot) {
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: customBaselineKey)
        }
    }

    private func trimByDays(maxDays: Int) {
        // Snapshots are already one-per-day due to takeSnapshot replacement logic.
        // If there are more than `maxDays`, drop the oldest.
        let overflow = snapshots.count - maxDays
        if overflow > 0 {
            snapshots.removeFirst(overflow)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: snapshotsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: snapshotsKey),
              let decoded = try? JSONDecoder().decode([PlayCountSnapshot].self, from: data) else { return }
        snapshots = decoded.sorted { $0.date < $1.date }
    }
}

class MusicPlayerHelper: ObservableObject {
    @Published var currentSong: MPMediaItem? = nil
    private var musicPlayer = MPMusicPlayerController.systemMusicPlayer
    
    @Published var shuffledSongs: [MPMediaItem] = []
    @Published var nonShuffledSongs: [MPMediaItem] = []
    @Published var isLoading = false
    @Published var timer: Timer?
    @Published var progress: Double = 0
    init() {
        // Start observing now-playing changes once. Avoid duplicated work on repeated helper instantiation.
        musicPlayer.beginGeneratingPlaybackNotifications()
        self.currentSong = musicPlayer.nowPlayingItem // Set initial song

        NotificationCenter.default.addObserver(forName: .MPMusicPlayerControllerNowPlayingItemDidChange, object: musicPlayer, queue: .main) { [weak self] _ in
            self?.currentSong = self?.musicPlayer.nowPlayingItem
            if let newItem = self?.musicPlayer.nowPlayingItem {
                PlayHistoryStore.shared.recordPlay(newItem)
            }
        }

        // Avoid calling prepareToPlay eagerly here (can be expensive on some devices/libraries).
        // prepareToPlay will be invoked shortly before playback in playCurrentSong().
    }
    func playSongs() {
        playCurrentSong()
    }
    
    func shuffleSongs(){
        let days = self.getDaysFromLastPlayed()
        let result = self.reorderBasedOnProbabilityIndexes(days)
        // Initialize shuffledSongs with the same size
        self.shuffledSongs = Array(repeating: MPMediaItem(), count: nonShuffledSongs.count)

        for i in 0...self.nonShuffledSongs.count-1 {
            self.shuffledSongs[i] = self.nonShuffledSongs[result[i]]
        }

    }

    func reorderBasedOnProbabilityIndexes(_ days: [Int]) -> [Int] {
        if days.allSatisfy({ $0 == -1 }) {
            return Array(0..<days.count)
        }

        let zeroIndexes = days.enumerated().filter { $0.element == 0 }.map { $0.offset }
        let nonZeroIndexedDays = days.enumerated().filter { $0.element > 0 || $0.element == -1 }

        let maxValue = days.max() ?? 1
        let adjustedDays = nonZeroIndexedDays.map { $0.element < 0 ? maxValue : $0.element }
        let weights = adjustedDays.map { Double($0 + 1) } // avoid zero
        let totalWeight = weights.reduce(0, +)
        let probabilities = weights.map { $0 / totalWeight }

        var gumbelScores: [(index: Int, score: Double)] = []

        for (i, prob) in probabilities.enumerated() {
            let u = Double.random(in: 0..<1)
            let gumbelNoise = -log(-log(u))
            let score = log(prob) + gumbelNoise
            gumbelScores.append((index: nonZeroIndexedDays[i].offset, score: score))
        }

        let sorted = gumbelScores.sorted { $0.score > $1.score }.map { $0.index }
        return sorted + zeroIndexes
    }

    private func getDaysFromLastPlayed() -> [Int] {
        let playlistSongs = self.nonShuffledSongs
        let currentDate = Date()
        var days = Array<Int>(repeating: 0, count: playlistSongs.count)
        
        for i in 0...playlistSongs.count-1 {
            let lastPlayed = playlistSongs[i].lastPlayedDate
            if lastPlayed == nil { days[i] = -1; continue }
            let components = Calendar.current.dateComponents([.day], from: lastPlayed!, to: currentDate)
            days[i] = components.day ?? 0  // If components.day is nil, assign 0
        }
        
        if let maxValue = days.max() {
            days = days.map { $0 < 0 ? maxValue : $0 }
        } else { print("The array is empty.") }
        return days
    }
    
    private func playCurrentSong() {
        guard !shuffledSongs.isEmpty else {
            return
        }
        
        let player = MPMusicPlayerController.systemMusicPlayer
        player.stop()
        
        let collection = MPMediaItemCollection(items: shuffledSongs)
        player.setQueue(with: collection)
        
        player.nowPlayingItem = shuffledSongs.first
        
        DispatchQueue.main.asyncAfter(deadline: .now()) {
            player.prepareToPlay()
            player.play()

            self.progress = 0
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                let duration = player.nowPlayingItem?.playbackDuration ?? 0
                if duration > 0 {
                    let currentTime = player.currentPlaybackTime
                    self.progress = currentTime / duration
                }
            }
        }
    }

    func openAppleMusic() {
        if let url = URL(string: "music://") {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}

struct SongListView: View {
    let songs: [MPMediaItem]
    @ObservedObject var musicPlayerHelper: MusicPlayerHelper
    let playlistInfoCard: AnyView

    var body: some View {
        VStack {
            List(songs, id: \.persistentID) { song in
                HStack {
                    if let artwork = song.artwork?.image(at: CGSize(width: 40, height: 40)) {
                        Image(uiImage: artwork)
                            .resizable()
                            .frame(width: 40, height: 40)
                            .cornerRadius(4)
                    } else {
                        Image(systemName: "music.note")
                            .frame(width: 40, height: 40)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title ?? "Unknown Song")
                                .font(.body)
                            Text(song.artist ?? "Unknown Artist")
                                .font(.caption)
                                .foregroundColor(.gray)
                            // PPM display
                            let ppm = calculatePPM(song)
                            Text(ppm.isNaN ? "PPM: NAN" : String(format: "PPM: %.2f", ppm))
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if let lastPlayed = song.lastPlayedDate {
                                Text(lastPlayed.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                            Text("\(song.playCount) plays")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }

            if musicPlayerHelper.isLoading {
                ProgressView()
                    .padding()
            }

            playlistInfoCard

            Button("Play in Apple Music") {
                musicPlayerHelper.isLoading = true
                musicPlayerHelper.playSongs()
                musicPlayerHelper.isLoading = false
                musicPlayerHelper.openAppleMusic()
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 40)
            .background(Color.red)
            .foregroundColor(.white)
            .cornerRadius(8)
            .font(.headline)
        }
    }

    private func calculatePPM1(_ song: MPMediaItem) -> Double {
        guard let addedDate = song.value(forKey: "dateAdded") as? Date else { return .nan }
        let months = Calendar.current.dateComponents([.month], from: addedDate, to: Date()).month ?? 0
        if months == 0 { return .nan }
        return Double(song.playCount - song.skipCount) / Double(months)
    }
}

struct PlaylistView: View {
    @Binding var selectedPlaylist: MPMediaPlaylist?
    let playlist: MPMediaPlaylist

    @State private var playlistSongs: [MPMediaItem] = []
    @ObservedObject var musicPlayerHelper: MusicPlayerHelper

    var body: some View {
        VStack {
            SongListView(songs: playlistSongs, musicPlayerHelper: musicPlayerHelper, playlistInfoCard: playlistInfoCard)
        }
        .onAppear {
            fetchPlaylistSongs()
        }
        .onDisappear {
            musicPlayerHelper.timer?.invalidate()
        }
    }

    private func fetchPlaylistSongs() {
        playlistSongs = playlist.items
        musicPlayerHelper.nonShuffledSongs = playlistSongs
        musicPlayerHelper.shuffleSongs()
        playlistSongs = musicPlayerHelper.shuffledSongs
    }

    private var playlistInfoCard: AnyView {
        let totalDuration = playlistSongs.reduce(0) { $0 + $1.playbackDuration }
        let playedDuration = playlistSongs.reduce(0.0) { result, item in
            let count = item.playCount
            return result + (Double(count) * item.playbackDuration)
        }
        let mostPlayedSong = playlistSongs.max(by: { $0.playCount < $1.playCount })

        // Median PPM for songs in this playlist
        let ppmValues = playlistSongs.compactMap { song -> Double? in
            guard let addedDate = song.value(forKey: "dateAdded") as? Date else { return nil }
            let months = Calendar.current.dateComponents([.month], from: addedDate, to: Date()).month ?? 0
            if months <= 0 { return nil }
            return Double(song.playCount - song.skipCount) / Double(months)
        }.sorted()
        let medianPPM: Double = {
            guard !ppmValues.isEmpty else { return .nan }
            let mid = ppmValues.count / 2
            if ppmValues.count % 2 == 0 {
                return (ppmValues[mid - 1] + ppmValues[mid]) / 2.0
            } else {
                return ppmValues[mid]
            }
        }()

        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                // Compact metrics row: songs, median PPM (icon+value), total duration, played duration
                HStack(spacing: 16) {
                    Label("\(playlistSongs.count)", systemImage: "music.note.list")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar")
                            .foregroundColor(medianPPM.isNaN ? .secondary : .blue)
                        Text(medianPPM.isNaN ? "--" : String(format: "%.2f", medianPPM))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Label(formatTime(totalDuration), systemImage: "clock")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Label(formatTime(playedDuration), systemImage: "play.circle")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }

                if let song = mostPlayedSong {
                    Divider()
                    Text("Most Played Song")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("\(song.title ?? "Unknown") (\(song.playCount) plays)")
                        .font(.body)
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.2)))
            .padding(.horizontal)
            .frame(maxWidth: .infinity)
        )
    }

    private func formatTime(_ time: TimeInterval) -> String {
        if time >= 86400 {
            let days = time / 86400
            return String(format: "%.1f days", days)
        }
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60

        if hours > 0 {
            return String(format: "%02dh %02dm", hours, minutes)
        } else {
            return String(format: "%02dm", minutes)
        }
    }
}

struct AllSongsView: View {
    enum SortMode: String, CaseIterable, Identifiable {
        case ppm = "PPM Order"
        case smart = "Smart Shuffle"
        var id: String { rawValue }
    }
 
    @EnvironmentObject private var mediaStore: MediaLibraryStore
    @State private var allSongs: [MPMediaItem] = []
    @ObservedObject var musicPlayerHelper: MusicPlayerHelper
    @State private var sortAscending = true
    @State private var minMonthsText = "0"
    @State private var sortMode: SortMode = .ppm
    @State private var minMonths: Int = 0
    @State private var sortedSongs: [MPMediaItem] = []

    // Selection mode state
    @State private var isSelectMode = false
    @State private var selectedIDs = Set<UInt64>()

    var body: some View {
        VStack {
            // Toolbar for selection mode
            HStack {
                Spacer()
                Button(isSelectMode ? "Cancel" : "Select") {
                    isSelectMode.toggle()
                    if !isSelectMode { selectedIDs.removeAll() }
                }
                .padding()
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Min Months Since Added:")
                    TextField("Months", text: $minMonthsText)
                        .keyboardType(.numberPad)
                        .submitLabel(.done)
                        .frame(width: 50)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .disabled(sortMode == .smart)
                        .opacity(sortMode == .smart ? 0.5 : 1.0)
                        .onSubmit {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            minMonths = Int(minMonthsText) ?? 0
                        }
                    Spacer()
                    Picker("Sort", selection: $sortAscending) {
                        Text("↑").tag(true)
                        Text("↓").tag(false)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 100)
                    .disabled(sortMode == .smart)
                    .opacity(sortMode == .smart ? 0.5 : 1.0)
                }
                Picker("Sort Mode", selection: $sortMode) {
                    ForEach(SortMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }
            .padding(.horizontal)
            .background(Color(UIColor.secondarySystemBackground))
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        minMonths = Int(minMonthsText) ?? 0
                    }
                }
            }

            // Song List with selection mode
            List(filteredAndSortedSongs, id: \.persistentID) { song in
                HStack {
                    if isSelectMode {
                        Button(action: {
                            let id = song.persistentID
                            if selectedIDs.contains(id) {
                                selectedIDs.remove(id)
                            } else {
                                selectedIDs.insert(id)
                            }
                        }) {
                            Image(systemName: selectedIDs.contains(song.persistentID) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(.blue)
                        }
                    }
                    SongRow(song: song, calculatePPM: { mediaStore.ppm(for: $0) })
                }
            }

            // Save selection button
            if isSelectMode {
                Button("Save Selection to Songs2BeRemoved") {
                    createOrRewritePlaylist()
                    isSelectMode = false
                    selectedIDs.removeAll()
                }
                .padding()
            }

            Button("Play in Apple Music") {
                musicPlayerHelper.isLoading = true
                musicPlayerHelper.playSongs()
                musicPlayerHelper.isLoading = false
                musicPlayerHelper.openAppleMusic()
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 40)
            .background(Color.red)
            .foregroundColor(.white)
            .cornerRadius(8)
            .font(.headline)
        }
        .onAppear {
            allSongs = mediaStore.allSongs
            if allSongs.isEmpty { mediaStore.loadSongs() }
            musicPlayerHelper.nonShuffledSongs = allSongs
            musicPlayerHelper.shuffleSongs()
            allSongs = musicPlayerHelper.shuffledSongs
            updateSortedSongs()
        }
        .onDisappear {
            musicPlayerHelper.timer?.invalidate()
        }
        .onChange(of: sortMode) { _, _ in updateSortedSongs() }
        .onChange(of: sortAscending) { _, _ in updateSortedSongs() }
        .onChange(of: mediaStore.allSongs) { _, new in
            allSongs = new
            musicPlayerHelper.nonShuffledSongs = allSongs
            musicPlayerHelper.shuffleSongs()
            allSongs = musicPlayerHelper.shuffledSongs
            updateSortedSongs()
        }
    }
 
     private func updateSortedSongs() {
         switch sortMode {
         case .ppm:
             // Compute using cached PPM from mediaStore
             sortedSongs = allSongs.sorted { a, b in
                 let v0 = mediaStore.ppm(for: a)
                 let v1 = mediaStore.ppm(for: b)
                 // Place NaN values at the end
                 if v0.isNaN && v1.isNaN { return false }
                 if v0.isNaN { return false }
                 if v1.isNaN { return true }
                 return sortAscending ? v0 < v1 : v0 > v1
             }
         case .smart:
             sortedSongs = allSongs
         }
     }

     private var filteredAndSortedSongs: [MPMediaItem] {
         sortedSongs.filter {
             guard let addedDate = $0.value(forKey: "dateAdded") as? Date else { return false }
             let months = Calendar.current.dateComponents([.month], from: addedDate, to: Date()).month ?? 0
             return months > minMonths
         }
     }

     private func calculatePPM1(_ song: MPMediaItem) -> Double {
         guard let addedDate = song.value(forKey: "dateAdded") as? Date else { return .nan }
         let months = Calendar.current.dateComponents([.month], from: addedDate, to: Date()).month ?? 0
         if months == 0 { return .nan }
         return Double(song.playCount - song.skipCount) / Double(months)
     }

     // Playlist creation logic
     private func createOrRewritePlaylist() {
         let title = "Songs2BeRemoved"
         let metadata = MPMediaPlaylistCreationMetadata(name: title)
         // Look for existing playlist by name
         let query = MPMediaQuery.playlists()
         if let playlists = query.collections as? [MPMediaPlaylist],
            let existing = playlists.first(where: { $0.name == title }) {
             // For existing playlists, we'll just add the selected songs
             // Note: MPMediaPlaylist doesn't have a direct remove method in the public API
             addSelected(to: existing)
         } else {
             // Create new playlist
             MPMediaLibrary.default().getPlaylist(with: UUID(), creationMetadata: metadata) { playlist, error in
                 guard let playlist = playlist else { return }
                 addSelected(to: playlist)
             }
         }
     }

     private func addSelected(to playlist: MPMediaPlaylist) {
         let songsToAdd = allSongs.filter { selectedIDs.contains($0.persistentID) }
         if !songsToAdd.isEmpty {
             playlist.add(songsToAdd) { error in
                 // Optionally handle error or notify user here
             }
         }
     }
 }

// SongRow view for displaying a song (factored out from SongListView)
struct SongRow: View {
    let song: MPMediaItem
    let calculatePPM: (MPMediaItem) -> Double

    var body: some View {
        HStack {
            if let artwork = song.artwork?.image(at: CGSize(width: 40, height: 40)) {
                Image(uiImage: artwork)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .cornerRadius(4)
            } else {
                Image(systemName: "music.note")
                    .frame(width: 40, height: 40)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title ?? "Unknown Song")
                        .font(.body)
                    Text(song.artist ?? "Unknown Artist")
                        .font(.caption)
                        .foregroundColor(.gray)
                    // PPM display
                    let ppm = calculatePPM(song)
                    Text(ppm.isNaN ? "PPM: NAN" : String(format: "PPM: %.2f", ppm))
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let lastPlayed = song.lastPlayedDate {
                        Text(lastPlayed.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    Text("\(song.playCount) plays")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
        }
    }
}

// Custom LabelStyle for vertical metrics with icon, value, and title
struct VerticalMetricLabelStyle: LabelStyle {
    var title: String
    func makeBody(configuration: Configuration) -> some View {
        VStack {
            configuration.icon
                .font(.title2)
            configuration.title
                .font(.headline)
            Text(title)
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }
}

// PlaylistStatsView: Shows stats for all playlists in a card-based, sortable layout
struct PlaylistStatsView: View {
    @Binding var selectedPlaylist: MPMediaPlaylist?
    let playlists: [MPMediaPlaylist]
    @ObservedObject var musicPlayerHelper: MusicPlayerHelper
    @EnvironmentObject private var mediaStore: MediaLibraryStore

    @AppStorage("selectedPlaylistIDs") private var selectedPlaylistIDsRaw: String = ""
    @State private var selectedPlaylistIDs: Set<UInt64> = []

    private func loadSelectedPlaylistIDs() {
        let ids = selectedPlaylistIDsRaw.split(separator: ",").compactMap { UInt64($0) }
        selectedPlaylistIDs = Set(ids)
    }

    private func saveSelectedPlaylistIDs() {
        selectedPlaylistIDsRaw = selectedPlaylistIDs.map { String($0) }.joined(separator: ",")
    }
    @State private var isSelectMode = false
    // Local copy for mutation in view
    @State private var localSelectedIDs: Set<UInt64> = []

    struct Stats: Identifiable {
        let id = UUID()
        let playlist: MPMediaPlaylist
        var name: String { playlist.name ?? "Unknown" }
        let songCount: Int
        let totalDuration: TimeInterval
        let playedDuration: TimeInterval
        let medianPPM: Double
    }

    var sortedStats: [Stats] {
        let visiblePlaylists = isSelectMode ? playlists : playlists.filter {
            localSelectedIDs.isEmpty || localSelectedIDs.contains($0.persistentID)
        }
        let base = visiblePlaylists.map { playlist in
            let songs = playlist.items
            let total = songs.reduce(0) { $0 + $1.playbackDuration }
            let played = songs.reduce(0.0) { $0 + (Double($1.playCount) * $1.playbackDuration) }
            // Compute Median PPM across songs in playlist
            let ppmValues = songs.compactMap { song -> Double? in
                guard let addedDate = song.value(forKey: "dateAdded") as? Date else { return nil }
                let months = Calendar.current.dateComponents([.month], from: addedDate, to: Date()).month ?? 0
                if months <= 0 { return nil }
                return Double(song.playCount - song.skipCount) / Double(months)
            }.sorted()
            let median: Double = {
                guard !ppmValues.isEmpty else { return .nan }
                let mid = ppmValues.count / 2
                if ppmValues.count % 2 == 0 {
                    return (ppmValues[mid - 1] + ppmValues[mid]) / 2.0
                } else {
                    return ppmValues[mid]
                }
            }()
            return Stats(playlist: playlist, songCount: songs.count, totalDuration: total, playedDuration: played, medianPPM: median)
        }

        // Always sort by name
        return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Spacer()
                Button(isSelectMode ? "Done" : "Select") {
                    isSelectMode.toggle()
                }
                .padding(.trailing)
            }
            // Heading at the top
            Text("Playlists")
                .font(.largeTitle)
                .bold()
                .padding(.horizontal)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(sortedStats, id: \.id) { stat in
                        HStack {
                            if isSelectMode {
                                Button(action: {
                                    let id = stat.playlist.persistentID
                                    if localSelectedIDs.contains(id) {
                                        localSelectedIDs.remove(id)
                                    } else {
                                        localSelectedIDs.insert(id)
                                    }
                                }) {
                                    Image(systemName: localSelectedIDs.contains(stat.playlist.persistentID) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(localSelectedIDs.contains(stat.playlist.persistentID) ? .blue : .gray)
                                }
                                .padding(.leading)
                            }
                            NavigationLink(destination: PlaylistView(selectedPlaylist: $selectedPlaylist, playlist: stat.playlist, musicPlayerHelper: musicPlayerHelper)) {
                                HStack(spacing: 12) {
                                    Text(stat.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    // Compact metrics on a single line: song count + median PPM value (no label text)
                                    HStack(spacing: 12) {
                                        Label("\(stat.songCount)", systemImage: "music.note.list")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                        HStack(spacing: 4) {
                                            Image(systemName: "chart.bar")
                                                .foregroundColor(stat.medianPPM.isNaN ? .secondary : .blue)
                                            Text(stat.medianPPM.isNaN ? "--" : String(format: "%.2f", stat.medianPPM))
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.gray)
                                }
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.2)))
                                .padding(.horizontal)
                            }
                            .contextMenu {
                                Button("Play Now") {
                                    selectedPlaylist = stat.playlist
                                    playPlaylist(stat.playlist)
                                }
                            }
                        }
                    }
                }
                .padding(.top)
            }

            // "All Songs" card-style NavigationLink after the Picker, with contextMenu
            NavigationLink(destination: AllSongsView(musicPlayerHelper: musicPlayerHelper)) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("All Songs")
                            .font(.headline)
                        let summary = mediaStore.librarySummary
                        HStack(spacing: 16) {
                            Label("\(summary?.songCount ?? mediaStore.allSongs.count)", systemImage: "music.note.list")
                            HStack(spacing: 4) {
                                Image(systemName: "chart.bar")
                                    .foregroundColor((summary?.medianPPM == nil) ? .secondary : .blue)
                                Text({
                                    if let v = summary?.medianPPM { return String(format: "%.2f", v) }
                                    return "--"
                                }())
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Label(formatTime(summary?.totalDuration ?? mediaStore.allSongs.reduce(0) { $0 + $1.playbackDuration }), systemImage: "clock")
                            Label(formatTime(summary?.playedDuration ?? mediaStore.allSongs.reduce(0.0) { $0 + (Double($1.playCount) * $1.playbackDuration) }), systemImage: "play.circle")
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.gray)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.2)))
                .padding(.horizontal)
            }
            .contextMenu {
                Button("Play Now") {
                    let helper = musicPlayerHelper
                    let songs = mediaStore.allSongs
                    helper.nonShuffledSongs = songs
                    helper.shuffleSongs()
                    helper.shuffledSongs = helper.shuffledSongs
                    helper.playSongs()
                }
            }
            .buttonStyle(PlainButtonStyle())
        }
        .onAppear {
            loadSelectedPlaylistIDs()
            localSelectedIDs = selectedPlaylistIDs
        }
        .onDisappear {
            selectedPlaylistIDs = localSelectedIDs
            saveSelectedPlaylistIDs()
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        if time >= 86400 {
            let days = time / 86400
            return String(format: "%.1f d", days)
        }
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        return hours > 0 ? String(format: "%02dh %02dm", hours, minutes) : String(format: "%02dm", minutes)
    }

    private func playPlaylist(_ playlist: MPMediaPlaylist) {
        let helper = MusicPlayerHelper()
        helper.nonShuffledSongs = playlist.items
        helper.shuffleSongs()
        helper.shuffledSongs = helper.shuffledSongs
        helper.playSongs()
    }
}


struct NowPlayingView: View {
    let song: MPMediaItem?
    @State private var showFullScreen = false
    @State private var isPlaying = false
    private let musicPlayer = MPMusicPlayerController.systemMusicPlayer

    var body: some View {
        if let song = song {
            VStack(spacing: 0) {
                Button(action: {
                    showFullScreen = true
                }) {
                    HStack {
                        if let artwork = song.artwork?.image(at: CGSize(width: 44, height: 44)) {
                            Image(uiImage: artwork)
                                .resizable()
                                .frame(width: 44, height: 44)
                                .cornerRadius(4)
                        } else {
                            Image(systemName: "music.note")
                                .resizable()
                                .frame(width: 44, height: 44)
                                .foregroundColor(.gray)
                        }

                        VStack(alignment: .leading) {
                            Text(song.title ?? "Unknown Title")
                                .font(.headline)
                            Text(song.artist ?? "Unknown Artist")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }

                        Spacer()

                        Button(action: {
                            togglePlayback()
                        }) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color(UIColor.secondarySystemBackground))
                .onAppear {
                    isPlaying = musicPlayer.playbackState == .playing
                    NotificationCenter.default.addObserver(forName: .MPMusicPlayerControllerPlaybackStateDidChange, object: musicPlayer, queue: .main) { _ in
                        isPlaying = musicPlayer.playbackState == .playing
                    }
                    musicPlayer.beginGeneratingPlaybackNotifications()
                }
                .onDisappear {
                    NotificationCenter.default.removeObserver(self, name: .MPMusicPlayerControllerPlaybackStateDidChange, object: musicPlayer)
                    musicPlayer.endGeneratingPlaybackNotifications()
                }
                .sheet(isPresented: $showFullScreen) {
                    FullScreenNowPlayingView(song: song)
                }
            }
        }
    }

    private func togglePlayback() {
        if musicPlayer.playbackState == .playing {
            musicPlayer.pause()
            isPlaying = false
        } else {
            musicPlayer.play()
            isPlaying = true
        }
    }
}

struct FullScreenNowPlayingView: View {
    let song: MPMediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var playbackProgress: Double = 0.0
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    private let musicPlayer = MPMusicPlayerController.systemMusicPlayer
    // Removed custom drag-to-dismiss states

    // Extra metadata
    @State private var metaComposer: String? = nil
    @State private var metaLyricist: String? = nil
    @State private var metaSongwriter: String? = nil
    @State private var releaseYear: String? = nil

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            if let artwork = song.artwork?.image(at: CGSize(width: 300, height: 300)) {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(10)
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 300, height: 300)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
            }

            VStack(spacing: 8) {
                Text(song.title ?? "Unknown Title")
                    .font(.title)
                    .bold()
                Text(song.artist ?? "Unknown Artist")
                    .font(.title3)
                    .foregroundColor(.gray)
                // Card 1: Song Credits (one per line; composer, lyricist, songwriter)
                VStack(alignment: .leading, spacing: 6) {
                    if let composer = metaComposer, !composer.isEmpty {
                        LabelInline(title: "Composer:", value: composer, systemImage: "music.quarternote.3")
                    }
                    if let lyricist = metaLyricist, !lyricist.isEmpty {
                        LabelInline(title: "Lyricist:", value: lyricist, systemImage: "text.quote")
                    }
                    if let songwriter = metaSongwriter, !songwriter.isEmpty {
                        LabelInline(title: "Songwriter:", value: songwriter, systemImage: "pencil")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.15)))
                .padding(.horizontal)
            }

            // Card 2: Plays and Skips (more compact)
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "goforward")
                    Text("Plays: \(song.playCount)")
                }
                .font(.subheadline)
                .foregroundColor(.primary)
                HStack(spacing: 6) {
                    Image(systemName: "forward.fill")
                    Text("Skips: \(song.skipCount)")
                }
                .font(.subheadline)
                .foregroundColor(.primary)
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar")
                    let ppm = calculatePPM(song)
                    Text(ppm.isNaN ? "PPM: NAN" : String(format: "PPM: %.2f", ppm))
                }
                .font(.subheadline)
                .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.15)))
            .padding(.horizontal)

            // Card 3: Dates (icons + dates only)
            HStack(spacing: 36) {
                HStack(spacing: 6) {
                    if let rd = song.value(forKey: "releaseDate") as? Date {
                        Image(systemName: "calendar")
                        Text(rd.formatted(date: .abbreviated, time: .omitted))
                    } else if let year = releaseYear, !year.isEmpty {
                        Image(systemName: "calendar")
                        Text(year)
                    }
                }
                .font(.subheadline)
                .foregroundColor(.primary)
                HStack(spacing: 6) {
                    if let dateAdded = song.value(forKey: "dateAdded") as? Date {
                        Image(systemName: "tray.and.arrow.down")
                        Text(dateAdded.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .font(.subheadline)
                .foregroundColor(.primary)
                HStack(spacing: 6) {
                    if let lastPlayed = song.lastPlayedDate {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(lastPlayed.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .font(.subheadline)
                .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.15)))
            .padding(.horizontal)

            // Card 3: Playback Progress
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: playbackProgress)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                HStack {
                    Text(String(format: "%d:%02d", Int(currentTime)/60, Int(currentTime)%60))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%d:%02d", Int(duration)/60, Int(duration)%60))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.15)))
            .padding(.horizontal)

            HStack(spacing: 40) {
                Button(action: {
                    musicPlayer.skipToPreviousItem()
                }) {
                    Image(systemName: "backward.fill")
                        .font(.largeTitle)
                }

                Button(action: {
                    togglePlayback()
                }) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                }

                Button(action: {
                    musicPlayer.skipToNextItem()
                }) {
                    Image(systemName: "forward.fill")
                        .font(.largeTitle)
                }
            }
            .padding(.top, 30)

            Spacer()
        }
        .padding()
        // Removed custom offset and gesture; use default modal swipe-to-dismiss
        .onAppear {
            isPlaying = musicPlayer.playbackState == .playing

            // Seed metadata from MPMediaItem
            metaComposer = (song.composer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let rd = song.value(forKey: "releaseDate") as? Date {
                let y = Calendar.current.component(.year, from: rd)
                releaseYear = String(y)
            } else if let yearNum = song.value(forKey: "year") as? NSNumber {
                releaseYear = yearNum.stringValue
            }

            // Try to enrich with AVAsset metadata using async loading to avoid deprecation
            if let url = song.assetURL {
                Task {
                    let asset = AVURLAsset(url: url)
                    let meta = (try? await asset.load(.metadata)) ?? []
                    func firstString(for keys: [String]) async -> String? {
                        let keysLower = Set(keys.map { $0.lowercased() })
                        for item in meta {
                            let common = item.commonKey?.rawValue.lowercased()
                            let ident = item.identifier?.rawValue.lowercased()
                            if (common != nil && keysLower.contains(common!)) || keysLower.contains(where: { ident?.contains($0) == true }) {
                                if let s = try? await item.load(.stringValue), !s.isEmpty {
                                    return s
                                }
                            }
                        }
                        return nil
                    }
                    if (metaComposer == nil || metaComposer?.isEmpty == true) {
                        if let comp = await firstString(for: ["composer"]) { await MainActor.run { metaComposer = comp } }
                    }
                    if let lyr = await firstString(for: ["lyricist"]) { await MainActor.run { metaLyricist = lyr } }
                    if let auth = await firstString(for: ["songwriter", "writer", "author"]) { await MainActor.run { metaSongwriter = auth } }
                    if releaseYear == nil, let dateStr = await firstString(for: ["creationdate"]) {
                        let yearPrefix = dateStr.prefix(4)
                        if Int(yearPrefix) != nil { await MainActor.run { releaseYear = String(yearPrefix) } }
                    }
                }
            }

            NotificationCenter.default.addObserver(forName: .MPMusicPlayerControllerPlaybackStateDidChange, object: musicPlayer, queue: .main) { _ in
                isPlaying = musicPlayer.playbackState == .playing
            }

            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                duration = musicPlayer.nowPlayingItem?.playbackDuration ?? 0
                if duration != 0 {
                    currentTime = musicPlayer.currentPlaybackTime
                    playbackProgress = currentTime / duration
                }
            }
        }
        .onDisappear {
            NotificationCenter.default.removeObserver(self, name: .MPMusicPlayerControllerPlaybackStateDidChange, object: musicPlayer)
        }
    }

    private func togglePlayback() {
        if musicPlayer.playbackState == .playing {
            musicPlayer.pause()
            isPlaying = false
        } else {
            musicPlayer.play()
            isPlaying = true
        }
    }
}

struct LabelInline: View {
    let title: String
    let value: String
    let systemImage: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
}


// UIKit share sheet wrapper for SwiftUI
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Stats View

struct StatsSnapshot {
    let uniqueSongCount: Int
    let totalPlayDuration: TimeInterval
    let mostPlayedSong: MPMediaItem?
    let mostPlayedSongCount: Int?
    let mostPlayedPlaylist: MPMediaPlaylist?
}

struct StatsView: View {
    @ObservedObject private var snapshotStore = PlayCountSnapshotStore.shared
    @EnvironmentObject private var mediaStore: MediaLibraryStore
    @State private var allPlaylists: [MPMediaPlaylist] = []
    @AppStorage("customStatsStartDate") private var customStartDate: Date = Date()
    @AppStorage("statsSelectedPlaylistIDs") private var statsSelectedPlaylistIDsRaw: String = ""

    @State private var isSelectMode = false
    @State private var localSelectedIDs: Set<UInt64> = []

    // Export state
    @State private var exportURL: URL? = nil
    @State private var isExportReady = false
    @State private var showingShare = false

    private func loadSelectedPlaylistIDs() {
        let ids = statsSelectedPlaylistIDsRaw.split(separator: ",").compactMap { UInt64($0) }
        localSelectedIDs = Set(ids)
    }

    private func saveSelectedPlaylistIDs() {
        statsSelectedPlaylistIDsRaw = localSelectedIDs.map { String($0) }.joined(separator: ",")
    }

    private var selectedPlaylistIDs: Set<UInt64> {
        // Use local in-view edits immediately; fall back to persisted selection
        if !localSelectedIDs.isEmpty || isSelectMode { return localSelectedIDs }
        return Set(statsSelectedPlaylistIDsRaw.split(separator: ",").compactMap { UInt64($0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Playing Activity")
                    .font(.largeTitle).bold()
                    .padding(.horizontal)
                HStack(spacing: 8) {
                    if let last = snapshotStore.snapshots.last?.date {
                        Text("Last snapshot: \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Last snapshot: —")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if snapshotStore.isSnapshotInProgress {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.8)
                    }
                    Spacer()
                    Button {
                        snapshotStore.takeSnapshotAsync()
                    } label: {
                        Label("Take Snapshot", systemImage: "camera.on.rectangle")
                    }
                    .disabled(snapshotStore.isSnapshotInProgress)
                }
                .padding(.horizontal)

                // Card 1: Last week
                statsCard(title: "Last 7 Days", snapshot: computeSnapshot(since: Calendar.current.date(byAdding: .day, value: -7, to: Date())!))

                // Card 2: Last month
                statsCard(title: "Last 30 Days", snapshot: computeSnapshot(since: Calendar.current.date(byAdding: .day, value: -30, to: Date())!))

                // Card 3: Custom (resettable)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Custom (since \(customStartDate.formatted(date: .abbreviated, time: .omitted)))")
                            .font(.headline)
                        Spacer()
                        Button {
                            customStartDate = Date()
                            snapshotStore.setCustomBaselineNow()
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, -4)
                    cardContent(for: computeSnapshot(since: customStartDate))
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.15)))
                .padding(.horizontal)

                Spacer(minLength: 24)

                Divider()
                    .padding(.horizontal)

                // Inline selection list moved to bottom when in selection mode
                if isSelectMode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose which playlists Stats should consider")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(allPlaylists, id: \.persistentID) { pl in
                                    Button {
                                        let id = pl.persistentID
                                        if localSelectedIDs.contains(id) {
                                            localSelectedIDs.remove(id)
                                        } else {
                                            localSelectedIDs.insert(id)
                                        }
                                    } label: {
                                        HStack {
                                            Image(systemName: localSelectedIDs.contains(pl.persistentID) ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(localSelectedIDs.contains(pl.persistentID) ? .blue : .gray)
                                            Text(pl.name ?? "Unknown")
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                        .padding(.horizontal)
                                        .padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.12)))
                                        .padding(.horizontal)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                        .padding(.bottom, 4)
                    }
                }

                VStack(spacing: 12) {
                    Button {
                        do {
                            let url = try exportSnapshotsCSV()
                            exportURL = url
                            showingShare = true
                        } catch {
                            print("Export failed: \(error)")
                        }
                    } label: {
                        Label("Export Snapshots (CSV)", systemImage: "square.and.arrow.up")
                    }

                    Button(isSelectMode ? "Done" : "Select Stats Playlists") {
                        if isSelectMode {
                            saveSelectedPlaylistIDs()
                        } else {
                            loadSelectedPlaylistIDs()
                        }
                        isSelectMode.toggle()
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            allPlaylists = mediaStore.playlists
            loadSelectedPlaylistIDs()
            snapshotStore.ensureRecentSnapshot() // make sure we have at least one snapshot
        }
        .onChange(of: mediaStore.playlists) { _, new in
            allPlaylists = new
        }
         // Share sheet presentation
         .sheet(isPresented: $showingShare) {
             if let url = exportURL {
                 ActivityView(activityItems: [url])
             }
         }
     }

     // Build a StatsSnapshot for events since a given date using system play count deltas from snapshots
     private func computeSnapshot(since start: Date) -> StatsSnapshot {
         // Determine baseline snapshot:
         // - For Custom window, prefer custom baseline if present and newer than start.
         // - Otherwise, use the latest snapshot taken on/before `start`.
         let baseline: PlayCountSnapshot? = {
             if let custom = snapshotStore.getCustomBaseline(), custom.date >= start {
                 return custom
             }
             if let snap = snapshotStore.snapshot(beforeOrOn: start) {
                 return snap
             }
             // Fallback: use earliest snapshot so we report plays since the first snapshot, not absolute counts
             return snapshotStore.snapshots.first
         }()

        // Current counts from cached library (no app-logged events)
        let currentSongs = mediaStore.allSongs
         var currentCounts: [UInt64: Int] = [:]
         currentCounts.reserveCapacity(currentSongs.count)
         for it in currentSongs {
             currentCounts[it.persistentID] = it.playCount
         }

         guard let baselineCounts = baseline?.counts else {
             // If absolutely no snapshots exist, return an empty snapshot
             return StatsSnapshot(
                 uniqueSongCount: 0,
                 totalPlayDuration: 0,
                 mostPlayedSong: nil,
                 mostPlayedSongCount: nil,
                 mostPlayedPlaylist: nil
             )
         }

         // Compute deltas (plays within the window)
         var deltaCounts: [UInt64: Int] = [:]
         for (id, now) in currentCounts {
             let then = baselineCounts[id] ?? 0
             let delta = max(0, now - then)
             if delta > 0 { deltaCounts[id] = delta }
         }

         let ids = Set(deltaCounts.keys)
         // Lookup from cached library
         let itemsByID: [UInt64: MPMediaItem] = {
             var map: [UInt64: MPMediaItem] = [:]
             for it in mediaStore.allSongs where ids.contains(it.persistentID) {
                 map[it.persistentID] = it
             }
             return map
         }()

         // Duration = sum(delta * track duration)
         var totalDuration: TimeInterval = 0
         var mostPlayed: (id: UInt64, count: Int, duration: TimeInterval)? = nil
         for (id, count) in deltaCounts {
             guard let item = itemsByID[id] else { continue }
             let contribution = Double(count) * item.playbackDuration
             totalDuration += contribution
             let current = (id: id, count: count, duration: contribution)
             if let best = mostPlayed {
                 if current.count > best.count || (current.count == best.count && current.duration > best.duration) {
                     mostPlayed = current
                 }
             } else {
                 mostPlayed = current
             }
         }

         let mostPlayedSong = mostPlayed.flatMap { itemsByID[$0.id] }

         // Most played playlist = among the user-selected playlists only.
         // If none are selected or there is no overlap, result is nil.
         let uniqueIDs = ids
         var best: (playlist: MPMediaPlaylist, count: Int)? = nil
         for pl in allPlaylists {
             // Consider only playlists the user selected in the Playlists tab
             guard selectedPlaylistIDs.contains(pl.persistentID) else { continue }
             let idsInPlaylist = Set(pl.items.map { $0.persistentID })
             let overlapCount = idsInPlaylist.intersection(uniqueIDs).count
             if overlapCount > 0 {
                 if let currentBest = best {
                     if overlapCount > currentBest.count {
                         best = (pl, overlapCount)
                     }
                 } else {
                     best = (pl, overlapCount)
                 }
             }
         }
         let mostPlaylist = best?.playlist

         return StatsSnapshot(
             uniqueSongCount: uniqueIDs.count,
             totalPlayDuration: totalDuration,
             mostPlayedSong: mostPlayedSong,
             mostPlayedSongCount: mostPlayed?.count,
             mostPlayedPlaylist: mostPlaylist
         )
     }

     // MARK: - Export helpers
     private func exportSnapshotsTXT() throws -> URL {
         let text = buildSnapshotsText()
         let df = DateFormatter()
         df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
         let filename = "PlayHistorySnapshots_\(df.string(from: Date())).txt"
         let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
         try text.write(to: url, atomically: true, encoding: .utf8)
         return url
     }

     private func buildSnapshotsText() -> String {
         var out: [String] = []
         let dateFmt = DateFormatter()
         dateFmt.dateStyle = .medium
         dateFmt.timeStyle = .short

         // Summary
         out.append("=== Play History Snapshots ===")
         if let last = snapshotStore.snapshots.last?.date {
             out.append("Last snapshot: \(dateFmt.string(from: last))")
         } else {
             out.append("Last snapshot: —")
         }

         if let custom = snapshotStore.getCustomBaseline()?.date {
             out.append("Custom baseline snapshot: \(dateFmt.string(from: custom))")
         } else {
             out.append("Custom baseline snapshot: —")
         }
         out.append("")

         // Resolve metadata for nicer lines from cached library
         let allItems = mediaStore.allSongs
         var itemByID: [UInt64: MPMediaItem] = [:]
         itemByID.reserveCapacity(allItems.count)
         for it in allItems { itemByID[it.persistentID] = it }

         // Index
         out.append("=== Snapshot Index ===")
         if snapshotStore.snapshots.isEmpty {
             out.append("- (no snapshots)")
         } else {
             for snap in snapshotStore.snapshots {
                 let tracked = snap.counts.count
                 let sumCounts = snap.counts.values.reduce(0, +)
                 out.append("- \(dateFmt.string(from: snap.date)) | tracks tracked: \(tracked), total playCount sum: \(sumCounts)")
             }
         }
         out.append("")

         // Details (top 20 by count)
         for snap in snapshotStore.snapshots {
             out.append("=== Snapshot @ \(dateFmt.string(from: snap.date)) ===")
             let top = snap.counts.sorted { $0.value > $1.value }.prefix(20)
             if top.isEmpty {
                 out.append("(no items)")
             } else {
                 for (id, c) in top {
                     if let it = itemByID[id] {
                         let title = it.title ?? "Unknown Title"
                         let artist = it.artist ?? "Unknown Artist"
                         out.append("• \(title) — \(artist) | count: \(c)")
                     } else {
                         out.append("• [\(id)] | count: \(c)")
                     }
                 }
             }
             out.append("")
         }

         // Baselines used for windows
         let weekStart = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
         let monthStart = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
         let weekSnap = snapshotStore.snapshot(beforeOrOn: weekStart)
         let monthSnap = snapshotStore.snapshot(beforeOrOn: monthStart)
         let earliest = snapshotStore.snapshots.first?.date

         out.append("=== Window Baselines ===")
         if let w = weekSnap?.date {
             out.append("7d baseline: \(dateFmt.string(from: w))")
         } else if let e = earliest {
             out.append("7d baseline: \(dateFmt.string(from: e)) (earliest snapshot; no snapshot existed on/before window start)")
         } else {
             out.append("7d baseline: — (no snapshots available)")
         }

         if let m = monthSnap?.date {
             out.append("30d baseline: \(dateFmt.string(from: m))")
         } else if let e = earliest {
             out.append("30d baseline: \(dateFmt.string(from: e)) (earliest snapshot; no snapshot existed on/before window start)")
         } else {
             out.append("30d baseline: — (no snapshots available)")
         }

         return out.joined(separator: "\n")
     }

     // New: CSV export per requirements
     private func exportSnapshotsCSV() throws -> URL {
         let csv = buildSnapshotsCSV()
         let df = DateFormatter()
         df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
         let filename = "PlayHistorySnapshots_\(df.string(from: Date())).csv"
         let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
         try csv.write(to: url, atomically: true, encoding: .utf8)
         return url
     }

     private func buildSnapshotsCSV() -> String {
         let snaps = PlayCountSnapshotStore.shared.snapshots.sorted { $0.date < $1.date }
         guard !snaps.isEmpty else {
             return "No snapshots available"
         }

         // Header: first column label, then snapshot dates
         let dateFmt = DateFormatter()
         dateFmt.dateFormat = "yyyy-MM-dd"
         var rows: [String] = []

         func q(_ s: String) -> String {
             var v = s.replacingOccurrences(of: "\"", with: "\"\"")
             // Also normalize newlines
             v = v.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
             return "\"" + v + "\""
         }

         let header = ["Label"] + snaps.map { dateFmt.string(from: $0.date) }
         rows.append(header.map { q($0) }.joined(separator: ","))

         // Baseline rows
         let now = Date()
         let weekStart = Calendar.current.date(byAdding: .day, value: -7, to: now)!
         let monthStart = Calendar.current.date(byAdding: .day, value: -30, to: now)!
         let weekSnap = PlayCountSnapshotStore.shared.snapshot(beforeOrOn: weekStart)
         let monthSnap = PlayCountSnapshotStore.shared.snapshot(beforeOrOn: monthStart)
         let customSnap = PlayCountSnapshotStore.shared.getCustomBaseline()

         func baselineRow(label: String, baseline: PlayCountSnapshot?) -> [String] {
             let onesIndex: Int? = baseline.flatMap { b in snaps.firstIndex(where: { $0.date == b.date }) }
             let vals = snaps.enumerated().map { (idx, _) in (idx == onesIndex) ? "1" : "0" }
             return [label] + vals
         }

         rows.append(baselineRow(label: "WeeklyBaseline", baseline: weekSnap).map { q($0) }.joined(separator: ","))
         rows.append(baselineRow(label: "MonthlyBaseline", baseline: monthSnap).map { q($0) }.joined(separator: ","))
         rows.append(baselineRow(label: "CustomBaseline", baseline: customSnap).map { q($0) }.joined(separator: ","))

         // Identify songs whose playcount changed between oldest and newest snapshots
         let oldest = snaps.first!
         let latest = snaps.last!
         var allIDs = Set<UInt64>()
         for s in snaps { allIDs.formUnion(s.counts.keys) }

         // Build library lookup for labels
         let items = mediaStore.allSongs
         var itemByID: [UInt64: MPMediaItem] = [:]
         for it in items { itemByID[it.persistentID] = it }

         // Filter to IDs that changed since oldest snapshot
         var changedIDs: [(id: UInt64, delta: Int)] = []
         changedIDs.reserveCapacity(allIDs.count)
         for id in allIDs {
             let a = oldest.counts[id] ?? 0
             let b = latest.counts[id] ?? 0
             let d = b - a
             if d != 0 { changedIDs.append((id, d)) }
         }

         // Sort by descending delta, then by title
         changedIDs.sort { lhs, rhs in
             if lhs.delta != rhs.delta { return lhs.delta > rhs.delta }
             let lt = itemByID[lhs.id]?.title ?? ""
             let rt = itemByID[rhs.id]?.title ?? ""
             return lt.localizedCaseInsensitiveCompare(rt) == .orderedAscending
         }

         // Emit one row per song with counts across snapshots
         for (id, _) in changedIDs {
             let title = itemByID[id]?.title ?? "Unknown Title"
             let artist = itemByID[id]?.artist ?? "Unknown Artist"
             let label = "\(title) — \(artist) [\(id)]"
             let countsAcross = snaps.map { snap -> String in
                 let v = snap.counts[id] ?? 0
                 return String(v)
             }
             let row = [label] + countsAcross
             rows.append(row.map { q($0) }.joined(separator: ","))
         }

         return rows.joined(separator: "\n")
     }

     // MARK: - Cards & UI

     private func statsCard(title: String, snapshot: StatsSnapshot) -> some View {
         VStack(alignment: .leading, spacing: 8) {
             Text(title)
                 .frame(maxWidth: .infinity, alignment: .center) // centers horizontally
                 .padding(.top, 8)                               // adds a little space above
                 .padding(.bottom, -4)
             cardContent(for: snapshot)
         }
         .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.15)))
         .padding(.horizontal)
     }

     private func cardContent(for snapshot: StatsSnapshot) -> some View {
         VStack(alignment: .leading, spacing: 8) {
             HStack {
                 Label("\(snapshot.uniqueSongCount)", systemImage: "play.square.stack")
                 Spacer()
                 Label(formatTime(snapshot.totalPlayDuration), systemImage: "clock")
             }
             .font(.subheadline)
             .foregroundColor(.primary)

             Divider()
             HStack(alignment: .top, spacing: 24) {
                 HStack(alignment: .top, spacing: 12) {
                     Image(systemName: "music.mic")
                     VStack(alignment: .leading, spacing: 2) {
                         Text("Most Played Song")
                             .font(.caption)
                             .foregroundColor(.secondary)
                         Text({
                             guard let title = snapshot.mostPlayedSong?.title else { return "—" }
                             if let c = snapshot.mostPlayedSongCount, c > 0 {
                                 return "\(title) (\(c))"
                             }
                             return title
                         }())
                         .font(.body)
                         .lineLimit(2)
                     }
                 }

                 HStack(alignment: .top, spacing: 12) {
                     Image(systemName: "music.note.list")
                     VStack(alignment: .leading, spacing: 2) {
                         Text("Most Played Playlist")
                             .font(.caption)
                             .foregroundColor(.secondary)
                         Text(snapshot.mostPlayedPlaylist?.name ?? "—")
                             .font(.body)
                             .lineLimit(2)
                     }
                 }
             }
         }
         .padding()
     }

     private func formatTime(_ time: TimeInterval) -> String {
         if time >= 86400 {
             let days = time / 86400
             return String(format: "%.1f d", days)
         }
         let hours = Int(time) / 3600
         let minutes = (Int(time) % 3600) / 60
         return hours > 0 ? String(format: "%02dh %02dm", hours, minutes) : String(format: "%02dm", minutes)
     }
}
