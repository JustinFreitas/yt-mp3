#requires -Version 5.1
<#
.SYNOPSIS
    Download the audio of one or more YouTube links or extract local audio files.

.DESCRIPTION
    Wraps yt-dlp + ffmpeg to save high-fidelity audio with embedded cover art,
    clean metadata, and ReplayGain 2.0 loudness normalization.

    It is source-aware:
      * Lossless source (FLAC, ALAC, WAV, ...): compressed down to MP3 V0
        (~245 kbps) by default; the lossless original is not kept. Pass -Flac
        to keep the lossless source as-is instead (add -Mp3 to also produce an MP3).
      * Lossy source (Opus, AAC, MP3, ... — all YouTube audio): the original
        track is saved as-is without transcoding. Opus streams from YouTube are
        losslessly remuxed from WebM to .opus containers (zero re-encode). Pass
        -Mp3 to additionally create an MP3.

    Inputs may be URLs or local audio file paths, passed as arguments or piped
    from the PowerShell pipeline. A local source file is never deleted, overwritten,
    or retagged: the script only ever modifies files it produces, and refuses any
    operation that would land on top of the source.

    Each produced file is ReplayGain-scanned (track gain by default, or album
    gain for playlists/chapters) via rsgain. Pass -NoReplayGain to skip.

.PARAMETER Url
    One or more YouTube video (or audio) URLs, or local audio file paths.
    Accepts pipeline input (e.g. Get-Clipboard | .\yt-mp3.ps1).

.PARAMETER OutDir
    Folder to save audio into. Defaults to the current directory.

.PARAMETER Mp3
    For lossy sources, also create an MP3. Without this switch a lossy source
    (such as YouTube Opus) is preserved as-is. With -Flac, also produce an
    MP3 alongside the kept lossless original.

.PARAMETER Flac
    Keep a lossless source as-is instead of converting it to MP3. By default a
    lossless source is compressed to MP3 V0; with -Flac the original is saved
    unchanged (combine with -Mp3 to keep the lossless original AND make an MP3).

.PARAMETER CleanAudio
    (Alias: -NoSponsor) Automatically removes non-music skits, intro dialogue,
    and outro promotional cards from music videos via SponsorBlock without re-encoding.

.PARAMETER CleanMetadata
    Automatically cleans YouTube title clutter (e.g. '(Official Video)', '[4K Remaster]',
    '(Lyric Video)', '[HD]', 'Visualizer') and normalizes Artist / Title tags.

.PARAMETER SplitChapters
    Splits full-album or concert YouTube uploads into discrete, numbered, and tagged
    tracks based on YouTube video chapters.

.PARAMETER AlbumGain
    Tag files with ReplayGain 2.0 Album Gain in addition to Track Gain, preserving
    relative intra-album dynamics. Automatically enabled for playlists and chapter splits.

.PARAMETER NoReplayGain
    Skip ReplayGain scanning. By default each produced file is tagged with
    ReplayGain 2.0 track gain via rsgain (auto-downloaded on first use).

.PARAMETER NoThumbnail
    Skip downloading and embedding cover art. By default, high-compatibility JPEG
    cover art is embedded across all supported output formats.

.PARAMETER Quality
    Target audio quality for MP3 conversions ('V0', 'V2', '320k', '256k', '192k',
    '128k', or 'match'). Defaults to V0 for lossless sources or source-matched bitrate.

.PARAMETER Template
    Custom output filename template for yt-dlp (e.g. '%(artist)s - %(title)s.%(ext)s').

.PARAMETER NoOverwrites
    Prevent overwriting existing output files.

.PARAMETER Playlist
    If the URL points at a playlist, download the whole playlist instead of
    just the single video. Off by default.

.PARAMETER CookiesBrowser
    Extract cookies from the specified browser (e.g. 'chrome', 'firefox', 'edge',
    'brave') to authenticate for age-gated, private, or member-only videos.

.PARAMETER Lyrics
    Download and embed synchronized/unsynchronized subtitles/lyrics into the audio file.

.PARAMETER Retries
    Number of network retries for yt-dlp on connection errors (defaults to 10).

