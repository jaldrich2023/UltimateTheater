# Third-Party Notices

Ultimate Theater links no third-party libraries. Its playback engine (container
readers, bitstream handling, its own DTS, TrueHD, MPEG-4 Part 2, VP8, Theora and DV
decoders, and the render pipeline) is original work built on Apple system frameworks
(AVFoundation, Core Media, VideoToolbox, AudioToolbox, SwiftUI, SwiftData, and WebKit),
written from public specifications where they exist. Where a format's specification
isn't public, third-party material was used only as far as necessary, as listed below.

## Codec reference material

### MPEG-4 Visual reference software (ISO/IEC 14496-5)

`Playback/MPEG4Decoder.swift` and `Playback/MPEG4Tables.swift` are an independent
implementation written using the ISO/IEC 14496-5 MPEG-4 Visual reference software
(Microsoft implementation, as distributed in mpeg4ip `common/video/iso-mpeg4`,
https://github.com/stsquad/mpeg4ip, commit 1a11af262c599c2607570c99cd3c724cde370186)
as documentation of ISO/IEC 14496-2. The standard's VLC codewords, scan orders and
default quantisation matrices were taken from its `vlc.hpp` and `global.hpp`. Its licence:

> This software module was originally developed by Ming-Chieh Lee, Wei-ge Chen, Bruce
> Lin, Chuang Gu, Simon Winder (Microsoft Corporation) … in the course of development of
> the MPEG-4 Video (ISO/IEC 14496-2). This software module is an implementation of a part
> of one or more MPEG-4 Video tools as specified by the MPEG-4 Video. ISO/IEC gives users
> of the MPEG-4 Video free license to this software module or modifications thereof for
> use in hardware or software products claiming conformance to the MPEG-4 Video. Those
> intending to use this software module in hardware or software products are advised that
> its use may infringe existing patents. The original developer of this software module
> and his/her company, the subsequent editors and their companies, and ISO/IEC have no
> liability for use of this software module or modifications thereof in an
> implementation. Copyright is not released for non MPEG-4 Video conforming products.
> Microsoft retains full right to use the code for his/her own purpose, assign or donate
> the code to a third party and to inhibit third parties from using the code for non
> <MPEG standard> conforming products. This copyright notice must be included in all
> copies or derivative works. Copyright (c) 1996, 1997.

### FFmpeg (LGPL 2.1 or later)

Copyright © the FFmpeg developers (https://ffmpeg.org). FFmpeg is licensed under the GNU
Lesser General Public License, version 2.1 or later
(https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html).

- **Dolby TrueHD / MLP** (`Playback/TrueHDDecoder.swift`, `Playback/TrueHDTables.swift`):
  the decoding process beyond Dolby's public high-level bitstream description was
  learned from FFmpeg's `mlpdec.c`, `mlp.c`, `mlp.h`, `mlpdsp.c` and `mlp_parse.c`
  (copyright Ian Caulfield 2007–2008, Ramiro Polla 2009; commit
  bf0e831606938f530326c9679591109407fa8d0d). The residual Huffman tables
  (`ff_mlp_huffman_tables`) and the 256-entry noise table were transcribed from them.
- **DTS vector codebooks** (`Playback/DTSVectorTables.swift`): the ADPCM prediction
  codebook and high-frequency subband vectors that ETSI TS 102 114 clause D.10 omits,
  transcribed from FFmpeg's `dcadata.c` (copyright Gildas Bazin 2004, Benjamin Larsson
  2006; commit 303510f9d1fe19bcae440df0d940f33616d93bf5).

Because these files contain material from FFmpeg, they are covered by the LGPL: their
source must be made available to recipients of the app, and recipients may modify them.
Review this before any commercial distribution.

The VP8 decoder follows RFC 6386 (its constant tables come from the RFC text), the
Theora decoder the Xiph.Org Theora specification, and the DTS core decoder ETSI
TS 102 114.

The app retrieves movie and TV information from the services below at the user's
request. Their data remains subject to each provider's terms, and the app shows
the required attributions in its About window, Settings, and title pages.

| Service | Used for | Terms | Attribution required |
| --- | --- | --- | --- |
| [TMDB](https://www.themoviedb.org) | Primary metadata, artwork, trailers, collections | [TMDB API Terms of Use](https://www.themoviedb.org/api-terms-of-use) | The TMDB logo (less prominent than the app's own marks) and the notice "This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB." |
| [OMDb API](https://www.omdbapi.com) | IMDb, Rotten Tomatoes, and Metacritic scores; MPAA ratings | [OMDb Terms](https://www.omdbapi.com/legal.htm) | No attribution required; terms permit **personal, non-commercial use only** |
| [TVmaze](https://www.tvmaze.com) | TV shows and episode guides | [TVmaze API License](https://www.tvmaze.com/api#licensing) | Data licensed [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| [Wikipedia](https://www.wikipedia.org) | Synopses and lead images | [Wikimedia Terms of Use](https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use) | Text licensed [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/); images carry their own licenses |
| [OpenSubtitles.com](https://www.opensubtitles.com) | Subtitle search and download, with the user's own API key | [OpenSubtitles Terms of Service](https://www.opensubtitles.com/en/tos) | Credit OpenSubtitles as the source; the free tier is for personal use, and commercial distribution likely needs a paid plan or agreement |

Trailers are played in the provider's official embedded player (YouTube or Vimeo)
and remain subject to that provider's terms.

## Content ratings

Film and TV ratings come from each country's rating authority, as published by
TMDB and OMDb, and are shown for the household's chosen ratings country. Ultimate
Theater isn't affiliated with or endorsed by any rating authority.

- G, PG, PG-13, R, and NC-17 are certification marks of the Motion Picture
  Association (MPA). Film ratings are assigned by the Classification and Rating
  Administration (https://www.filmratings.com).
- TV-Y, TV-Y7, TV-G, TV-PG, TV-14, and TV-MA are TV Parental Guidelines ratings,
  administered by the TV Parental Guidelines Monitoring Board
  (http://www.tvguidelines.org).
- Ratings from other countries (for example BBFC, FSK, CNC, Eirin, CBFC, and
  DJCTQ) belong to their respective authorities.

The TMDB logo in the app's asset catalog is TMDB's official mark, included as their
terms require; it remains TMDB's property.

Users supply their own API keys for TMDB and OMDb and are responsible for using
those services within their terms. Commercial distribution of the app may require
a commercial agreement with TMDB, and OMDb's terms do not permit commercial use;
review both before release.
