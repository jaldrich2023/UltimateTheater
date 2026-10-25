# Known issues and limitations

This page lists what Ultimate Theater 1.0 can't do yet, and what hasn't been fully tested. It's kept short and factual. If you run into something that isn't listed here, please [open a bug report](https://github.com/jaldrich2023/UltimateTheater/issues/new/choose).

## Status of this build

- **Version 1.0 is a development build.** It hasn't been released to the public.
- **The full automated test suite hasn't been run since the latest round of changes.** Individual tests were run while features were built, but there has been no complete pass since then.
- **Not yet tested on real devices or real files:** casting (Google Cast, DLNA, Roku), AirPlay video to an Apple TV, the iPhone remote, subtitle downloads from OpenSubtitles, and Skip Intro / Skip Credits detection. These features are built and have unit tests, but nobody has tried them end to end on real hardware or a real library yet.

## Formats

- **VC-1, WMV and WMA aren't supported.** WMV and ASF files are added to the library but marked as unplayable. VC-1 video inside MPEG-TS or M2TS files is reported as unsupported.
- **Nothing is ever transcoded.** The Theater engine plays files on the Mac as they are. Casting and AirPlay send the original file, so the receiving device has to support the format itself.
- **DTS plays the core only.** DTS-HD tracks play their DTS core. The lossless DTS-HD Master Audio extension and DTS:X objects aren't decoded.
- **Dolby TrueHD plays the lossless bed only.** Atmos tracks play their channel bed; Atmos height objects aren't rendered.
- **Files in other formats are added but flagged.** They show a "Can't Play" badge and a reason on the title page.

## AirPlay

- **AirPlay video only works with MP4, M4V or MOV files that use H.264 or HEVC video** (and AAC, Dolby Digital or Dolby Digital Plus sound) and that macOS can play directly. The Theater engine can't send its picture over AirPlay, so any other file sends **sound only**, through the player's Sound Output menu.
- **AirPlay sound runs about 2 seconds behind the picture** on the Mac. This is normal for AirPlay audio.
- **Moving on to the next episode brings playback back to the Mac.** You have to choose the Apple TV again for the new episode.

## Casting (Google Cast, DLNA, Roku)

- **The device has to support the file's format.** Nothing is converted. The Cast menu checks each file and explains why a device can't play it.
- **Roku:**
  - Video always starts from the beginning, and you can't seek from the Mac. Use the Roku remote to scan.
  - Play/Pause sends Roku's single Play key, which toggles. If the Roku and the Mac disagree about whether it's playing, the button can get out of step.
  - Volume works only on Roku TVs, or when the Roku controls the TV over HDMI-CEC.
  - Newer Roku OS versions can turn off "Control by mobile apps", which blocks casting completely.
- **Google Cast devices use self-signed certificates.** Ultimate Theater accepts the device's certificate for that one connection. This doesn't change what your Mac trusts anywhere else.
- **Media is sent over plain HTTP on your local network.** Each cast uses a random one-time link (a 256-bit token) that only works on the local network. It stops working when casting ends.
- **Only your Mac's primary network connection is searched** (the first active Ethernet or Wi-Fi connection). If your Mac is connected to more than one network or VLAN, devices on the other ones may not show up.
- **The first time you open the Cast menu, macOS asks for Local Network permission.** Finding devices can take a few seconds.
- **Your Mac must stay awake and on the same network** for the whole cast.

## iPhone remote

- **The connection is plain HTTP, with no encryption.** Someone who can watch your Wi-Fi traffic could read the pairing cookie. Only use the remote on a Wi-Fi network you trust.
- **Other devices on your network can retire a pairing code.** If they send enough wrong guesses, the code stops working and you'll need to make a new one on the Mac (Settings › Remote › New Code).
- **Pairings expire after 30 days without use.** The phone then has to be paired again.

## Skip Intro and Skip Credits

- **Intros and credits are found in the background**, either after a show is added or the first time an episode plays. Until then, the buttons only appear for files with chapter names like "Intro" or "Credits".
- **A recap shared between episodes ("Previously on…") can be mistaken for an intro.**
- **About 16 minutes of each episode is read** (the first 10 minutes and the last 6), which can be slow on a network drive.
- **Movies only get Skip Intro, and only from chapter names.** Movies never get Skip Credits.

## Subtitles

- **Downloading from OpenSubtitles needs your own API key.** The free tier allows only a handful of downloads a day (about 5). Signing in with an OpenSubtitles account raises the limit.
- **Sidecar subtitle files are only found inside watched folders.** A sidecar is a separate subtitle file next to the video, such as `Movie.en.srt`. Because the app is sandboxed, it can't read the video's folder unless that folder is in your library.
- **You can't delete a downloaded subtitle in the app.** Downloads are kept in the app's Application Support folder and are removed when the movie or episode is removed.
- **Subtitles are hidden in picture-in-picture.**

## Movie and TV information

- **Episode lengths come from the episode guide**, not from the files. If the guide doesn't have a length, the Episodes panel shows "—".
- **OMDb's terms only allow personal, non-commercial use.**
- **TMDB and OpenSubtitles need separate agreements for commercial use.**
- **On a Kids profile with nothing to show, the empty-page message lists US ratings** (G, PG, TV-Y and so on), even if your household uses another country's ratings.

## Watch Stats

- **Weekly time is counted in the week you last watched each title.** There's no full log of every viewing, so time spent on a title in earlier weeks is moved to its latest week.

## Security and parental controls

- **Anyone who knows the Mac's login password can reset the administrator PIN**, using "Forgot PIN? Use Mac Password…". Touch ID or an Apple Watch also works. This is the recovery path for a forgotten PIN.
- **The PIN lockout is stored in user defaults.** This is the count of wrong guesses and the waiting time. Someone who can edit the app's preferences could clear it.
- **Profile PINs are stored as salted SHA-256 hashes in the local users database** (Users.sqlite). Only the administrator PIN is kept in the Keychain. A 4-digit PIN protects against children, not against someone with access to your user account.

## User interface

- **English only.** The app is set up for translation (it has a String Catalog), but no translations have been added yet.
- **The Episodes panel stays open when you click other controls on the player bar.** Click outside the panel, press Escape, or click Episodes again to close it.
- **Space always plays or pauses the video**, even when a control has keyboard focus with Full Keyboard Access turned on.
- **The smallest window size is 1024 × 680 points.** There is only one main window.

## Development

- **Building requires Xcode 27.2 or later.** The project uses the new project file format (`project.xcproj`).
- **Debug builds are compiled with `-O` optimization** so the software decoders play in real time. Stepping through code in the debugger and inspecting variables works less well as a result.
- **Unit tests run inside the app.** The app opens empty in-memory databases and separate preferences for tests, so your real library is never touched.
- **Realtime engine tests don't run by default.** Choose the "Realtime" configuration of `Ultimate Theater.xctestplan` to run them. It sets `UT_RUN_REALTIME_TESTS=1`, and the tests also need an audio output device.

## Licensing

- **Some decoder tables were copied from FFmpeg, which is licensed under the LGPL 2.1 or later.** These are the Dolby TrueHD residual Huffman tables and noise table, and the DTS vector codebooks. See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for details.
- **The LGPL conflicts with the app's proprietary [LICENSE](../LICENSE).** This must be resolved before any commercial or App Store distribution.
