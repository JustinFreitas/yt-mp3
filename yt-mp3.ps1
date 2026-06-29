#requires -Version 5.1
<#
.SYNOPSIS
    Download the audio of one or more YouTube links as MP3 files.

.DESCRIPTION
    Wraps yt-dlp + ffmpeg to save audio with embedded cover art and metadata.
    It is source-aware:
      * Lossless source (FLAC, ALAC, WAV, ...): compressed down to MP3 V0
        (~245 kbps); the lossless original is not kept. Pass -Flac to keep the
        lossless source as-is instead (add -Mp3 to also produce an MP3).
      * Lossy source (Opus, AAC, MP3, ... — all YouTube audio): the original
        track is saved as-is. Pass -Mp3 to also create an MP3, capped at the
        source bitrate so it never exceeds it (V0 ceiling for high bitrates).
    Inputs may be URLs or local audio file paths. A local source file is never
    deleted, overwritten, or retagged: the script only ever modifies files it
    produces, and refuses any operation that would land on top of the source.
    Each produced file is ReplayGain-scanned (track gain) by default; pass
    -NoReplayGain to skip.
    If yt-dlp or ffmpeg are missing, the script attempts to install them with
    winget, and prints manual install instructions if that fails. rsgain (for
    ReplayGain) is auto-downloaded from GitHub on first use.

.PARAMETER Url
    One or more YouTube video (or audio) URLs, or local audio file paths.

.PARAMETER OutDir
    Folder to save the MP3 into. Defaults to the current directory.

.PARAMETER Mp3
    For lossy sources, also create an MP3 (capped at the source bitrate). Without
    this switch a lossy source is just saved as-is. With -Flac, also produce an
    MP3 alongside the kept lossless original.

.PARAMETER Flac
    Keep a lossless source as-is instead of converting it to MP3. By default a
    lossless source is compressed to MP3 V0; with -Flac the original is saved
    unchanged (combine with -Mp3 to keep the lossless original AND make an MP3).

.PARAMETER NoReplayGain
    Skip ReplayGain scanning. By default each produced file is tagged with
    ReplayGain 2.0 track gain via rsgain (auto-downloaded on first use). The
    user's own local source files are never modified.

.PARAMETER Playlist
    If the URL points at a playlist, download the whole playlist instead of
    just the single video. Off by default.

.EXAMPLE
    # Lossy (YouTube): saves the original audio as-is
    .\yt-mp3.ps1 "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

.EXAMPLE
    # Lossy + an MP3 alongside the original
    .\yt-mp3.ps1 "https://youtu.be/abc" -Mp3

.EXAMPLE
    .\yt-mp3.ps1 "https://youtu.be/abc" "https://youtu.be/def" -OutDir D:\Music
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Url,

    [string]$OutDir = (Get-Location).Path,

    [switch]$Mp3,

    [switch]$Flac,

    [switch]$NoReplayGain,

    [switch]$Playlist
)

$ErrorActionPreference = 'Stop'

# Decode native-command output (e.g. yt-dlp's --print filename) as UTF-8 so
# non-ASCII characters in titles/paths survive capture. Paired with yt-dlp's
# --encoding utf-8 below.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

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

function Ensure-Rsgain {
    # rsgain (ReplayGain 2.0 scanner) isn't in winget, so fetch the win64 zip from
    # GitHub releases into a local tools cache and add it to PATH for this session.
    if (Test-Tool 'rsgain') { return $true }

    $toolsDir = Join-Path $env:LOCALAPPDATA 'yt-mp3\tools\rsgain'
    $exe = Get-ChildItem -Path $toolsDir -Filter 'rsgain.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $exe) {
        $url = 'https://github.com/complexlogic/rsgain/releases/download/v3.7/rsgain-3.7-win64.zip'
        $zip = Join-Path $env:TEMP 'rsgain-win64.zip'
        Write-Host "Downloading rsgain (ReplayGain scanner)..." -ForegroundColor Cyan
        try {
            New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            Expand-Archive -Path $zip -DestinationPath $toolsDir -Force
            Remove-Item $zip -ErrorAction SilentlyContinue
            $exe = Get-ChildItem -Path $toolsDir -Filter 'rsgain.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        catch {
            Write-Warning "Could not download rsgain: $($_.Exception.Message)"
            return $false
        }
    }

    if ($exe) {
        $env:Path = "$($exe.Directory.FullName);$env:Path"
        return (Test-Tool 'rsgain')
    }
    return $false
}

# Audio containers rsgain can tag (skip anything else, e.g. raw .webm).
$RgExts = @('.mp3', '.flac', '.ogg', '.oga', '.opus', '.spx',
            '.m4a', '.mp4', '.wma', '.wav', '.aiff', '.aif', '.wv', '.ape')

