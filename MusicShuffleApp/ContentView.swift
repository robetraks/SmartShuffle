import SwiftUI
import MediaPlayer
import AVFoundation

@main
struct MusicShuffleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
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
    @State private var playlists: [MPMediaPlaylist] = []
    @State private var selectedPlaylist: MPMediaPlaylist? = nil
    @State private var isAuthorized = false
    @State private var showError = false
    @State private var errorMessage = ""
    @StateObject private var musicPlayerHelper = MusicPlayerHelper()
    
    var body: some View {
        NavigationView {
            VStack {
                PlaylistStatsView(selectedPlaylist: $selectedPlaylist, playlists: playlists, musicPlayerHelper: musicPlayerHelper)
                    .onAppear {
                        requestAuthorization()
                    }
                NowPlayingView(song: musicPlayerHelper.currentSong)
                
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    private func requestAuthorization() {
        let status = MPMediaLibrary.authorizationStatus()
        if status == .denied || status == .restricted {
            errorMessage = "Please enable Music access in Settings"
            showError = true
        } else if status == .authorized {
            isAuthorized = true
            fetchPlaylists()
        } else if status == .notDetermined {
            MPMediaLibrary.requestAuthorization { newStatus in
                if newStatus == .authorized {
                    DispatchQueue.main.async {
                        isAuthorized = true
                        fetchPlaylists()
                    }
                } else {
                    DispatchQueue.main.async {
                        errorMessage = "Music access is required for this app"
                        showError = true
                    }
                }
            }
        }
    }

    private func fetchPlaylists() {
        let query = MPMediaQuery.playlists()
        if let items = query.collections as? [MPMediaPlaylist] {
            playlists = items.filter { !$0.items.isEmpty } // Filter out empty playlists
        }
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
        musicPlayer.beginGeneratingPlaybackNotifications()
        self.currentSong = musicPlayer.nowPlayingItem // Set initial song

        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: musicPlayer,
            queue: .main
        ) { [weak self] _ in
            self?.currentSong = self?.musicPlayer.nowPlayingItem
        }

        musicPlayer.beginGeneratingPlaybackNotifications()
        musicPlayer.prepareToPlay()
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
    @ObservedObject private var musicPlayerHelper = MusicPlayerHelper()

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

    @State private var allSongs: [MPMediaItem] = []
    @ObservedObject private var musicPlayerHelper = MusicPlayerHelper()
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
                    SongRow(song: song, calculatePPM: calculatePPM(_:))
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
            fetchAllSongs()
        }
        .onDisappear {
            musicPlayerHelper.timer?.invalidate()
        }
        .onChange(of: sortMode) { _, _ in updateSortedSongs() }
        .onChange(of: sortAscending) { _, _ in updateSortedSongs() }
    }

    private func fetchAllSongs() {
        let query = MPMediaQuery.songs()
        if let items = query.items {
            allSongs = items
        }
        musicPlayerHelper.nonShuffledSongs = allSongs
        musicPlayerHelper.shuffleSongs()
        allSongs = musicPlayerHelper.shuffledSongs
        updateSortedSongs()
    }

    private func updateSortedSongs() {
        switch sortMode {
        case .ppm:
            sortedSongs = allSongs.sorted { a, b in
                let v0 = calculatePPM(a)
                let v1 = calculatePPM(b)
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

    enum SortOption: String, CaseIterable, Identifiable {
        case name = "Name"
        case songs = "Songs"
        case medianPPM = "Median PPM"
        case total = "Total"
        case played = "Played"
        var id: String { rawValue }
    }

    @State private var sortOption: SortOption = .name

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

        switch sortOption {
        case .name:
            return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .songs:
            return base.sorted { $0.songCount > $1.songCount }
        case .medianPPM:
            return base.sorted { ($0.medianPPM.isNaN ? -Double.infinity : $0.medianPPM) > ($1.medianPPM.isNaN ? -Double.infinity : $1.medianPPM) }
        case .total:
            return base.sorted { $0.totalDuration > $1.totalDuration }
        case .played:
            return base.sorted { $0.playedDuration > $1.playedDuration }
        }
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
                            NavigationLink(destination: PlaylistView(selectedPlaylist: $selectedPlaylist, playlist: stat.playlist)) {
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
                .animation(.easeInOut(duration: 0.3), value: sortOption)
                .padding(.top)
            }

            Divider()
                .background(Color.gray.opacity(0.3))
                .frame(height: 1)
                .padding(.vertical, 8)
                .padding(.horizontal)

            // Sort picker moved below playlist cards
            Picker("Sort by", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            .background(Color.green.opacity(0.2))
            .cornerRadius(10)
            .frame(height: 50)
            .padding(.horizontal)

            Divider()
                .background(Color.gray.opacity(0.3))
                .frame(height: 1)
                .padding(.vertical, 8)
                .padding(.horizontal)

            // "All Songs" card-style NavigationLink after the Picker, with contextMenu
            NavigationLink(destination: AllSongsView()) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("All Songs")
                            .font(.headline)
                        let songs = MPMediaQuery.songs().items ?? []
                        let total = songs.reduce(0) { $0 + $1.playbackDuration }
                        let played = songs.reduce(0.0) { $0 + (Double($1.playCount) * $1.playbackDuration) }
                        // Median PPM for all songs
                        let allPPM = songs.compactMap { song -> Double? in
                            guard let addedDate = song.value(forKey: "dateAdded") as? Date else { return nil }
                            let months = Calendar.current.dateComponents([.month], from: addedDate, to: Date()).month ?? 0
                            if months <= 0 { return nil }
                            return Double(song.playCount - song.skipCount) / Double(months)
                        }.sorted()
                        let medianAllPPM: Double = {
                            guard !allPPM.isEmpty else { return .nan }
                            let mid = allPPM.count / 2
                            if allPPM.count % 2 == 0 {
                                return (allPPM[mid - 1] + allPPM[mid]) / 2.0
                            } else {
                                return allPPM[mid]
                            }
                        }()
                        HStack(spacing: 16) {
                            Label("\(songs.count)", systemImage: "music.note.list")
                            HStack(spacing: 4) {
                                Image(systemName: "chart.bar")
                                    .foregroundColor(medianAllPPM.isNaN ? .secondary : .blue)
                                Text(medianAllPPM.isNaN ? "--" : String(format: "%.2f", medianAllPPM))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Label(formatTime(total), systemImage: "clock")
                            Label(formatTime(played), systemImage: "play.circle")
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
                    let helper = MusicPlayerHelper()
                    let songs = MPMediaQuery.songs().items ?? []
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
