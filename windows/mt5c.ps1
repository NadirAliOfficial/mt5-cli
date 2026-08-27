<#
.SYNOPSIS
    mt5c — compile an MQL5 source file from the Windows terminal.
.DESCRIPTION
    Copies the source into the terminal's MQL5\Experts folder, compiles via
    MetaEditor64.exe, prints only real errors and warnings (stripping include
    chatter and "generating code" lines), drops the compiled .ex5 next to
    your source, and cleans up.

    Exit code is non-zero on compile failure.
.PARAMETER File
    Path to the .mq5 source file.
.PARAMETER Keep
    Leave the copy inside the MT5 Experts folder after compiling.
.PARAMETER Avx2
    Compile for AVX2+FMA3 architecture. Required when indicator resources
    were compiled for AVX2.
.EXAMPLE
    .\mt5c.ps1 C:\eas\MyEA.mq5
    .\mt5c.ps1 MyEA.mq5 --keep
    .\mt5c.ps1 MyEA.mq5 --avx2
#>

param(
    [Parameter(Position=0)]
    [string]$File,
    [switch]$Keep,
    [switch]$Avx2
)

# also accept --keep / --avx2 as positional args (match mac CLI style)
$extra = $args
foreach ($a in $extra) {
    if ($a -eq '--keep') { $Keep = $true }
    elseif ($a -eq '--avx2') { $Avx2 = $true }
    elseif (-not $File -and $a -notlike '-*') { $File = $a }
}

$ErrorActionPreference = 'Stop'

# ─── usage ──────────────────────────────────────────────────────────────
if (-not $File) {
    Write-Host "usage: mt5c <file.mq5> [--keep] [--avx2]"
    exit 2
}
$File = (Resolve-Path $File -ErrorAction SilentlyContinue).Path
if (-not $File -or -not (Test-Path $File)) {
    Write-Host "not found: $File"
    exit 2
}

# ─── find MetaTrader 5 installation ────────────────────────────────────
function Find-MT5 {
    $candidates = @(
        "$env:ProgramFiles\MetaTrader 5",
        "${env:ProgramFiles(x86)}\MetaTrader 5"
    )
    foreach ($c in $candidates) {
        if (Test-Path "$c\MetaEditor64.exe") { return $c }
    }
    foreach ($drive in @('C','D','E')) {
        $p = "${drive}:\MetaTrader 5"
        if (Test-Path "$p\MetaEditor64.exe") { return $p }
    }
    return $null
}

$MT5_INSTALL = Find-MT5
if (-not $MT5_INSTALL) {
    Write-Host "MetaTrader 5 installation not found (MetaEditor64.exe missing)"
    exit 2
}

# ─── find data directory ────────────────────────────────────────────────
function Find-DataDir {
    param([string]$InstallDir)
    $termBase = "$env:APPDATA\MetaQuotes\Terminal"
    if (-not (Test-Path $termBase)) { return $null }
    foreach ($d in (Get-ChildItem $termBase -Directory -ErrorAction SilentlyContinue)) {
        $origin = Join-Path $d.FullName "origin.txt"
        if (Test-Path $origin) {
            $originPath = (Get-Content $origin -Raw).Trim()
            if ($originPath -eq $InstallDir) {
                return $d.FullName
            }
        }
    }
    return $null
}

$MT5_DATA = Find-DataDir $MT5_INSTALL
if (-not $MT5_DATA) {
    Write-Host "MetaTrader 5 data directory not found in $env:APPDATA\MetaQuotes\Terminal"
    Write-Host "Run MetaTrader 5 once so it creates its data folder."
    exit 2
}

$EXPERTS = "$MT5_DATA\MQL5\Experts"
$METAEDITOR = "$MT5_INSTALL\MetaEditor64.exe"

# ─── copy source into Experts ───────────────────────────────────────────
$name = [System.IO.Path]::GetFileNameWithoutExtension($File)
$work = "$EXPERTS\$name.mq5"

