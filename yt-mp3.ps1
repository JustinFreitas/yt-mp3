#requires -Version 5.1
<#
.SYNOPSIS
    Download the audio of one or more YouTube links as MP3 files.

.DESCRIPTION
    Wraps yt-dlp + ffmpeg to save audio with embedded cover art and metadata.
    It is source-aware:
      * Lossless source (FLAC, ALAC, WAV, ...): compressed down to MP3 V0
        (~245 kbps); the lossless original is not kept.
      * Lossy source (Opus, AAC, MP3, ... — all YouTube audio): the original
        track is kept as-is AND an MP3 is produced, capped at the source bitrate
        so it never exceeds it (V0 ceiling for high-bitrate sources).
    If yt-dlp or ffmpeg are missing, the script attempts to install them with
    winget, and prints manual install instructions if that fails.

.PARAMETER Url
    One or more YouTube video (or audio) URLs.

.PARAMETER OutDir
    Folder to save the MP3 into. Defaults to the current directory.

.PARAMETER Playlist
    If the URL points at a playlist, download the whole playlist instead of
    just the single video. Off by default.

.EXAMPLE
    .\yt-mp3.ps1 "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

.EXAMPLE
    .\yt-mp3.ps1 "https://youtu.be/abc" "https://youtu.be/def" -OutDir D:\Music
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Url,

    [string]$OutDir = (Get-Location).Path,

    [switch]$Playlist
)

$ErrorActionPreference = 'Stop'

function Refresh-Path {
    # Re-read PATH from machine + user scopes so freshly winget-installed exes resolve.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Test-Tool {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-Tool {
    param(
        [string]$Name,        # command to look for on PATH
        [string]$WingetId,    # winget package id
        [string]$Manual       # manual install command to suggest on failure
    )

    if (Test-Tool $Name) { return $true }

    if (-not (Test-Tool 'winget')) {
        Write-Warning "'$Name' is not installed and winget is unavailable."
        Write-Host    "Install it manually with:  $Manual" -ForegroundColor Yellow
        return $false
    }

    Write-Host "Installing '$Name' via winget ($WingetId)..." -ForegroundColor Cyan
    winget install --id $WingetId -e --source winget `
        --accept-package-agreements --accept-source-agreements

    Refresh-Path

    if (Test-Tool $Name) {
        Write-Host "Installed '$Name'." -ForegroundColor Green
        return $true
    }

    Write-Warning "Automated install of '$Name' did not complete."
    Write-Host    "Install it manually, then re-run:  $Manual" -ForegroundColor Yellow
    return $false
}

# --- Dependency bootstrap ---------------------------------------------------
$ok = $true
$ok = (Install-Tool -Name 'yt-dlp' -WingetId 'yt-dlp.yt-dlp' -Manual 'winget install yt-dlp.yt-dlp') -and $ok
$ok = (Install-Tool -Name 'ffmpeg' -WingetId 'Gyan.FFmpeg'  -Manual 'winget install Gyan.FFmpeg')  -and $ok

if (-not $ok) {
    Write-Error 'Required dependencies are missing. See the messages above.'
    exit 1
}

# --- Prepare output dir -----------------------------------------------------
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

# --- Source-aware quality helpers ------------------------------------------

# V0 VBR (~245 kbps) is the target when compressing a lossless source.
$VbrV0 = '0'

# Lossless audio codecs as reported by yt-dlp's %(acodec)s. A lossless source is
# compressed down to MP3 V0; a lossy source is kept as-is plus a capped MP3.
$LosslessPattern = '^(flac|alac|pcm|wav|aiff|ape|tta|wavpack|wv|tak|mlp|truehd|dsd)'

function Get-AudioInfo {
    # Probe the best audio stream without downloading (--print implies simulate).
    param([string]$TargetUrl)
    $probeArgs = @('-f', 'bestaudio/best', '--no-warnings', '--print', '%(acodec)s|%(abr)s')
    if (-not $Playlist) { $probeArgs += '--no-playlist' }
    $line = yt-dlp @probeArgs -- $TargetUrl 2>$null | Select-Object -First 1
    if (-not $line) { return $null }
    $parts = $line.Split('|')
    [pscustomobject]@{
        Acodec = $parts[0].Trim()
        Abr    = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
    }
}

function Get-Bitrate {
    # Parse a bitrate string to a rounded integer kbps; 0 if unknown.
    param([string]$Value)
    $n = 0.0
    if ([double]::TryParse($Value, [ref]$n) -and $n -gt 0) { return [int][math]::Round($n) }
    return 0
}

# --- Download / convert -----------------------------------------------------
# Pin audio-only selection so we never pull the (huge) video stream — important
# when keeping the original file via -k for lossy sources.
$commonArgs = @(
    '-f', 'bestaudio/best'
    '--embed-thumbnail'
    '--embed-metadata'
    '-o', (Join-Path $OutDir '%(title)s.%(ext)s')
)
if (-not $Playlist) { $commonArgs += '--no-playlist' }

$failed = 0
foreach ($u in $Url) {
    Write-Host "`nProcessing: $u" -ForegroundColor Cyan

    $info       = Get-AudioInfo -TargetUrl $u
    $srcAbr     = if ($info) { Get-Bitrate $info.Abr } else { 0 }
    $codecLabel = if ($info -and $info.Acodec) { $info.Acodec } else { 'unknown' }
    $isLossless = $info -and ($info.Acodec -match $LosslessPattern)

    if ($isLossless) {
        # Lossless source -> compress down to high-quality MP3 (V0, ~245 kbps).
        # The lossless original is not kept.
        Write-Host "  Source is lossless ($codecLabel) -> compressing to MP3 V0." -ForegroundColor DarkGray
        $runArgs = @('-x', '--audio-format', 'mp3', '--audio-quality', $VbrV0) + $commonArgs
    }
    else {
        # Lossy source -> keep the original track (-k) AND make an MP3 capped at
        # the source bitrate so it never exceeds it (V0 ceiling for high bitrates).
        $quality = $VbrV0
        $note    = 'V0 (~245 kbps ceiling)'
        if ($srcAbr -gt 0 -and $srcAbr -lt 245) {
            $quality = "${srcAbr}K"
            $note    = "$srcAbr kbps (matched to source)"
        }
        Write-Host "  Source is lossy ($codecLabel $srcAbr kbps) -> keeping original + MP3 at $note." -ForegroundColor DarkGray
        $runArgs = @('-x', '--audio-format', 'mp3', '--audio-quality', $quality, '-k') + $commonArgs
    }

    yt-dlp @runArgs -- $u
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "yt-dlp exited with code $LASTEXITCODE for: $u"
        $failed++
    }
}

if ($failed -gt 0) {
    Write-Error "$failed of $($Url.Count) download(s) failed."
    exit 1
}

Write-Host "`nDone. MP3(s) saved to: $OutDir" -ForegroundColor Green
