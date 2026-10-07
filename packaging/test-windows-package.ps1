param([Parameter(Mandatory = $true)][string]$Archive)
$ErrorActionPreference = 'Stop'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('moneytracker-package-' + [guid]::NewGuid())
$bundle = Join-Path $testRoot 'app'
$data = Join-Path $testRoot 'user-data'
$process = $null
$previousData = $env:MONEYTRACKER_DATA_DIR
$previousLegacy = $env:MONEYTRACKER_LEGACY_DIR
try {
    Expand-Archive -LiteralPath $Archive -DestinationPath $bundle
    $executable = Join-Path $bundle 'money_tracker.exe'
    foreach ($required in @('money_tracker.exe', 'flutter_windows.dll', 'data\icudtl.dat', 'data\flutter_assets')) {
        if (!(Test-Path (Join-Path $bundle $required))) { throw "Package is missing $required" }
    }
    $env:MONEYTRACKER_DATA_DIR = $data
    Remove-Item Env:MONEYTRACKER_LEGACY_DIR -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $executable -WorkingDirectory $bundle -PassThru
    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) { throw "Packaged app exited during startup with code $($process.ExitCode)" }
        $windowReady = $process.MainWindowHandle -ne 0 -and $process.MainWindowTitle -eq 'MoneyTracker'
        $serviceReady = Test-Path (Join-Path $data 'undo.sqlite3')
    } while ((!$windowReady -or !$serviceReady) -and (Get-Date) -lt $deadline)
    if (!$windowReady) { throw 'Packaged app did not create its MoneyTracker window' }
    if (!$serviceReady) { throw 'Native data service did not initialize (check SQLite and system credential storage)' }
    Start-Sleep -Seconds 3
    $process.Refresh()
    if ($process.HasExited) { throw 'Packaged app exited after initialization' }
    if (!$process.CloseMainWindow()) { throw 'Packaged app did not accept a window-close request' }
    if (!$process.WaitForExit(10000)) { throw 'Packaged app did not exit after closing its window' }
    if ($process.ExitCode -ne 0) { throw "Packaged app closed with code $($process.ExitCode)" }
    Write-Output 'PASS: extracted Windows package opened its window, initialized native storage, and closed cleanly.'
} finally {
    if ($process -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $env:MONEYTRACKER_DATA_DIR = $previousData
    $env:MONEYTRACKER_LEGACY_DIR = $previousLegacy
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
