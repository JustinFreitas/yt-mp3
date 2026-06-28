# yt-mp3

A small PowerShell script that saves the audio of a YouTube link as an MP3.

It wraps [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) and
[`ffmpeg`](https://ffmpeg.org/), extracting best-quality VBR MP3 audio (~V0,
≈245 kbps) with embedded cover art and metadata.

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
