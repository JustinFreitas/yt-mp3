#requires -Version 5.1
<#
.SYNOPSIS
    Download the audio of one or more YouTube links as MP3 files.

.DESCRIPTION
    Wraps yt-dlp + ffmpeg to extract best-quality VBR MP3 (~V0) audio with
    embedded cover art and metadata. If yt-dlp or ffmpeg are missing, the
    script attempts to install them with winget, and prints manual install
    instructions if that fails.

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

# --- Download / convert -----------------------------------------------------
$ytArgs = @(
    '-x'
    '--audio-format', 'mp3'
    '--audio-quality', '0'
    '--embed-thumbnail'
    '--embed-metadata'
    '-o', (Join-Path $OutDir '%(title)s.%(ext)s')
)
if (-not $Playlist) { $ytArgs += '--no-playlist' }

$failed = 0
foreach ($u in $Url) {
    Write-Host "`nDownloading: $u" -ForegroundColor Cyan
    yt-dlp @ytArgs -- $u
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
