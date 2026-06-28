# yt-mp3

A small PowerShell script that saves the audio of a YouTube link as an MP3.

It wraps [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) and
[`ffmpeg`](https://ffmpeg.org/), saving MP3 audio with embedded cover art and
metadata.

It is **source-aware** about quality:

- **Lossless source** (FLAC, ALAC, WAV, …) → compressed down to a high-quality
  **mp3 V0** (≈245 kbps). Pass **`-Flac`** to keep the lossless original as-is
  instead (add `-Mp3` to keep the lossless original **and** make an mp3).
- **Lossy source** (Opus, AAC, mp3, …) → the **original track is saved as-is**.
  Pass **`-Mp3`** to also create an **mp3 capped at the source bitrate** (never
  above it, with a V0 ceiling for high-bitrate sources).

Because **YouTube audio is always lossy** (Opus ~129 kbps, or AAC), a YouTube
link gives you the original `.webm`/`.m4a` by default, plus a bitrate-matched
`.mp3` when you add `-Mp3`. Lossless sources from other sites yt-dlp supports
are always converted to mp3.

> Note: for `-Playlist` downloads the quality decision is probed from the first
> item and applied to the whole playlist.

## Usage

```powershell
.\yt-mp3.ps1 "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```

Multiple links and a custom output folder:

```powershell
.\yt-mp3.ps1 "https://youtu.be/abc" "https://youtu.be/def" -OutDir D:\Music
```

Get an mp3 from a lossy source (e.g. YouTube) alongside the original:

```powershell
.\yt-mp3.ps1 "https://youtu.be/abc" -Mp3
```

Local audio files work too (handy for converting lossless to mp3):

```powershell
.\yt-mp3.ps1 "E:\Music\track.flac"
```

Download a whole playlist (off by default):

```powershell
.\yt-mp3.ps1 "https://www.youtube.com/playlist?list=..." -Playlist
```

### Options

| Parameter   | Description                                              |
| ----------- | -------------------------------------------------------- |
| `Url`       | One or more YouTube URLs or local file paths (positional).      |
| `-OutDir`   | Where to save output. Defaults to the current directory.        |
| `-Mp3`      | Also create an mp3 for lossy sources (or alongside a kept `-Flac`). |
| `-Flac`     | Keep a lossless source as-is instead of converting it to mp3.    |
| `-Playlist` | Download the full playlist instead of just one video.           |

## Dependencies

The script needs `yt-dlp` and `ffmpeg`. On first run it tries to install both
automatically with `winget`. If that fails (e.g. winget needs interactive
approval), install them manually and re-run:

```powershell
winget install yt-dlp.yt-dlp
winget install Gyan.FFmpeg
```

## Notes

- Downloaded audio files are git-ignored so only the script and docs are tracked.
- If you hit a PowerShell execution-policy error, run the script for the current
  session with:
  `powershell -ExecutionPolicy Bypass -File .\yt-mp3.ps1 "<url>"`
