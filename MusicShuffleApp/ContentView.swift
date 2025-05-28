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
            List {
                // Add an entry for "All Songs"
                NavigationLink(destination: AllSongsView()) {
                    Text("All Songs")
                }
                
                ForEach(playlists, id: \.persistentID) { playlist in
                    NavigationLink(destination: PlaylistView(selectedPlaylist: $selectedPlaylist, playlist: playlist)) {
                        Text(playlist.name ?? "Unknown Playlist")
                    }
                }
            }
            .navigationTitle("Playlists")
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
        if days.allSatisfy({ $0 == -1 }){
            return Array(0..<days.count)
        }
        
        // Step 1: Separate non-zero elements and their indexes
        let indexedDays = days.enumerated().filter { $0.element > 0 }  // [(index, value)]
        let zeroIndexes = days.enumerated().filter { $0.element == 0 }.map { $0.offset } // [index of zeros]

        // Step 2: Sort non-zero elements in descending order while keeping their original indexes
        let sortedIndexedDays = indexedDays.sorted { $0.element > $1.element } // [(index, value)]
        
        // Step 3: Calculate probabilities for non-zero elements
        let totalSum = sortedIndexedDays.reduce(0) { $0 + $1.element }
        let probabilities = sortedIndexedDays.map { Double($0.element) / Double(totalSum) } // Probabilities

        // Step 4: Randomly pick indexes of non-zero elements based on probabilities
        var indexes = Array(0..<sortedIndexedDays.count) // Track available indexes
        var selectedIndexes: [Int] = [] // Result array (stores original indexes)
        var remainingProbabilities = probabilities

        while !remainingProbabilities.isEmpty {
            let randomValue = Double.random(in: 0..<1) // Generate random number
            var cumulativeProbability = 0.0
            var pickedIndex = -1

            // Find the index matching the random value
            for (index, probability) in remainingProbabilities.enumerated() {
                cumulativeProbability += probability
                if randomValue < cumulativeProbability {
                    pickedIndex = index
                    break
                }
            }

            // Add the selected index and remove it from the remaining lists
            if pickedIndex != -1 {
                selectedIndexes.append(sortedIndexedDays[indexes[pickedIndex]].offset) // Add the original index
                remainingProbabilities.remove(at: pickedIndex)
                indexes.remove(at: pickedIndex)
            }
        }

        // Step 5: Append zero indexes at the end
        selectedIndexes.append(contentsOf: zeroIndexes)

        return selectedIndexes
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
                    
                    VStack(alignment: .leading) {
                        Text(song.title ?? "Unknown Song")
                            .font(.body)
                        Text(song.artist ?? "Unknown Artist")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    
                    Spacer()
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

        let columns = [GridItem(.flexible()), GridItem(.flexible())]

        return AnyView(
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: columns, spacing: 16) {
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
                    Text(song.title ?? "Unknown")
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

        let columns = [GridItem(.flexible()), GridItem(.flexible())]

        return AnyView(
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: columns, spacing: 16) {
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
                    Text(song.title ?? "Unknown")
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
