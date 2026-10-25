# Security policy

## Reporting a vulnerability

**Please don't report security problems in public issues.**

Report them privately using GitHub's private vulnerability reporting:

1. Go to the repository's **[Security](https://github.com/jaldrich2023/UltimateTheater/security)** tab.
2. Click **Report a vulnerability**. This opens a private Security Advisory that only you and the maintainer can see.
3. Include:
   - what the problem is and what someone could do with it,
   - the steps to reproduce it,
   - the version of Ultimate Theater and of macOS,
   - for problems that depend on a file, the container and codecs. Please don't attach copyrighted media or personal files; describe them, or provide a small sample file you made yourself.

You'll get an acknowledgement as soon as possible, followed by updates as the issue is investigated and fixed. Please give a reasonable amount of time for a fix before you disclose anything publicly.

## Supported versions

| Version | Supported |
| --- | --- |
| 1.0 (development build) | Yes |

## Scope

In scope:

- **The iPhone remote server** (`Remote/`). It's an HTTP server on the local network, advertised over Bonjour as `_ultimatetheater._tcp` (it prefers port 52525). It's off by default. The administrator turns it on, and only paired devices can control playback.
  - **Pairing:** a six-digit code that works once and expires after 10 minutes. Wrong guesses are throttled.
  - **Paired devices:** each gets a random 256-bit token in an HttpOnly, SameSite=Strict cookie that lasts 30 days. Only a SHA-256 hash of the token is stored.
  - **Requests:** each request's Host header is checked (protection against DNS rebinding), commands need a JSON body and a custom header, and responses never include file paths.
- **The casting media server** (`Cast/MediaServer.swift`). It serves exactly one file and its poster to devices on the local network, at paths containing a fresh 256-bit random token. The token is revoked when casting stops.
- **The casting protocol clients** (Google Cast, DLNA/UPnP, Roku ECP and SSDP): how they handle replies from untrusted devices. The clients parse UPnP device descriptions and SOAP replies, Roku responses, and Cast messages.
- **Parsing untrusted media files:** the container readers, decoders and subtitle parsers in `Playback/`, and the repair tools in `Library/`.
- **Handling PINs and API keys** (`Models/ProfileSecurity.swift`, and the Keychain storage).

Known, documented limitations are not treated as vulnerabilities. They're described in [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md):

- The remote and the casting server use plain HTTP on the local network, with no TLS.
- Google Cast devices' self-signed certificates are accepted for each connection.
- The administrator PIN can be reset by someone who knows the Mac's login password.
- PIN lockout state is stored in user defaults.
- Discovery uses the Mac's primary network interface only.

Reports that show these limitations can be exploited in a way that goes beyond what's described there are welcome.

Out of scope: vulnerabilities in macOS, or in the third-party services the app talks to (TMDB, OMDb, TVmaze, Wikipedia, OpenSubtitles, YouTube, Vimeo), and in casting devices' own firmware. Please report those to the companies that make them.
