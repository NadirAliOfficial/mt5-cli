<#
.SYNOPSIS
    mt5t — run an MT5 strategy test from the Windows terminal and print
    the numbers straight out of MetaTrader's own report.
.DESCRIPTION
    Compiles the EA (if .mq5), builds a tester config INI, launches
    terminal64.exe, waits for the report, and parses it via mt5t_parse.py.

    Every figure printed comes from the MT5 report file. Nothing is recomputed.
.EXAMPLE
    .\mt5t.ps1 MyEA.mq5 --symbol XAUUSD --from 2026.01.01 --to 2026.07.31
    .\mt5t.ps1 MyEA.mq5 --symbol XAUUSD --from 2026.07.06 --to 2026.07.31 --model 4 --json
#>

$ErrorActionPreference = 'Stop'

# ─── parse arguments (match mac CLI style) ──────────────────────────────
$src = ''; $symbol = ''; $from = ''; $to = ''
$period = 'M1'; $model = '4'; $deposit = '10000'; $leverage = '100'
$setfile = ''; $spread = '0'; $keep = $false; $asjson = $false
$optimize = ''; $criterion = '0'
$login = $env:MT5_LOGIN; $password = $env:MT5_PASSWORD; $server = $env:MT5_SERVER

$i = 0
while ($i -lt $args.Count) {
    $a = $args[$i]
    switch ($a) {
        '--login'     { $login    = $args[++$i] }
        '--password'  { $password = $args[++$i] }
        '--server'    { $server   = $args[++$i] }
        '--symbol'    { $symbol   = $args[++$i] }
        '--period'    { $period   = $args[++$i] }
        '--from'      { $from     = $args[++$i] }
        '--to'        { $to       = $args[++$i] }
        '--model'     { $model    = $args[++$i] }
        '--deposit'   { $deposit  = $args[++$i] }
        '--leverage'  { $leverage = $args[++$i] }
        '--set'       { $setfile  = $args[++$i] }
        '--spread'    { $spread   = $args[++$i] }
        '--keep'      { $keep = $true }
        '--json'      { $asjson = $true }
        '--optimize'  { $optimize = $args[++$i] }
        '--criterion' { $criterion = $args[++$i] }
        default {
            if ($a -like '-*') {
                Write-Host "unknown option: $a"
                exit 2
            }
            if (-not $src) { $src = $a }
        }
    }
    $i++
}

if (-not $src -or -not $symbol -or -not $from -or -not $to) {
    Write-Host "usage: mt5t <file.mq5|Name.ex5> --symbol SYM --from YYYY.MM.DD --to YYYY.MM.DD [options]"
    exit 2
}

if ($setfile -and -not (Test-Path $setfile)) {
    Write-Host "set file not found: $setfile"
    exit 2
}

