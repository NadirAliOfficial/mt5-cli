<#
.SYNOPSIS
    mt5d — download tick and bar history for a symbol from the Windows terminal.
.DESCRIPTION
    Compiles and runs an MQL5 script inside the terminal that pulls the range
    with CopyTicksRange and CopyRates, polling until the download settles,
    then reports what actually arrived.
.EXAMPLE
    .\mt5d.ps1 --symbol XAUUSD --from 2026.01.01 --to 2026.08.01 --timeframe M1
#>

$ErrorActionPreference = 'Stop'

# ─── parse arguments ────────────────────────────────────────────────────
$symbol = ''; $from = ''; $to = ''; $tf = 'M1'; $bars = 1; $timeout = 600
$login = $env:MT5_LOGIN; $password = $env:MT5_PASSWORD; $server = $env:MT5_SERVER

$i = 0
while ($i -lt $args.Count) {
    $a = $args[$i]
    switch ($a) {
        '--symbol'    { $symbol   = $args[++$i] }
        '--from'      { $from     = $args[++$i] }
        '--to'        { $to       = $args[++$i] }
        '--timeframe' { $tf       = $args[++$i] }
        '--timeout'   { $timeout  = $args[++$i] }
        '--login'     { $login    = $args[++$i] }
        '--password'  { $password = $args[++$i] }
        '--server'    { $server   = $args[++$i] }
        '--no-bars'   { $bars = 0 }
        default {
            Write-Host "unknown option: $a"
            exit 2
        }
    }
    $i++
}

if (-not $symbol -or -not $from -or -not $to) {
    Write-Host "usage: mt5d --symbol SYM --from YYYY.MM.DD --to YYYY.MM.DD [--timeframe M1] [--no-bars]"
    exit 2
}

# ─── find MetaTrader 5 ─────────────────────────────────────────────────
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

function Find-DataDir {
    param([string]$InstallDir)
    $termBase = "$env:APPDATA\MetaQuotes\Terminal"
    if (-not (Test-Path $termBase)) { return $null }
    foreach ($d in (Get-ChildItem $termBase -Directory -ErrorAction SilentlyContinue)) {
        $origin = Join-Path $d.FullName "origin.txt"
        if (Test-Path $origin) {
            $originPath = (Get-Content $origin -Raw).Trim()
            if ($originPath -eq $InstallDir) { return $d.FullName }
        }
    }
    return $null
}

$MT5_INSTALL = Find-MT5
if (-not $MT5_INSTALL) { Write-Host "MetaTrader 5 installation not found"; exit 2 }
$MT5_DATA = Find-DataDir $MT5_INSTALL
if (-not $MT5_DATA) { Write-Host "MetaTrader 5 data directory not found"; exit 2 }

$METAEDITOR = "$MT5_INSTALL\MetaEditor64.exe"
$TERMINAL   = "$MT5_INSTALL\terminal64.exe"
$FILES      = "$MT5_DATA\MQL5\Files"
$SCRIPTS    = "$MT5_DATA\MQL5\Scripts"
$HERE       = Split-Path -Parent $MyInvocation.MyCommand.Path
$REPO       = Split-Path -Parent $HERE

# ─── compile the fetch script ──────────────────────────────────────────
if (-not (Test-Path $FILES))   { New-Item -ItemType Directory -Path $FILES   -Force | Out-Null }
if (-not (Test-Path $SCRIPTS)) { New-Item -ItemType Directory -Path $SCRIPTS -Force | Out-Null }

$fetchSrc = "$REPO\scripts\mt5d_fetch.mq5"
if (-not (Test-Path $fetchSrc)) {
    Write-Host "fetch script not found: $fetchSrc"
    exit 2
}
Copy-Item $fetchSrc "$SCRIPTS\mt5d_fetch.mq5" -Force