.EXAMPLE
    # Lossless Opus extraction directly from YouTube (default, zero transcode)
    .\yt-mp3.ps1 "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

.EXAMPLE
    # Pipe URLs from clipboard or file
    Get-Clipboard | .\yt-mp3.ps1 -CleanAudio -CleanMetadata

.EXAMPLE
    # Download with browser authentication for age-gated content
    .\yt-mp3.ps1 "https://www.youtube.com/watch?v=dQw4w9WgXcQ" -CookiesBrowser chrome

.EXAMPLE
    # Split a full album YouTube upload into discrete tagged Opus tracks
    .\yt-mp3.ps1 "https://youtu.be/album_video" -SplitChapters -AlbumGain

.EXAMPLE
    # Lossy source + an MP3 copy alongside the original Opus
    .\yt-mp3.ps1 "https://youtu.be/abc" -Mp3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, ValueFromRemainingArguments = $true)]
    [Alias('Path', 'Uri')]
    [string[]]$Url,

    [string]$OutDir = $PWD.ProviderPath,

    [switch]$Mp3,

    [switch]$Flac,

    [Alias('NoSponsor')]
    [switch]$CleanAudio,

    [switch]$CleanMetadata,

    [switch]$SplitChapters,

    [switch]$AlbumGain,

    [switch]$NoReplayGain,

    [switch]$NoThumbnail,

    [ValidateSet('V0', 'V2', '320k', '256k', '192k', '128k', 'match', '0', '2', '320K', '256K', '192K', '128K', IgnoreCase = $true)]
    [string]$Quality,

    [string]$Template,

    [switch]$NoOverwrites,

    [switch]$Playlist,

    [ValidateSet('chrome', 'firefox', 'edge', 'brave', 'opera', 'vivaldi', 'safari', 'chromium', IgnoreCase = $true)]
    [string]$CookiesBrowser,

    [switch]$Lyrics,

    [int]$Retries = 10
)