function Invoke-ReplayGain {
    # Write per-file (track) ReplayGain 2.0 tags with clipping protection, and
    # report the computed gain/peak so it's visible the scan actually ran.
    param([string[]]$Files)
    foreach ($f in $Files) {
        $name = [System.IO.Path]::GetFileName($f)
        if (-not (Test-Path -LiteralPath $f)) {
            Write-Warning "  ReplayGain: expected output not found, skipping -> $name"
            continue
        }
        if ($RgExts -notcontains ([System.IO.Path]::GetExtension($f).ToLower())) {
            Write-Host "  ReplayGain: skipped (rsgain can't tag this format) -> $name" -ForegroundColor Yellow
            continue
        }

        $out = rsgain custom -s i -c p -p -- $f 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  ReplayGain: rsgain failed for $name"
            $out | ForEach-Object { Write-Host "    $_" }
            continue
        }

        $gm = $out | Select-String -Pattern 'Gain:\s*(-?[\d.]+\s*dB)' | Select-Object -First 1
        $pm = $out | Select-String -Pattern 'Peak:\s*([\d.]+)'        | Select-Object -First 1
        $gain = if ($gm) { $gm.Matches[0].Groups[1].Value } else { '' }
        $peak = if ($pm) { $pm.Matches[0].Groups[1].Value } else { '' }
        if ($gain) {
            $peakNote = if ($peak) { ", peak $peak" } else { '' }
            Write-Host "  ReplayGain: tagged $name -> track gain $gain$peakNote" -ForegroundColor Green
        }
        else {
            Write-Host "  ReplayGain: tagged $name" -ForegroundColor Green
        }
    }
}

# --- Dependency bootstrap ---------------------------------------------------
$ok = $true
$ok = (Install-Tool -Name 'yt-dlp' -WingetId 'yt-dlp.yt-dlp' -Manual 'winget install yt-dlp.yt-dlp') -and $ok
$ok = (Install-Tool -Name 'ffmpeg' -WingetId 'Gyan.FFmpeg'  -Manual 'winget install Gyan.FFmpeg')  -and $ok

if (-not $ok) {
    Write-Error 'Required dependencies are missing. See the messages above.'
    exit 1
}

