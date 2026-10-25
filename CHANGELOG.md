# Changelog

All notable changes to Ultimate Theater are recorded in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] — Unreleased

The first version of Ultimate Theater. It's a development build and hasn't been released yet. See [Known issues](docs/KNOWN_ISSUES.md) for what is still untested.

### Added

#### Playback

- **The Theater engine,** the app's own playback engine, built on Apple's media frameworks. It reads MP4, M4V, MOV, 3GP, MKV, WebM, AVI, MPEG-TS and M2TS (Blu-ray and AVCHD), MPEG program streams (MPG, VOB), Ogg, FLV and DV files.
- **The app's own decoders** for DTS (core), Dolby TrueHD/MLP (lossless, including Atmos beds), MPEG-4 Part 2 (Xvid/DivX), VP8, Theora and DV. Apple's decoders handle H.264, HEVC (HDR10, HLG, Dolby Vision), AV1, VP9, MPEG-1/2, ProRes, AAC, Dolby Digital/Plus, FLAC, Opus and others.
- **Subtitles:** SRT, ASS/SSA, MP4 text, Blu-ray PGS, DVD (VobSub), DVB and Teletext, plus separate `.srt` and `.vtt` files stored next to the video.
- **Choosing audio and subtitle tracks,** with the choice remembered for each profile, either for every title or for one title.
- **The player:** one glass bar with the title's info and the controls, a synopsis panel, an Episodes panel, a paused screen, Save Scene (favourite scenes), full screen, and picture-in-picture docked in the sidebar.
- **Skip Intro and Skip Credits.** Intros and credits are found from chapter names, or by comparing an episode's sound with the episodes around it.
- **Up Next** with a 15-second countdown, autoplay of the next episode, and "Are you still watching?" after three episodes play with nobody touching anything.
- **A Playback menu** with single-key shortcuts, a live Dock preview and Dock menu, media keys and Now Playing.
- **Sleep prevention** while a video plays.

#### Library

- **Adding movies and shows** from files, folders, or by drag and drop. Titles, years and episode numbers are read from the file and folder names.
- **Watched folders, including network shares (NAS).** New videos wait for the administrator's approval. Deleted videos leave the library, and titles on a disconnected drive are kept.
- **Manage Library:** a table of every title with its status, an approval queue, rescanning, Refresh Info, Fix Match and Edit Info (with Lock info).
- **Repairing damaged files** in every supported format, with the repaired copy saved separately from the original.
- **Remove from Library, or Move to Trash.**
- **Two separate SQLite databases:** the master library, and the household's users. If a database can't be opened, the app offers to move it aside and start fresh.

#### Movie and TV information

- **Automatic information** from TMDB (the main source), OMDb, TVmaze and Wikipedia: artwork, cast, ratings, episode guides and trailers.
- **Movie collections** from TMDB, with placeholders for movies you don't have, and **Made for You** smart collections: In Progress, Recently Watched, Unwatched, Highly Rated, and one for each decade.
- **Subtitle search and download** from OpenSubtitles.com, using the household's own key.

#### Browsing

- **Home,** with a hero carousel, Continue Watching, Recently Watched, Recently Added, Top Rated, My List, Because You Watched, and genre rows.
- **Movies and TV Shows grids,** with multi-select filters (Genre, Year, Rated, Studio, Writer, Director, Actors, My Rating), sort submenus and an A–Z bar.
- **Recently Added, My List and Search.**
- **Title pages:** Resume and Start Over, My List, Mark Watched, Trailer, your own rating, episodes with watched toggles, Favourite Scenes, and More Like This.
- **Watch Stats** for each profile: totals, the last 12 weeks, favourite genres, most-watched shows, and what's in progress.

#### Profiles and parental controls

- **Profiles** with a name, color, icon or picture, and an optional PIN, plus one household administrator.
- **An administrator PIN** that protects managing profiles and the library, with a growing lockout after wrong guesses and recovery using the Mac's password.
- **Content limits** (Little Kids, Older Kids, Teens, All Ratings) that follow the rating systems of 48 countries.
- **A setup guide** for the first launch.

#### Casting and remote

- **AirPlay:** video to an Apple TV for compatible files, and sound to any AirPlay output.
- **Casting to Google Cast, DLNA/UPnP and Roku devices,** with a format check for each device.
- **An iPhone web remote,** paired with a QR code or a six-digit code, with revocable 30-day pairings.

#### App

- **A Liquid Glass interface** on a dark, cinematic background.
- **An About window** with the license, the third-party notices, and data-source credits.
- **A privacy manifest:** no tracking, and no data collected.

[Unreleased]: https://github.com/jaldrich2023/UltimateTheater/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/jaldrich2023/UltimateTheater/releases/tag/v1.0.0