# ─── find MetaTrader 5 ─────────────────────────────────────────────────
function Find-MT5 {
    $candidates = @(
        "$env:ProgramFiles\MetaTrader 5",
        "${env:ProgramFiles(x86)}\MetaTrader 5"
    )
    foreach ($c in $candidates) {
        if (Test-Path "$c\terminal64.exe") { return $c }
    }
    foreach ($drive in @('C','D','E')) {
        $p = "${drive}:\MetaTrader 5"
        if (Test-Path "$p\terminal64.exe") { return $p }
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

$EXPERTS  = "$MT5_DATA\MQL5\Experts"
$TERMINAL = "$MT5_INSTALL\terminal64.exe"
$HERE     = Split-Path -Parent $MyInvocation.MyCommand.Path
$REPO     = Split-Path -Parent $HERE  # repo root (parent of windows/)

$name = [System.IO.Path]::GetFileNameWithoutExtension($src)

# ─── 1. compile if source was given ─────────────────────────────────────
if ($src -like '*.mq5') {
    $srcPath = (Resolve-Path $src -ErrorAction SilentlyContinue).Path
    if (-not $srcPath -or -not (Test-Path $srcPath)) {
        Write-Host "not found: $src"
        exit 2
    }
    Write-Host "compiling $name ..."
    & "$HERE\mt5c.ps1" $srcPath -Keep
    if ($LASTEXITCODE -ne 0) {
        Write-Host "compile failed, test aborted"
        exit 1
    }
} else {
    # .ex5 given directly — must already be in Experts
    if (-not (Test-Path "$EXPERTS\$name.ex5")) {
        Write-Host "not found in Experts: $name.ex5"
        exit 2
    }
}

# ─── 2. build the tester config ────────────────────────────────────────
$configDir = "$MT5_DATA\config"
if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

$reportsDir = "$MT5_DATA\reports"
if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }

# clean old reports
Remove-Item "$reportsDir\$name.htm"  -Force -ErrorAction SilentlyContinue
Remove-Item "$reportsDir\$name.html" -Force -ErrorAction SilentlyContinue
Remove-Item "$reportsDir\$name.xml"  -Force -ErrorAction SilentlyContinue

$report = "reports\$name"

$ini = @()

# On Windows, /config: may override the default login. If no credentials were
# given, read them from the terminal's existing common.ini so we don't lose
# the logged-in session.
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
$ini += "[Tester]"
$ini += "Expert=$name.ex5"
$ini += "Symbol=$symbol"
$ini += "Period=$period"
$ini += "Model=$model"
$ini += "ExecutionMode=0"
if ($optimize) {
    $ini += "Optimization=$optimize"
    $ini += "OptimizationCriterion=$criterion"
} else {
    $ini += "Optimization=0"
}
$ini += "ForwardMode=0"
$ini += "FromDate=$from"
$ini += "ToDate=$to"
$ini += "Deposit=$deposit"
$ini += "Currency=USD"
$ini += "Leverage=1:$leverage"
$ini += "Spread=$spread"
$ini += "Report=$report"
$ini += "ReplaceReport=1"
$ini += "ShutdownTerminal=1"
$ini += "Visual=0"

if ($setfile) {
    $ini += ""
    $ini += "[TesterInputs]"
    $setContent = Get-Content $setfile | Where-Object { $_ -and $_ -notmatch '^\s*;' }
    if ($optimize) {
        # optimization needs the full  Name=value||start||step||stop||enabled  form
        $ini += $setContent
    } else {
        # single run takes the value only
        foreach ($line in $setContent) {
            $ini += ($line -replace '\|\|.*$', '')
        }
    }
}

$iniPath = "$configDir\mt5t.ini"
$ini | Out-File -FilePath $iniPath -Encoding ascii -Force

Write-Host "testing $name  $symbol $period  $from .. $to  model=$model"

# ─── 3. wait for MetaEditor to finish ───────────────────────────────────
for ($w = 0; $w -lt 30; $w++) {
    $me = Get-Process -Name "MetaEditor64" -ErrorAction SilentlyContinue
    if (-not $me) { break }
    Start-Sleep -Seconds 1
}
Start-Sleep -Seconds 2

# ─── 4. run the terminal ────────────────────────────────────────────────
$proc = Start-Process -FilePath $TERMINAL `
    -ArgumentList "/config:`"$iniPath`"" `
    -PassThru -ErrorAction SilentlyContinue
$null = $proc  # suppress display

if ($proc) {
    $null = $proc.WaitForExit(600000)  # 10 minute timeout
    if (-not $proc.HasExited) {
        Write-Host "terminal timed out after 10 minutes"
        $proc.Kill()
    }
}

# ─── 5. find the report ────────────────────────────────────────────────
$out = $null
$candidates = @(
    "$reportsDir\$name.xml",
    "$reportsDir\$name.htm",
    "$reportsDir\$name.html",
    "$MT5_DATA\$name.htm",
    "$MT5_DATA\$name.html"
)
foreach ($cand in $candidates) {
    if (Test-Path $cand) { $out = $cand; break }
}

if (-not $out) {
    # check logs for auth failure
    $logDir = "$MT5_DATA\logs"
    $latestLog = Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if ($latestLog) {
        $logText = ''
        try {
            $logText = [System.IO.File]::ReadAllText($latestLog.FullName, [System.Text.Encoding]::Unicode)
        } catch {
            $logText = Get-Content $latestLog.FullName -Raw -ErrorAction SilentlyContinue
        }
        if ($logText -match '(?i)authorization.*failed|invalid account') {
            Write-Host "no report -- MetaTrader has no working account, so it quits before testing."
            Write-Host "log in once in the MT5 window, or pass --login/--password/--server."
            exit 1
        }
    }

    Write-Host "no report produced. last tester log:"
    $testerLogDir = "$MT5_DATA\Tester\logs"
    $testerLog = Get-ChildItem $testerLogDir -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($testerLog) {
        try {
            $content = [System.IO.File]::ReadAllText($testerLog.FullName, [System.Text.Encoding]::Unicode)
        } catch {
            $content = Get-Content $testerLog.FullName -Raw
        }
        ($content -split "`r?`n") | Select-Object -Last 25 | ForEach-Object { Write-Host $_ }
    }
    exit 1
}

# ─── 6. print what MetaTrader reported ──────────────────────────────────
$env:MT5T_JSON = if ($asjson) { '1' } else { '0' }
$parseScript = "$REPO\mt5t_parse.py"
# On Windows, Python 3 is typically 'python' not 'python3'
$pythonCmd = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' } else { 'python' }
& $pythonCmd $parseScript $out
$parseExit = $LASTEXITCODE

if (-not $keep) {
    $srcDir = ''
    if ($src -like '*.mq5') {
        $srcDir = [System.IO.Path]::GetDirectoryName((Resolve-Path $src -ErrorAction SilentlyContinue).Path)
    }
    if ($srcDir -ne $EXPERTS) {
        Remove-Item "$EXPERTS\$name.ex5" -Force -ErrorAction SilentlyContinue
        Remove-Item "$EXPERTS\$name.mq5" -Force -ErrorAction SilentlyContinue
        Remove-Item "$EXPERTS\$name.log" -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "report: $out"
}

exit $parseExit
