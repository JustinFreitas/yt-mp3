# yt-mp3

A small PowerShell script that saves the audio of a YouTube link as an MP3.

It wraps [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) and
[`ffmpeg`](https://ffmpeg.org/), saving MP3 audio with embedded cover art and
metadata.

It is **source-aware** about quality:

- **Lossless source** (FLAC, ALAC, WAV, …) → compressed down to a high-quality
  **mp3 V0** (≈245 kbps). The lossless original is not kept.
- **Lossy source** (Opus, AAC, mp3, …) → the **original track is kept as-is**
  *and* an **mp3 is produced, capped at the source bitrate** (never above it,
  with a V0 ceiling for high-bitrate sources).

Because **YouTube audio is always lossy** (Opus ~129 kbps, or AAC), a YouTube
link gives you **both** the original `.webm`/`.m4a` *and* a bitrate-matched
`.mp3`. mp3-only output (no original kept) happens for lossless sources from
other sites yt-dlp supports.

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

Download a whole playlist (off by default):

```powershell
.\yt-mp3.ps1 "https://www.youtube.com/playlist?list=..." -Playlist
```

### Options

| Parameter   | Description                                              |
| ----------- | -------------------------------------------------------- |
| `Url`       | One or more YouTube URLs (positional).                   |
| `-OutDir`   | Where to save MP3s. Defaults to the current directory.   |
| `-Playlist` | Download the full playlist instead of just one video.    |

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
