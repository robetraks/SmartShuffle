import SwiftUI
import MediaPlayer

@main
struct MusicShuffleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var playlists: [MPMediaPlaylist] = []
    @State private var selectedPlaylist: MPMediaPlaylist? = nil
    @State private var isAuthorized = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationView {
            PlaylistStatsView(selectedPlaylist: $selectedPlaylist, playlists: playlists)
                .onAppear {
                    requestAuthorization()
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
    @Published var shuffledSongs: [MPMediaItem] = []
    @Published var nonShuffledSongs: [MPMediaItem] = []
    @Published var isLoading = false
    @Published var timer: Timer?
    @Published var progress: Double = 0

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
        let affinityScore = playlistSongs.isEmpty ? 0 : playedDuration / Double(playlistSongs.count)
        let mostPlayedSong = playlistSongs.max(by: { $0.playCount < $1.playCount })

        return AnyView(
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 24) {
                    Label("\(playlistSongs.count)", systemImage: "music.note.list")
                        .labelStyle(VerticalMetricLabelStyle(title: "Songs"))
                    Label(formatTime(totalDuration), systemImage: "clock")
                        .labelStyle(VerticalMetricLabelStyle(title: "Total Duration"))
                    Label(formatTime(playedDuration), systemImage: "play.circle")
                        .labelStyle(VerticalMetricLabelStyle(title: "Played"))
                    Label(formatTime(affinityScore), systemImage: "star.fill")
                        .labelStyle(VerticalMetricLabelStyle(title: "Affinity Score"))
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
            .background(Color.blue.opacity(0.2))
            .cornerRadius(10)
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
    @State private var allSongs: [MPMediaItem] = []
    @ObservedObject private var musicPlayerHelper = MusicPlayerHelper()

    var body: some View {
        SongListView(songs: allSongs, musicPlayerHelper: musicPlayerHelper, playlistInfoCard: playlistInfoCard)
            .onAppear {
                fetchAllSongs()
            }
            .onDisappear {
                musicPlayerHelper.timer?.invalidate()
            }
    }
    
    private func fetchAllSongs() {
        let query = MPMediaQuery.songs()
        if let items = query.items {
            allSongs = items
        }
        musicPlayerHelper.nonShuffledSongs = allSongs
        musicPlayerHelper.shuffleSongs()
        allSongs = musicPlayerHelper.shuffledSongs
    }

    private var playlistInfoCard: AnyView {
        let totalDuration = allSongs.reduce(0) { $0 + $1.playbackDuration }
        let playedDuration = allSongs.reduce(0.0) { result, item in
            let count = item.playCount
            return result + (Double(count) * item.playbackDuration)
        }
        let affinityScore = allSongs.isEmpty ? 0 : playedDuration / Double(allSongs.count)
        let mostPlayedSong = allSongs.max(by: { $0.playCount < $1.playCount })

        return AnyView(
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 24) {
                    Label("\(allSongs.count)", systemImage: "music.note.list")
                        .labelStyle(VerticalMetricLabelStyle(title: "Songs"))
                    Label(formatTime(totalDuration), systemImage: "clock")
                        .labelStyle(VerticalMetricLabelStyle(title: "Total Duration"))
                    Label(formatTime(playedDuration), systemImage: "play.circle")
                        .labelStyle(VerticalMetricLabelStyle(title: "Played"))
                    Label(formatTime(affinityScore), systemImage: "star.fill")
                        .labelStyle(VerticalMetricLabelStyle(title: "Affinity Score"))
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
            .background(Color.blue.opacity(0.2))
            .cornerRadius(10)
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
        case affinity = "Affinity"
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
        let affinityScore: TimeInterval
    }

    var sortedStats: [Stats] {
        let visiblePlaylists = isSelectMode ? playlists : playlists.filter {
            localSelectedIDs.isEmpty || localSelectedIDs.contains($0.persistentID)
        }
        let base = visiblePlaylists.map { playlist in
            let songs = playlist.items
            let total = songs.reduce(0) { $0 + $1.playbackDuration }
            let played = songs.reduce(0.0) { $0 + (Double($1.playCount) * $1.playbackDuration) }
            let affinity = songs.isEmpty ? 0 : played / Double(songs.count)
            return Stats(playlist: playlist, songCount: songs.count, totalDuration: total, playedDuration: played, affinityScore: affinity)
        }

        switch sortOption {
        case .name:
            return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .songs:
            return base.sorted { $0.songCount > $1.songCount }
        case .affinity:
            return base.sorted { $0.affinityScore > $1.affinityScore }
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
                                HStack {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(stat.name)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        HStack(spacing: 16) {
                                            Label("\(stat.songCount)", systemImage: "music.note.list")
                                            Label(formatTime(stat.affinityScore), systemImage: "star.fill")
                                            Label(formatTime(stat.totalDuration), systemImage: "clock")
                                            Label(formatTime(stat.playedDuration), systemImage: "play.circle")
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
                        let affinity = songs.isEmpty ? 0 : played / Double(songs.count)
                        HStack(spacing: 16) {
                            Label("\(songs.count)", systemImage: "music.note.list")
                            Label(formatTime(affinity), systemImage: "star.fill")
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