begin {
    $ErrorActionPreference = 'Stop'

    # Decode native-command output as UTF-8 and set pipeline output encoding
    try {
        $OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    } catch { }

    function Exit-Script {
        param([string]$Message = '', [int]$Code = 1)
        if ($Message) { Write-Error $Message -ErrorAction Continue }
        if ($MyInvocation.InvocationName -eq '.' -or [Environment]::CommandLine -match 'powershell_ise\.exe') {
            return
        }
        $cmdArgs = [Environment]::GetCommandLineArgs()
        if ($cmdArgs -contains '-File' -or $cmdArgs -contains '-f') {
            exit $Code
        } else {
            throw "yt-mp3 terminated with exit code $Code"
        }
    }

    function Refresh-Path {
        # Re-read PATH from machine + user scopes so freshly winget-installed exes resolve,
        # merging them with current session paths without overwriting existing session-added paths.
        $isWin = [System.Environment]::OSVersion.Platform -match 'Win' -or $env:OS -match 'Windows'
        if (-not $isWin) { return }

        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
        $registryPaths = (@($machine, $user) | Where-Object { $_ }) -join ';' -split ';'
        $currentPaths = $env:Path -split ';'
        
        $newPaths = foreach ($path in $registryPaths) {
            if ($path -and $currentPaths -notcontains $path) { $path }
        }
        if ($newPaths) {
            $env:Path = ($currentPaths + $newPaths) -join ';'
        }
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
            --accept-package-agreements --accept-source-agreements --disable-interactivity

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

        $isWin = [System.Environment]::OSVersion.Platform -match 'Win' -or $env:OS -match 'Windows'
        if (-not $isWin) {
            Write-Warning "rsgain auto-download is Windows-only. Please install rsgain via your package manager (e.g. brew install rsgain / apt install rsgain)."
            return $false
        }

        $localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData\Local' }
        $toolsDir = Join-Path $localAppData 'yt-mp3\tools\rsgain'
        $exe = Get-ChildItem -LiteralPath $toolsDir -Filter 'rsgain.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

        if (-not $exe) {
            $url = 'https://github.com/complexlogic/rsgain/releases/download/v3.7/rsgain-3.7-win64.zip'
            $zip = Join-Path ([System.IO.Path]::GetTempPath()) 'rsgain-win64.zip'
            $expectedHash = '8D6E16D1AF5A805FB2DD6183E11F4F8BC51240F8A896FD37AB8FCA655BB70800'
            Write-Host "Downloading rsgain (ReplayGain scanner)..." -ForegroundColor Cyan
            try {
                if (-not (Test-Path -LiteralPath $toolsDir)) {
                    [System.IO.Directory]::CreateDirectory($toolsDir) | Out-Null
                }
                $prevProgress = $ProgressPreference
                $ProgressPreference = 'SilentlyContinue'
                try {
                    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
                } finally {
                    $ProgressPreference = $prevProgress
                }
                
                $actualHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
                if ($actualHash -ne $expectedHash) {
                    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
                    Write-Warning "rsgain download checksum mismatch!`nExpected: $expectedHash`nActual:   $actualHash"
                    return $false
                }
                
                Expand-Archive -LiteralPath $zip -DestinationPath $toolsDir -Force
                Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue
                $exe = Get-ChildItem -LiteralPath $toolsDir -Filter 'rsgain.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
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

    # Audio containers rsgain can tag.
    $RgExts = @('.mp3', '.flac', '.ogg', '.oga', '.opus', '.spx',
                '.m4a', '.mp4', '.wma', '.wav', '.aiff', '.aif', '.wv', '.ape')

    function Invoke-ReplayGain {
        # Write per-file (track) and/or album ReplayGain 2.0 tags with clipping protection.
        param(
            [string[]]$Files,
            [switch]$AlbumMode
        )

        $validFiles = @()
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
            $validFiles += $f
        }

        if ($validFiles.Count -eq 0) { return }

        if ($AlbumMode -and $validFiles.Count -gt 1) {
            Write-Host "  ReplayGain: scanning $($validFiles.Count) files in Album Gain mode..." -ForegroundColor Cyan
            $out = rsgain custom -s a -c p -p -- $validFiles 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "  ReplayGain: rsgain album scan returned code $LASTEXITCODE"
                $out | ForEach-Object { Write-Host "    $_" }
            } else {
                Write-Host "  ReplayGain: applied Album Gain & Track Gain to $($validFiles.Count) files." -ForegroundColor Green
            }
        } else {
            foreach ($f in $validFiles) {
                $name = [System.IO.Path]::GetFileName($f)
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
    }

    # --- Dependency bootstrap ---------------------------------------------------
    $ok = $true
    $ok = (Install-Tool -Name 'yt-dlp' -WingetId 'yt-dlp.yt-dlp' -Manual 'winget install yt-dlp.yt-dlp') -and $ok
    $ok = (Install-Tool -Name 'ffmpeg' -WingetId 'Gyan.FFmpeg'  -Manual 'winget install Gyan.FFmpeg')  -and $ok

    if (-not $ok) {
        Exit-Script -Message 'Required dependencies are missing. See the messages above.' -Code 1
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
        [System.IO.Directory]::CreateDirectory($OutDir) | Out-Null
    }
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path

    # Lossless audio codecs. A lossless source is compressed down to MP3 V0; a lossy source is kept as-is.
    $LosslessPattern = '^(flac|alac|pcm|wav|aiff|ape|tta|wavpack|wv|tak|mlp|truehd|dsd)'

    function Get-LocalAudioInfo {
        param([string]$FilePath)
        if (Test-Tool 'ffprobe') {
            $codec = (ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 -- $FilePath 2>$null)
            $abr   = (ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 -- $FilePath 2>$null)
            $abrKbps = if ($abr -and [double]::TryParse($abr, [ref]$null)) { [string][int][math]::Round([double]$abr / 1000) } else { '' }
            if ($codec) {
                return [pscustomobject]@{
                    Acodec = $codec.Trim()
                    Abr    = $abrKbps
                    DlPath = $FilePath
                }
            }
        }
        $ext = [System.IO.Path]::GetExtension($FilePath).TrimStart('.').ToLowerInvariant()
        $isLosslessExt = $ext -match '^(flac|wav|aiff|aif|alac|ape|wv|pcm)$'
        return [pscustomobject]@{
            Acodec = if ($isLosslessExt) { 'flac' } else { $ext }
            Abr    = ''
            DlPath = $FilePath
        }
    }

    function Get-AudioInfo {
        param([string]$TargetUrl, [string[]]$ExtraArgs = @(), [bool]$IsLocalFile = $false, [string]$LocalPath = '')
        if ($IsLocalFile -and $LocalPath) {
            return (Get-LocalAudioInfo -FilePath $LocalPath)
        }

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
        param([string]$Value)
        $n = 0.0
        if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and $n -gt 0) {
            return [int][math]::Round($n)
        }
        return 0
    }

    function Resolve-Mp3Quality {
        param(
            [string]$TargetQuality,
            [int]$SourceBitrate
        )
        if ($TargetQuality) {
            switch -Regex ($TargetQuality) {
                '^V?0$'   { return '0' }
                '^V?2$'   { return '2' }
                '^match$' { return if ($SourceBitrate -gt 0) { "${SourceBitrate}K" } else { '0' } }
                '^\d+k?$' { return $TargetQuality.ToUpper() }
                default   { return $TargetQuality }
            }
        }
        if ($SourceBitrate -gt 0 -and $SourceBitrate -lt 245) {
            return "${SourceBitrate}K"
        }
        return '0'
    }

    # --- Download / convert setup -----------------------------------------------
    $DefaultTemplate = if ($SplitChapters) {
        (Join-Path $OutDir '%(title)s - %(section_number)02d %(section_title)s.%(ext)s')
    } else {
        (Join-Path $OutDir '%(title)s.%(ext)s')
    }
    $OutTemplate = if ($Template) { (Join-Path $OutDir $Template) } else { $DefaultTemplate }

    $commonArgs = @(
        '-f', 'bestaudio/best'
        '--encoding', 'utf-8'
        '--embed-metadata'
        '-o', $OutTemplate
    )
    if (-not $Playlist) { $commonArgs += '--no-playlist' }
    if ($NoOverwrites) { $commonArgs += '--no-overwrites' }

    # Retries
    if ($Retries -gt 0) {
        $commonArgs += @('--retries', [string]$Retries, '--fragment-retries', [string]$Retries)
    }

    # Browser cookies for age-gated/authenticated content
    if ($CookiesBrowser) {
        $commonArgs += @('--cookies-from-browser', $CookiesBrowser)
    }

    # Embed high-compatibility JPEG cover art across all outputs by default
    if (-not $NoThumbnail) {
        $commonArgs += @('--embed-thumbnail', '--convert-thumbnails', 'jpg')
    }

    # Embed subtitles / lyrics
    if ($Lyrics) {
        $commonArgs += @('--embed-subs', '--sub-langs', 'all,-live_chat')
    }

    # SponsorBlock non-music skit removal
    if ($CleanAudio) {
        $commonArgs += @('--sponsorblock-remove', 'music_offtopic,sponsor')
    }

    # Clean promotional clutter from metadata title
    if ($CleanMetadata) {
        $junkPattern = '(?i)\s*[\(\[](official\s*(music\s*)?video|official\s*(audio|visualizer|track|lyric\s*video)|lyric\s*video|visualizer|4k\s*remaster(ed)?|remastered|hq\s*audio|audio\s*only|video\s*clip|clip\s*officiel|video\s*oficial|hd|4k(\s*60fps)?)[\)\]]'
        $commonArgs += @(
            '--parse-metadata', '%(title)s:%(title)s',
            '--replace-in-metadata', 'title', $junkPattern, ''
        )
    }

    # Chapter splitting
    if ($SplitChapters) {
        $commonArgs += '--split-chapters'
    }

    $collectedUrls = [System.Collections.Generic.List[string]]::new()
}

process {
    if ($Url) {
        foreach ($u in $Url) {
            if (-not [string]::IsNullOrWhiteSpace($u)) {
                $collectedUrls.Add($u)
            }
        }
    }
}

end {
    if ($collectedUrls.Count -eq 0) {
        Exit-Script -Message 'No URLs or file paths provided.' -Code 1
    }

    # --- Playlist Expansion -----------------------------------------------------
    $targetUrls = $collectedUrls
    if ($Playlist) {
        Write-Host "`nExpanding playlist(s)..." -ForegroundColor Cyan
        $expandedUrls = [System.Collections.Generic.List[string]]::new()
        foreach ($u in $collectedUrls) {
            if (Test-Path -LiteralPath $u -PathType Leaf) {
                $expandedUrls.Add($u)
            } else {
                $flat = @(yt-dlp --flat-playlist --print webpage_url -- $u 2>$null)
                if ($flat.Count -gt 0) {
                    foreach ($item in $flat) { $expandedUrls.Add($item) }
                } else {
                    $expandedUrls.Add($u)
                }
            }
        }
        $targetUrls = $expandedUrls
        $Playlist = $false
        # Automatically engage AlbumGain for playlist downloads unless explicitly skipped
        if (-not $AlbumGain) { $AlbumGain = $true }
    }

    # Automatically engage AlbumGain for chapter splits
    if ($SplitChapters -and -not $AlbumGain) {
        $AlbumGain = $true
    }

    $failed  = 0
    $skipped = 0
    $allProducedBatch = @()

    foreach ($u in $targetUrls) {
        Write-Host "`nProcessing: $u" -ForegroundColor Cyan

        $isLocal = Test-Path -LiteralPath $u -PathType Leaf
        $target  = $u
        $extra   = @()
        $srcFull = ''
        if ($isLocal) {
            $srcFull = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $u).Path)
            $target  = ([System.Uri]$srcFull).AbsoluteUri
            $extra   = @('--enable-file-urls')
        }

        $info       = Get-AudioInfo -TargetUrl $target -ExtraArgs $extra -IsLocalFile $isLocal -LocalPath $srcFull
        $srcAbr     = if ($info) { Get-Bitrate $info.Abr } else { 0 }
        $codecLabel = if ($info -and $info.Acodec) { $info.Acodec } else { 'unknown' }
        $isLossless = $info -and ($info.Acodec -match $LosslessPattern)

        # Decide outputs for this source:
        #   keepOriginal - save the source audio as-is
        #   makeMp3      - produce an MP3
        if ($isLossless) {
            $keepOriginal = [bool]$Flac
            $makeMp3      = (-not $Flac) -or $Mp3
        }
        else {
            # Lossy (e.g. YouTube Opus/AAC): keep original stream as-is unless -Mp3 requested
            $keepOriginal = $true
            $makeMp3      = [bool]$Mp3
        }

        # No MP3 to make and a local source: original is already on disk -> no-op.
        if (-not $makeMp3 -and $isLocal) {
            Write-Host "  Source is $codecLabel and already on disk -> nothing to do." -ForegroundColor DarkGray
            $skipped++
            continue
        }

        # Guard local source against accidental overwrites
        $forceKeep = $false
        if ($makeMp3 -and $isLocal) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($srcFull)
            $mp3LocalPath = Join-Path $OutDir "$baseName.mp3"
            if ($mp3LocalPath -ieq $srcFull) {
                Write-Warning "Output MP3 would overwrite the source file: $u"
                Write-Host    "  Skipped (source preserved). Use -OutDir to write the MP3 outside the source folder." -ForegroundColor Yellow
                $skipped++
                continue
            }
        }

        $outBase = if ($isLocal) {
            Join-Path $OutDir ([System.IO.Path]::GetFileNameWithoutExtension($srcFull))
        } elseif ($info -and $info.DlPath) {
            [System.IO.Path]::GetFullPath($info.DlPath)
        } else {
            ''
        }
        $producedFiles = @()

        if (-not $makeMp3) {
            # Save the original audio stream as-is (zero transcode)
            $runArgs = @()
            if ($codecLabel -match '^opus') {
                # Losslessly remux WebM Opus stream to .opus container
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
            # Lossless source -> compress down to MP3
            $mp3Qual = Resolve-Mp3Quality -TargetQuality $Quality -SourceBitrate $srcAbr
            $keepNote = if ($keepOriginal -and -not $isLocal) { 'keeping lossless + ' } else { '' }
            Write-Host "  Source is lossless ($codecLabel) -> ${keepNote}MP3 ($mp3Qual)." -ForegroundColor DarkGray
            $runArgs = @('-x', '--audio-format', 'mp3', '--audio-quality', $mp3Qual)
            if ($keepOriginal -and -not $isLocal) { $runArgs += '-k' }
            if ($outBase) {
                $producedFiles = @([System.IO.Path]::ChangeExtension($outBase, 'mp3'))
                if ($keepOriginal -and -not $isLocal) { $producedFiles += $outBase }
            }
        }
        else {
            # Lossy source + -Mp3
            $mp3Qual = Resolve-Mp3Quality -TargetQuality $Quality -SourceBitrate $srcAbr
            $keepNote = if ($keepOriginal -and -not $isLocal) { 'keeping original + ' } else { '' }
            Write-Host "  Source is lossy ($codecLabel $srcAbr kbps) -> ${keepNote}MP3 at $mp3Qual." -ForegroundColor DarkGray
            $runArgs = @('-x', '--audio-format', 'mp3', '--audio-quality', $mp3Qual)
            if ($keepOriginal -and -not $isLocal) { $runArgs += '-k' }
            if ($outBase) {
                $producedFiles = @([System.IO.Path]::ChangeExtension($outBase, 'mp3'))
                if ($keepOriginal -and -not $isLocal) { $producedFiles += $outBase }
            }
        }

        if ($forceKeep -and ($runArgs -notcontains '-k')) { $runArgs += '-k' }
        $runArgs += $commonArgs

        # Record start timestamp to track generated chapter files reliably
        $jobStartTime = (Get-Date).AddSeconds(-3)

        yt-dlp @runArgs @extra -- $target
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "yt-dlp exited with code $LASTEXITCODE for: $u"
            $failed++
            continue
        }

        # If keeping original Opus alongside MP3, ensure WebM is remuxed to .opus
        if ($keepOriginal -and -not $isLocal -and $makeMp3 -and $codecLabel -match '^opus' -and $outBase) {
            $webmFile = $outBase
            if (Test-Path -LiteralPath $webmFile) {
                $opusFile = [System.IO.Path]::ChangeExtension($webmFile, 'opus')
                Write-Host "  Remuxing kept original to .opus..." -ForegroundColor DarkGray
                ffmpeg -y -i $webmFile -c copy $opusFile -loglevel error
                if ($LASTEXITCODE -eq 0) {
                    Remove-Item -LiteralPath $webmFile -Force
                    $producedFiles = @($producedFiles | Where-Object { $_ -ne $webmFile })
                    $producedFiles += $opusFile
                } else {
                    Write-Warning "  Failed to remux $webmFile to .opus"
                }
            }
        }

        # If splitting chapters, locate produced chapter files in the output directory
        if ($SplitChapters) {
            $expectedExt = if ($makeMp3) { '*.mp3' } elseif ($codecLabel -match '^opus') { '*.opus' } else { '*.*' }
            $chapterFiles = Get-ChildItem -LiteralPath $OutDir -Filter $expectedExt -File | Where-Object {
                $_.LastWriteTime -ge $jobStartTime
            } | Select-Object -ExpandProperty FullName
            if ($chapterFiles) {
                $producedFiles = $chapterFiles
            }
        }

        $allProducedBatch += $producedFiles

        # Per-item ReplayGain scanning (if not doing batch AlbumGain at the end)
        if ($rgReady -and $producedFiles.Count -gt 0 -and -not $AlbumGain) {
            Invoke-ReplayGain -Files $producedFiles -AlbumMode:$false
        }
    }

    # Perform batch AlbumGain scanning across all produced files if requested
    if ($rgReady -and $allProducedBatch.Count -gt 0 -and $AlbumGain) {
        Invoke-ReplayGain -Files $allProducedBatch -AlbumMode:$true
    }

    if ($skipped -gt 0) {
        Write-Host "$skipped item(s) skipped." -ForegroundColor Yellow
    }

    if ($failed -gt 0) {
        Exit-Script -Message "$failed of $($targetUrls.Count) download(s) failed." -Code 1
    }

    Write-Host "`nDone. Output saved to: $OutDir" -ForegroundColor Green
}