# ReplayGain scanning is on by default; -NoReplayGain disables it.
$rgReady = $false
if (-not $NoReplayGain) {
    $rgReady = Ensure-Rsgain
    if (-not $rgReady) {
        Write-Warning 'ReplayGain scanning unavailable (rsgain missing); continuing without it.'
    }
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
    # Also reports the path yt-dlp would download to (so we can guard local files).
    param([string]$TargetUrl, [string[]]$ExtraArgs = @())
    $probeArgs = @('-f', 'bestaudio/best', '--no-warnings', '--encoding', 'utf-8',
                   '--print', '%(acodec)s|%(abr)s', '--print', 'filename',
                   '-o', $OutTemplate) + $ExtraArgs
    if (-not $Playlist) { $probeArgs += '--no-playlist' }
    $lines = @(yt-dlp @probeArgs -- $TargetUrl 2>$null)
    if ($lines.Count -lt 1 -or [string]::IsNullOrWhiteSpace($lines[0])) { return $null }
    $parts = $lines[0].Split('|')
    [pscustomobject]@{
        Acodec = $parts[0].Trim()
        Abr    = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
        DlPath = if ($lines.Count -gt 1) { $lines[1].Trim() } else { '' }
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
$OutTemplate = (Join-Path $OutDir '%(title)s.%(ext)s')
# Note: --embed-thumbnail is added per-branch only when producing an MP3; raw
# audio containers like webm don't support thumbnail embedding.
$commonArgs = @(
    '-f', 'bestaudio/best'
    '--encoding', 'utf-8'
    '--embed-metadata'
    '-o', $OutTemplate
)
if (-not $Playlist) { $commonArgs += '--no-playlist' }

$failed  = 0
$skipped = 0
foreach ($u in $Url) {
    Write-Host "`nProcessing: $u" -ForegroundColor Cyan

    # Local files: yt-dlp needs a file:// URI and --enable-file-urls to read them.
    $isLocal = Test-Path -LiteralPath $u -PathType Leaf
    $target  = $u
    $extra   = @()
    $srcFull = ''
    if ($isLocal) {
        $srcFull = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $u).Path)
        $target  = ([System.Uri]$srcFull).AbsoluteUri
        $extra   = @('--enable-file-urls')
    }

    $info       = Get-AudioInfo -TargetUrl $target -ExtraArgs $extra
    $srcAbr     = if ($info) { Get-Bitrate $info.Abr } else { 0 }
    $codecLabel = if ($info -and $info.Acodec) { $info.Acodec } else { 'unknown' }
    $isLossless = $info -and ($info.Acodec -match $LosslessPattern)

    # Decide the two outputs for this source:
    #   keepOriginal - save the source audio as-is
    #   makeMp3      - also produce an MP3
    if ($isLossless) {
        # Lossless: convert to MP3 by default; -Flac keeps the original instead.
        $keepOriginal = [bool]$Flac
        $makeMp3      = (-not $Flac) -or $Mp3
    }
    else {
        # Lossy: always keep the original; -Mp3 additionally produces an MP3.
        $keepOriginal = $true
        $makeMp3      = [bool]$Mp3
    }

    # No MP3 to make and a local source: the original is already on disk -> no-op.
    if (-not $makeMp3 -and $isLocal) {
        Write-Host "  Source is $codecLabel and already on disk -> nothing to do." -ForegroundColor DarkGray
        $skipped++
        continue
    }

    # When producing an MP3, never delete or overwrite a local source file.
    $forceKeep = $false
    if ($makeMp3 -and $isLocal -and $info -and $info.DlPath) {
        $dlFull  = [System.IO.Path]::GetFullPath($info.DlPath)
        $mp3Full = [System.IO.Path]::ChangeExtension($dlFull, 'mp3')
        if ($mp3Full -ieq $srcFull) {
            # The output MP3 would land on top of the source (e.g. an .mp3 source
            # in the output folder). Refuse rather than overwrite the original.
            Write-Warning "Output MP3 would overwrite the source file: $u"
            Write-Host    "  Skipped (source preserved). Use -OutDir to write the MP3 outside the source folder." -ForegroundColor Yellow
            $skipped++
            continue
        }
        if ($dlFull -ieq $srcFull) {
            # yt-dlp would work in place on the source; force -k so extraction
            # keeps it instead of deleting it.
            $forceKeep = $true
        }
    }

    # Path yt-dlp will write to; used to locate the produced file(s) for ReplayGain.
    $outBase       = if ($info -and $info.DlPath) { [System.IO.Path]::GetFullPath($info.DlPath) } else { '' }
    $producedFiles = @()

    if (-not $makeMp3) {
        # Save the original audio stream as-is (no transcode).
        $runArgs = @()
        if ($codecLabel -match '^opus') {
            # Opus is delivered in a .webm container that rsgain can't tag; losslessly
            # remux it to .opus (repackage only, no re-encode) so ReplayGain applies.
            $runArgs += @('--remux-video', 'opus')
            Write-Host "  Source is $codecLabel -> saving original audio (remuxed to .opus, no re-encode)." -ForegroundColor DarkGray
            if ($outBase) { $producedFiles = @([System.IO.Path]::ChangeExtension($outBase, 'opus')) }
        }
        else {
            Write-Host "  Source is $codecLabel -> saving original audio as-is." -ForegroundColor DarkGray
            if ($outBase) { $producedFiles = @($outBase) }
        }
    }
    elseif ($isLossless) {
        # Lossless -> compress down to high-quality MP3 (V0, ~245 kbps).
        $keepNote = if ($keepOriginal -and -not $isLocal) { 'keeping lossless + ' } else { '' }
        Write-Host "  Source is lossless ($codecLabel) -> ${keepNote}MP3 V0." -ForegroundColor DarkGray
        $runArgs = @('-x', '--audio-format', 'mp3', '--audio-quality', $VbrV0, '--embed-thumbnail')
        if ($keepOriginal -and -not $isLocal) { $runArgs += '-k' }
        if ($outBase) {
            $producedFiles = @([System.IO.Path]::ChangeExtension($outBase, 'mp3'))
            if ($keepOriginal -and -not $isLocal) { $producedFiles += $outBase }
        }
    }
    else {
        # Lossy + -Mp3 -> MP3 capped at the source bitrate so it never exceeds it
        # (V0 ceiling for high bitrates).
        $quality = $VbrV0
        $note    = 'V0 (~245 kbps ceiling)'
        if ($srcAbr -gt 0 -and $srcAbr -lt 245) {
            $quality = "${srcAbr}K"
            $note    = "$srcAbr kbps (matched to source)"
        }
        # Keep the original alongside the MP3 only for remote sources; a local
        # original already exists on disk, so there's nothing to keep a copy of.
        $keepNote = if ($keepOriginal -and -not $isLocal) { 'keeping original + ' } else { '' }
        Write-Host "  Source is lossy ($codecLabel $srcAbr kbps) -> ${keepNote}MP3 at $note." -ForegroundColor DarkGray
        $runArgs = @('-x', '--audio-format', 'mp3', '--audio-quality', $quality, '--embed-thumbnail')
        if ($keepOriginal -and -not $isLocal) { $runArgs += '-k' }
        if ($outBase) {
            $producedFiles = @([System.IO.Path]::ChangeExtension($outBase, 'mp3'))
            if ($keepOriginal -and -not $isLocal) { $producedFiles += $outBase }
        }
    }

    if ($forceKeep -and ($runArgs -notcontains '-k')) { $runArgs += '-k' }
    $runArgs += $commonArgs

    yt-dlp @runArgs @extra -- $target
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "yt-dlp exited with code $LASTEXITCODE for: $u"
        $failed++
        continue
    }

    # ReplayGain-scan the files we just produced (never the user's local source).
    if ($rgReady -and $producedFiles.Count -gt 0) {
        Invoke-ReplayGain -Files $producedFiles
    }
}

if ($skipped -gt 0) {
    Write-Host "$skipped item(s) skipped." -ForegroundColor Yellow
}

if ($failed -gt 0) {
    Write-Error "$failed of $($Url.Count) download(s) failed."
    exit 1
}

Write-Host "`nDone. Output saved to: $OutDir" -ForegroundColor Green
