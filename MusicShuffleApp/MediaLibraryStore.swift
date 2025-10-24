import Foundation
import MediaPlayer
import Combine

// Centralized, async-loaded media library cache and lightweight derived metrics
final class MediaLibraryStore: ObservableObject {
    @Published private(set) var allSongs: [MPMediaItem] = []
    @Published private(set) var playlists: [MPMediaPlaylist] = []

    @Published private(set) var authorizationStatus: MPMediaLibraryAuthorizationStatus = .notDetermined
    @Published var authorizationErrorMessage: String? = nil

    // Summary metrics for the entire library (precomputed off the main thread)
    struct LibrarySummary {
        let songCount: Int
        let totalDuration: TimeInterval
        let playedDuration: TimeInterval
        let medianPPM: Double? // nil if undefined
    }
    @Published private(set) var librarySummary: LibrarySummary? = nil

    // Cache for per-song PPM to avoid recomputation in lists
    private var ppmCache: [UInt64: Double] = [:]
    private let computeQueue = DispatchQueue(label: "MediaLibraryStore.compute", qos: .userInitiated)

    // MARK: - Authorization
    func requestAuthorizationAndLoad() {
        let status = MPMediaLibrary.authorizationStatus()
        authorizationStatus = status
        switch status {
        case .authorized:
            loadAll()
        case .denied, .restricted:
            authorizationErrorMessage = "Please enable Music access in Settings"
        case .notDetermined:
            MPMediaLibrary.requestAuthorization { [weak self] newStatus in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.authorizationStatus = newStatus
                    if newStatus == .authorized {
                        self.loadAll()
                        self.authorizationErrorMessage = nil
                    } else {
                        self.authorizationErrorMessage = "Music access is required for this app"
                    }
                }
            }
        @unknown default:
            authorizationErrorMessage = "Unknown authorization status"
        }
    }

    // MARK: - Loading
    func loadAll() {
        loadSongs()
        loadPlaylists()
    }

    func loadSongs() {
        computeQueue.async { [weak self] in
            guard let self = self else { return }
            let items = MPMediaQuery.songs().items ?? []
            DispatchQueue.main.async {
                self.allSongs = items
                self.recomputeLibrarySummaryOnBackground()
                self.ppmCache.removeAll(keepingCapacity: true)
            }
        }
    }

    func loadPlaylists() {
        computeQueue.async { [weak self] in
            guard let self = self else { return }
            let pls = (MPMediaQuery.playlists().collections as? [MPMediaPlaylist]) ?? []
            DispatchQueue.main.async {
                self.playlists = pls
            }
        }
    }

    // MARK: - Derived metrics
    func ppm(for item: MPMediaItem) -> Double {
        let id = item.persistentID
        if let v = ppmCache[id] { return v }
        let v = calculatePPMInternal(item)
        ppmCache[id] = v
        return v
    }

    private func calculatePPMInternal(_ song: MPMediaItem) -> Double {
        guard let addedDate = song.value(forKey: "dateAdded") as? Date else { return .nan }
        let months = Calendar.current.dateComponents([.month], from: addedDate, to: Date()).month ?? 0
        if months == 0 { return .nan }
        return Double(song.playCount - song.skipCount) / Double(months)
    }

    private func recomputeLibrarySummaryOnBackground() {
        let songs = allSongs // snapshot on main
        computeQueue.async { [weak self] in
            guard let self = self else { return }
            let songCount = songs.count
            var totalDuration: TimeInterval = 0
            var playedDuration: TimeInterval = 0
            var ppmValues: [Double] = []
            ppmValues.reserveCapacity(max(0, songCount / 4))

            for s in songs {
                totalDuration += s.playbackDuration
                playedDuration += Double(s.playCount) * s.playbackDuration
                let v = self.calculatePPMInternal(s)
                if !v.isNaN, v.isFinite { ppmValues.append(v) }
            }
            ppmValues.sort()
            let medianPPM: Double? = {
                guard !ppmValues.isEmpty else { return nil }
                let mid = ppmValues.count / 2
                if ppmValues.count % 2 == 0 {
                    return (ppmValues[mid - 1] + ppmValues[mid]) / 2.0
                } else {
                    return ppmValues[mid]
                }
            }()
            let summary = LibrarySummary(songCount: songCount, totalDuration: totalDuration, playedDuration: playedDuration, medianPPM: medianPPM)
            DispatchQueue.main.async {
                self.librarySummary = summary
            }
        }
    }
}
