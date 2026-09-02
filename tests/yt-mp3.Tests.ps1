#requires -Version 5.1

$ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\yt-mp3.ps1')).Path

Describe 'yt-mp3 Script Tests' {

    Context 'Syntax & Parameter Validation' {
        It 'Script parses without syntax errors' {
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $ScriptPath,
                [ref]$null,
                [ref]$errors
            )
            $errors.Count | Should Be 0
        }

        It 'Script exposes expected core and modern parameters' {
            $command = Get-Command $ScriptPath
            $params = @($command.Parameters.Keys)
            ($params -contains 'Url') | Should Be $true
            ($params -contains 'OutDir') | Should Be $true
            ($params -contains 'Mp3') | Should Be $true
            ($params -contains 'Flac') | Should Be $true
            ($params -contains 'CleanAudio') | Should Be $true
            ($params -contains 'CleanMetadata') | Should Be $true
            ($params -contains 'SplitChapters') | Should Be $true
            ($params -contains 'AlbumGain') | Should Be $true
            ($params -contains 'NoReplayGain') | Should Be $true
            ($params -contains 'NoThumbnail') | Should Be $true
            ($params -contains 'Quality') | Should Be $true
            ($params -contains 'Template') | Should Be $true
            ($params -contains 'NoOverwrites') | Should Be $true
            ($params -contains 'Playlist') | Should Be $true
            ($params -contains 'CookiesBrowser') | Should Be $true
            ($params -contains 'Lyrics') | Should Be $true
            ($params -contains 'Retries') | Should Be $true
        }

        It 'Supports -NoSponsor alias for -CleanAudio' {
            $command = Get-Command $ScriptPath
            $cleanAudioParam = $command.Parameters['CleanAudio']
            ($cleanAudioParam.Aliases -contains 'NoSponsor') | Should Be $true
        }

        It 'Supports -Path and -Uri aliases for -Url' {
            $command = Get-Command $ScriptPath
            $urlParam = $command.Parameters['Url']
            ($urlParam.Aliases -contains 'Path') | Should Be $true
            ($urlParam.Aliases -contains 'Uri') | Should Be $true
        }

        It 'Validates -Quality parameter against ValidateSet' {
            $command = Get-Command $ScriptPath
            $qualParam = $command.Parameters['Quality']
            $validateSetAttr = $qualParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $validateSetAttr | Should Not BeNullOrEmpty
            ($validateSetAttr.ValidValues -contains 'V0') | Should Be $true
            ($validateSetAttr.ValidValues -contains '320k') | Should Be $true
            ($validateSetAttr.ValidValues -contains 'match') | Should Be $true
        }

        It 'Validates -CookiesBrowser parameter against ValidateSet' {
            $command = Get-Command $ScriptPath
            $cookiesParam = $command.Parameters['CookiesBrowser']
            $validateSetAttr = $cookiesParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $validateSetAttr | Should Not BeNullOrEmpty
            ($validateSetAttr.ValidValues -contains 'chrome') | Should Be $true
            ($validateSetAttr.ValidValues -contains 'firefox') | Should Be $true
        }
    }

    Context 'Local Audio File Probing & Output Safety' {
        It 'Correctly identifies local lossless WAV and converts to MP3' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "yt_test_wav_$(Get-Random)"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            try {
                $testWav = Join-Path $testDir 'sine.wav'
                ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -y $testWav -loglevel error

                $outDir = Join-Path $testDir 'wav_out'
                & $ScriptPath $testWav -OutDir $outDir -NoReplayGain
                $expectedMp3 = Join-Path $outDir 'sine.mp3'
                (Test-Path -LiteralPath $expectedMp3) | Should Be $true
            }
            finally {
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Tags converted local audio in custom OutDir with ReplayGain' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "yt_test_rg_$(Get-Random)"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            try {
                $testWav = Join-Path $testDir 'sine.wav'
                ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -y $testWav -loglevel error

                $outDir = Join-Path $testDir 'rg_out'
                & $ScriptPath $testWav -OutDir $outDir
                $expectedMp3 = Join-Path $outDir 'sine.mp3'
                (Test-Path -LiteralPath $expectedMp3) | Should Be $true
            }
            finally {
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Supports pipeline input for URLs and file paths' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "yt_test_pipe_$(Get-Random)"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            try {
                $testWav1 = Join-Path $testDir 'pipe1.wav'
                $testWav2 = Join-Path $testDir 'pipe2.wav'
                ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -y $testWav1 -loglevel error
                ffmpeg -f lavfi -i "sine=frequency=880:duration=1" -y $testWav2 -loglevel error

                $outDir = Join-Path $testDir 'pipe_out'
                @($testWav1, $testWav2) | & $ScriptPath -OutDir $outDir -NoReplayGain

                (Test-Path -LiteralPath (Join-Path $outDir 'pipe1.mp3')) | Should Be $true
                (Test-Path -LiteralPath (Join-Path $outDir 'pipe2.mp3')) | Should Be $true
            }
            finally {
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Preserves local lossless FLAC when -Flac is passed' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "yt_test_flac_$(Get-Random)"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            try {
                $testFlac = Join-Path $testDir 'sine.flac'
                ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -y $testFlac -loglevel error

                $outDir = Join-Path $testDir 'flac_out'
                & $ScriptPath $testFlac -Flac -OutDir $outDir -NoReplayGain
                (Test-Path -LiteralPath $testFlac) | Should Be $true
            }
            finally {
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Safely handles output directories containing square brackets' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "yt_test_bracket_$(Get-Random)"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            try {
                $testWav = Join-Path $testDir 'sine.wav'
                ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -y $testWav -loglevel error

                $bracketDir = Join-Path $testDir '[Opus Audio]'
                & $ScriptPath $testWav -OutDir $bracketDir -NoReplayGain
                $expectedMp3 = Join-Path $bracketDir 'sine.mp3'
                (Test-Path -LiteralPath $expectedMp3) | Should Be $true
            }
            finally {
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Converts local lossy Opus to MP3 when -Mp3 is specified with -Quality V0' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "yt_test_opus_$(Get-Random)"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            try {
                $testOpus = Join-Path $testDir 'sine.opus'
                ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -c:a libopus -y $testOpus -loglevel error

                $outDir = Join-Path $testDir 'mp3_out'
                & $ScriptPath $testOpus -Mp3 -OutDir $outDir -NoReplayGain -Quality 'V0'
                $expectedMp3 = Join-Path $outDir 'sine.mp3'
                (Test-Path -LiteralPath $expectedMp3) | Should Be $true
            }
            finally {
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Skips local lossy Opus when -Mp3 is not specified (already on disk)' {
            $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "yt_test_opus_skip_$(Get-Random)"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            try {
                $testOpus = Join-Path $testDir 'sine.opus'
                ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -c:a libopus -y $testOpus -loglevel error

                $outDir = Join-Path $testDir 'opus_out'
                & $ScriptPath $testOpus -OutDir $outDir -NoReplayGain
                $expectedOpus = Join-Path $outDir 'sine.opus'
                # Should not create or duplicate existing local file
                (Test-Path -LiteralPath $expectedOpus) | Should Be $false
            }
            finally {
                Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
