# Ultimate Theater

**Your movies. Your theater.** Ultimate Theater is a home-theater app for macOS. It plays the movies and TV shows on your own drives in its own playback engine, and presents them like a streaming service.

![Platform: macOS 27+](https://img.shields.io/badge/platform-macOS%2027%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-FF3D5A?logo=swift&logoColor=white)
![License: proprietary](https://img.shields.io/badge/license-proprietary-3B5BFF)

![Ultimate Theater Home screen](docs/images/01-home.jpg)

## Overview

Point Ultimate Theater at your movie and TV folders, on the Mac, on an external drive, or on a NAS. It identifies every title, brings in posters, cast lists, ratings and episode guides, and gives each person in the household their own profile, with progress, My List, ratings and parental limits. Files play in the **Theater engine**, which was written for this app. It reads MKV, AVI, MP4/MOV, MPEG-TS/M2TS, VOB, Ogg, FLV, WebM and DV files, and has its own decoders for DTS, Dolby TrueHD, MPEG-4 Part 2, VP8, Theora and DV. When you'd rather watch on the TV, it can cast to an Apple TV, Chromecast, DLNA smart TV or Roku.

**Documentation**

- [User Manual](docs/USER_MANUAL.md) · [PDF](docs/Ultimate-Theater-User-Manual.pdf)
- [Brochure (PDF)](docs/Ultimate-Theater-Brochure.pdf)
- [Known issues and limitations](docs/KNOWN_ISSUES.md)
- [Changelog](CHANGELOG.md)

## Features

- **Its own playback engine.** MKV, AVI, MP4/MOV, TS/M2TS, VOB, Ogg, FLV, WebM and DV files, with H.264, HEVC (including HDR10 and Dolby Vision), AV1, VP8/VP9, MPEG-2, MPEG-4 Part 2 (Xvid/DivX), DTS, Dolby TrueHD (lossless), Dolby Digital/Plus, FLAC and Opus. Subtitles in SRT, ASS, PGS, VobSub, DVB and Teletext. It can also repair damaged files.
- **Information added automatically.** Details come from TMDB, OMDb, TVmaze and Wikipedia, with **Fix Match** and **Edit Info** for anything that comes out wrong.
- **Collections and Made for You.** Movie series are grouped automatically, plus smart collections: In Progress, Recently Watched, Unwatched, Highly Rated, and one for each decade.
- **Profiles for the household.** Optional PINs, one household administrator, and content limits that follow the ratings of 48 countries.
- **Picks up where you left off.** Watched tracking, Continue Watching, favourite scenes, your own ratings, and Watch Stats.
- **Binge-friendly.** Skip Intro and Skip Credits, Up Next with autoplay, and "Are you still watching?".
- **A cinematic player.** A synopsis panel, an Episodes panel, picture-in-picture, full screen, a live Dock preview and Dock menu, and media keys. Your Mac won't sleep while something is playing.
- **Watch on the big screen.** AirPlay, Google Cast, DLNA and Roku casting.
- **iPhone remote.** A web remote for any phone on your Wi-Fi, paired with a QR code.
- **Subtitle downloads** from OpenSubtitles.com, using your own key.
- **Watched folders, including NAS shares.** New files wait for the administrator's approval before they're added.

| | |
| --- | --- |
| ![Movies grid with filters and A–Z bar](docs/images/02-movies.jpg) | ![Title page](docs/images/07-title.jpg) |
| **Browse** with filters, sorting and an A–Z bar | **Title pages** with Resume, tracks and episodes |
| ![Player](docs/images/08-player.jpg) | ![Episodes panel](docs/images/10-episodes.jpg) |
| **The player** with all its controls in one glass bar | **The Episodes panel**, inside the player |
| ![Collections and Made for You](docs/images/04-collections.jpg) | ![Watch Stats](docs/images/05-stats.jpg) |
| **Collections** and **Made for You** | **Watch Stats** for each profile |

## Requirements

- macOS 27.0 or later.
- To build from source: Xcode 27.2 or later.
- Optional: free API keys for [TMDB](https://www.themoviedb.org/settings/api), [OMDb](https://www.omdbapi.com/apikey.aspx) and [OpenSubtitles](https://www.opensubtitles.com/consumers). TVmaze and Wikipedia need no key.

## Building from source

1. Install **Xcode 27.2 or later**. The project uses the new project file format (`Ultimate Theater.xcodeproj/project.xcproj`).
2. Open `Ultimate Theater.xcodeproj`.
3. Choose the **Ultimate Theater** scheme and **My Mac** as the run destination.
4. **Signing.** The project is set to the original developer's team. Under *Signing & Capabilities*, choose your own team for the `Ultimate Theater`, `Ultimate TheaterTests` and `Ultimate TheaterUITests` targets. You may also need to change the bundle identifier.
5. Build and run (⌘R). The first launch opens the setup guide.

> Debug builds are compiled with `-O` optimization so the software decoders play in real time. This makes stepping through code in the debugger less reliable.

### Tests

Tests are organized in the test plan `Ultimate Theater.xctestplan`, which has two configurations:

- **Default.** The unit and UI tests. They run inside the app, which opens empty in-memory databases and separate preferences, so your real library is never touched.
- **Realtime.** Default plus the realtime playback-engine tests. This configuration sets `UT_RUN_REALTIME_TESTS=1`, and the tests need an audio output device.

Run them with ⌘U in Xcode, or from the command line:

```sh
xcodebuild test -project "Ultimate Theater.xcodeproj" -scheme "Ultimate Theater" \
  -testPlan "Ultimate Theater" -only-test-configuration Default
```

## Project structure

```
Ultimate Theater/                 App source
├── Ultimate_TheaterApp.swift     App entry point, windows, menu commands (Playback, Profile…)
├── AppModel.swift                App state: profiles, navigation, PIN prompts, playback
├── ContentView.swift             Main window: sidebar, navigation, player placement
├── Playback/                     The Theater engine
│   ├── TheaterEngine.swift       Render pipeline, seeking, track selection
│   ├── Container.swift, *Demuxer.swift, *Reader.swift
│   │                             Readers: Matroska/WebM, AVI, MP4/MOV, MPEG-TS, MPEG-PS, Ogg, FLV, DV
│   ├── DTSDecoder.swift, TrueHDDecoder.swift, MPEG4Decoder.swift, VP8Decoder.swift, TheoraDecoder.swift
│   │                             The app's own decoders
│   ├── ImageSubtitles.swift, Teletext.swift, ExternalSubtitles.swift
│   │                             PGS, VobSub, DVB, Teletext, SRT and WebVTT subtitles
│   ├── SkipSegments.swift        Intro and credits detection
│   ├── AirPlay.swift             AirPlay video handoff and sound output
│   └── SleepPrevention.swift     Keeps the Mac awake during playback
├── Cast/                         Google Cast (CASTV2), DLNA/UPnP, Roku (ECP), SSDP discovery,
│                                 the local media server, format compatibility, Cast menu
├── Remote/                       iPhone web remote: HTTP server, pairing, web page, Now Playing
├── Library/                      Media library, filename parser, folder watching, file repair,
│                                 SQLite stores
├── Metadata/                     TMDB, OMDb, TVmaze, Wikipedia and OpenSubtitles providers
├── Models/                       Titles, profiles, PINs, content ratings, watch history
├── Views/                        SwiftUI screens: Home, browse grids, title page, player,
│                                 collections, Watch Stats, profiles, setup guide, Settings, About
├── Assets.xcassets               App icon, accent color, TMDB logo
├── Localizable.xcstrings         String Catalog (English)
└── PrivacyInfo.xcprivacy         Privacy manifest (no tracking, no data collected)
Ultimate TheaterTests/            Unit tests: containers, decoders, subtitles, library, casting, remote
Ultimate TheaterUITests/          UI tests
Ultimate Theater.xctestplan       Test plan (Default and Realtime configurations)
docs/                             Manual, brochure, known issues, screenshots
```

Ultimate Theater uses no third-party libraries or packages. Everything is built on Apple's system frameworks: SwiftUI, SwiftData, AVFoundation, Core Media, VideoToolbox, AudioToolbox, Network and WebKit.

## Data sources and attribution

<img src="docs/images/tmdb-logo.svg" alt="TMDB" height="14">

*This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.*

- **[TMDB](https://www.themoviedb.org).** Movie and TV information, artwork, trailers and collections.
- **[TVmaze](https://www.tvmaze.com).** TV shows and episode guides, licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
- **[Wikipedia](https://www.wikipedia.org).** Synopses and images by Wikipedia contributors. The text is licensed under CC BY-SA 4.0; images carry their own licences.
- **[OMDb API](https://www.omdbapi.com).** IMDb, Rotten Tomatoes and Metacritic scores, which are trademarks of their respective owners. OMDb's terms allow personal, non-commercial use only.
- **[OpenSubtitles.com](https://www.opensubtitles.com).** Subtitles contributed by its community, subject to its [terms of service](https://www.opensubtitles.com/en/tos).
- **Content ratings.** G, PG, PG-13, R and NC-17 are certification marks of the Motion Picture Association. TV-Y, TV-Y7, TV-G, TV-PG, TV-14 and TV-MA are TV Parental Guidelines ratings. Ratings from other countries belong to their respective authorities.

Movie and TV artwork in the screenshots belongs to its respective rights holders.

## License

Ultimate Theater is **proprietary software**. © 2026 John Aldrich. All rights reserved. The source code is published for reference only. Having access to it doesn't give you any right to use, copy, modify or distribute it. See [LICENSE](LICENSE).

Codec reference material and data-provider terms are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Some decoder tables are covered by the LGPL. See [Known issues › Licensing](docs/KNOWN_ISSUES.md#licensing).

Bug reports and feature requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md), and [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## Author

**John Aldrich** · [github.com/jaldrich2023](https://github.com/jaldrich2023)
