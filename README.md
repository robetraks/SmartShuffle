# MusicShuffleApp

SmartShuffle is a Swift-based iOS app that enhances the way users shuffle their Apple Music playlists and entire music libraries using Apple’s MediaPlayer framework. When playing long playlists on shuffle, some songs may repeat frequently while others go unheard. SmartShuffle’s intelligent algorithm ensures a more balanced shuffle experience.

The app’s algorithm considers the last played time of each song to determine the shuffle order. It assigns a selection probability to each track, ensuring that recently played songs have a lower chance of being repeated, while less-played tracks get prioritized.

## Features

- Shuffle and play songs from a selected playlist.
- Shuffle and play all songs from the user's music library.
- Display song details including artwork, title, and artist.
- Play songs directly in Apple Music.

## Requirements

- iOS 14.0+
- Xcode 12.0+
- Swift 5.0+

## Installation

1. Clone the repository:

   ```bash
   git clone https://github.com/YOUR_GITHUB_USERNAME/MusicShuffleApp.git
   ```

2. Open the project in Xcode:

   ```bash
   cd MusicShuffleApp
   open MusicShuffleApp.xcodeproj
   ```

3. Build and run the project on a simulator or a physical device.

## Usage

- Launch the app on your iOS device.
- Select a playlist or view all songs.
- Tap on the "Play in Apple Music" button to shuffle and play songs.