# copy if source is not already inside the Experts folder
$srcDir = [System.IO.Path]::GetDirectoryName($File)
$isSrcInExperts = ($srcDir.TrimEnd('\') -ieq $EXPERTS.TrimEnd('\'))
if (-not $isSrcInExperts) {
    Copy-Item $File $work -Force
}

# ─── compile helper ────────────────────────────────────────────────────
function Invoke-Compile {
    param([bool]$UseAvx2)

    Remove-Item "$EXPERTS\$name.log" -Force -ErrorAction SilentlyContinue

    # MetaEditor on Windows (non-portable) needs the full absolute path
    $compileArgs = @("/compile:`"$work`"", "/log")
    if ($UseAvx2) { $compileArgs += "/avx2" }

    $proc = Start-Process -FilePath $METAEDITOR `
        -ArgumentList $compileArgs `
        -PassThru -Wait -NoNewWindow -ErrorAction SilentlyContinue

    # wait for the log file to appear (MetaEditor may write it asynchronously)
    $logFile = "$EXPERTS\$name.log"
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-Path $logFile) { break }
        Start-Sleep -Seconds 1
    }
    if (-not (Test-Path $logFile)) {
        return $null
    }

    # parse UTF-16LE build log
    try {
        $logContent = [System.IO.File]::ReadAllText($logFile, [System.Text.Encoding]::Unicode)
    } catch {
        try {
            $logContent = [System.IO.File]::ReadAllText($logFile, [System.Text.Encoding]::UTF8)
        } catch {
            $logContent = Get-Content $logFile -Raw
        }
    }

    return $logContent
}

# ─── compile (with auto-retry for AVX2) ────────────────────────────────
$logContent = Invoke-Compile -UseAvx2 $Avx2

if (-not $logContent) {
    Write-Host "no build log produced"
    exit 1
}

$lines = $logContent -split "`r?`n"

# if not already using AVX2 and we see error 414 (requires AVX2), auto-retry
if (-not $Avx2) {
    $needsAvx2 = $lines | Where-Object { $_ -match 'error 414.*requires CPU architecture AVX2' }
    if ($needsAvx2) {
        $logContent = Invoke-Compile -UseAvx2 $true
        if (-not $logContent) {
            Write-Host "no build log produced on AVX2 retry"
            exit 1
        }
        $lines = $logContent -split "`r?`n"
    }
}

# filter out noise — keep only real errors, warnings, and the Result line
$filtered = $lines | Where-Object {
    $_ -and
    $_ -notmatch '(?i)information:\s*(including|generating code|compiling|code generated|resource|info property)' -and
    $_.Trim() -ne ''
}

foreach ($line in $filtered) {
    Write-Host $line
}

# ─── copy .ex5 back ────────────────────────────────────────────────────
$ex5 = "$EXPERTS\$name.ex5"
if (Test-Path $ex5) {
    $destDir = [System.IO.Path]::GetDirectoryName($File)
    $destEx5 = "$destDir\$name.ex5"
    # don't copy to self
    if ($ex5 -ne $destEx5) {
        Copy-Item $ex5 $destEx5 -Force
    }
    Write-Host "built -> $destEx5"
}

# ─── clean up ──────────────────────────────────────────────────────────
if (-not $Keep) {
    if (-not $isSrcInExperts) {
        Remove-Item $work -Force -ErrorAction SilentlyContinue
    }
    Remove-Item "$EXPERTS\$name.log" -Force -ErrorAction SilentlyContinue
    # only remove .ex5 from Experts if source was outside Experts
    if (-not $isSrcInExperts -and (Test-Path $ex5)) {
        Remove-Item $ex5 -Force -ErrorAction SilentlyContinue
    }
}

# ─── exit code ──────────────────────────────────────────────────────────
$resultLine = $filtered | Where-Object { $_ -match 'Result:' } | Select-Object -Last 1
if ($resultLine -and $resultLine -match '0 error') {
    exit 0
} else {
    exit 1
}