$compileArg = "$SCRIPTS\mt5d_fetch.mq5"
$proc = Start-Process -FilePath $METAEDITOR `
    -ArgumentList "/compile:`"$compileArg`"","/log" `
    -PassThru -Wait -NoNewWindow -ErrorAction SilentlyContinue

# wait for compiled output
for ($w = 0; $w -lt 30; $w++) {
    if (Test-Path "$SCRIPTS\mt5d_fetch.ex5") { break }
    Start-Sleep -Seconds 1
}

if (-not (Test-Path "$SCRIPTS\mt5d_fetch.ex5")) {
    Write-Host "could not compile the fetch script:"
    $fetchLog = "$SCRIPTS\mt5d_fetch.log"
    if (Test-Path $fetchLog) {
        try {
            $logText = [System.IO.File]::ReadAllText($fetchLog, [System.Text.Encoding]::Unicode)
        } catch {
            $logText = Get-Content $fetchLog -Raw
        }
        $logText -split "`r?`n" | Where-Object { $_ -match '(?i)error' } | ForEach-Object { Write-Host $_ }
    }
    exit 1
}

# ─── hand the request to the script ────────────────────────────────────
Remove-Item "$FILES\mt5d_result.txt" -Force -ErrorAction SilentlyContinue

$request = @(
    "symbol=$symbol",
    "from=$from 00:00:00",
    "to=$to 00:00:00",
    "timeframe=$tf",
    "bars=$bars",
    "timeout=$timeout"
)
$request | Out-File -FilePath "$FILES\mt5d.txt" -Encoding ascii -Force

# ─── build startup config ──────────────────────────────────────────────
$configDir = "$MT5_DATA\config"
if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

$ini = @()

if (-not $login) {
    $commonIni = "$MT5_DATA\config\common.ini"
    if (Test-Path $commonIni) {
        $commonContent = Get-Content $commonIni
        foreach ($cline in $commonContent) {
            if ($cline -match '^\s*Login\s*=\s*(.+)') { $login = $Matches[1].Trim() }
            if ($cline -match '^\s*Server\s*=\s*(.+)' -and -not $server) { $server = $Matches[1].Trim() }
        }
    }
}

if ($login) {
    $ini += "[Common]"
    $ini += "Login=$login"
    if ($password) { $ini += "Password=$password" }
    if ($server)   { $ini += "Server=$server" }
    $ini += ""
}
$ini += "[StartUp]"
$ini += "Script=mt5d_fetch"
$ini += "Symbol=$symbol"
$ini += "Period=$tf"

$iniPath = "$configDir\mt5d.ini"
$ini | Out-File -FilePath $iniPath -Encoding ascii -Force

Write-Host "downloading $symbol  $from .. $to  ($tf)"

# ─── run the terminal ──────────────────────────────────────────────────
$proc = Start-Process -FilePath $TERMINAL `
    -ArgumentList "/config:`"$iniPath`"" `
    -PassThru -NoNewWindow -ErrorAction SilentlyContinue

if ($proc) {
    # wait up to timeout + 60s for the terminal to finish
    $waitMs = ([int]$timeout + 60) * 1000
    $null = $proc.WaitForExit($waitMs)
    if (-not $proc.HasExited) {
        Write-Host "terminal timed out"
        $proc.Kill()
    }
}

# ─── report what the terminal actually got ──────────────────────────────
$res = "$FILES\mt5d_result.txt"
if (-not (Test-Path $res)) {
    Write-Host "no result written. the terminal may not have connected to a server."
    exit 1
}

$resContent = Get-Content $res
$status = ($resContent | Select-Object -First 1).Trim()
$resContent | Select-Object -Skip 1 | ForEach-Object { Write-Host "  $($_.Trim())" }

if ($status -ne "STATUS=OK") {
    Write-Host ""
    Write-Host "download incomplete"
    exit 1
}
Write-Host ""
Write-Host "done -- rerun mt5t with --model 4 for a real tick test"
