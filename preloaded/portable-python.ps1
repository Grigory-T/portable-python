[CmdletBinding()]
param([switch]$NoPause)

$Root = $PSScriptRoot
. (Join-Path $Root 'portable-common.ps1')
$originalEncoding = [Console]::OutputEncoding
$originalLocation = Get-Location
$state = Join-Path $Root '.portable-python'
$venv = Join-Path $Root '.venv'
$python = Join-Path $venv 'Scripts\python.exe'
$runtime = Join-Path $Root 'runtime\python.exe'
$manifest = Join-Path $Root 'bundle-manifest.json'
$project = Join-Path $Root 'pyproject.toml'
$ready = Join-Path $state 'ready.state'
$lock = $null
$code = 10

function Verify-Bundle {
    $record = [IO.File]::ReadAllText($manifest, $Utf8) | ConvertFrom-Json
    if ($record.schema -ne 1) { throw 'Unsupported bundle manifest.' }
    $files = $record.sha256.PSObject.Properties
    $verified = 0
    $payload = foreach ($item in (Get-ChildItem -LiteralPath $Root -Force)) {
        if ($item.FullName -eq $state) { continue }
        Assert-NotLinked $item
        if ($item.PSIsContainer) { Get-TreeFiles $item.FullName } else { $item }
    }
    $payload | ForEach-Object {
        $relative = $_.FullName.Substring($Root.Length + 1).Replace('\', '/')
        if ($relative -ne 'bundle-manifest.json') {
            $entry = $files[$relative]
            if ($null -eq $entry -or $entry.Value -cnotmatch '^[a-f0-9]{64}$' -or (Get-Hash $_.FullName) -cne $entry.Value) {
                throw "Bundle file is unexpected or failed SHA-256 verification: $relative"
            }
            $verified++
        }
    }
    if ($verified -ne @($files).Count) { throw 'The bundle is missing one or more declared files.' }
    Write-Host "Verified bundle files: $verified"
}

try {
    [Console]::OutputEncoding = $Utf8
    Assert-LocalWindows $Root
    if (-not [IO.File]::Exists($manifest)) {
        throw 'No prepared bundle found. On the online setup machine, first run SETUP.bat and ZIP only bundle contents.'
    }
    foreach ($path in @($state, $venv, $manifest, $runtime, $project, (Join-Path $Root 'runtime'), (Join-Path $Root 'application'))) {
        if (Test-Path -LiteralPath $path) { Assert-NotLinked (Get-Item -LiteralPath $path -Force) }
    }
    # Allow concurrent-start rejection without writing into the payload. The
    # existing opened user script/common are trusted, not signed by the manifest.
    $stateItem = [IO.Directory]::CreateDirectory($state)
    Assert-NotLinked $stateItem
    $lockPath = Join-Path $state 'workspace.lock'
    if (Test-Path -LiteralPath $lockPath) { Assert-NotLinked (Get-Item -LiteralPath $lockPath -Force) }
    $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    $pins = Read-Pins $project
    $fingerprint = @($Root, (Get-Hash $manifest), (Get-Hash $project)) -join "`n"
    Set-Location -LiteralPath $Root
    Write-Host "PORTABLE PYTHON (OFFLINE): CPython $($pins['requires-python']), uv $($pins['required-version'])"

    if ([IO.File]::Exists($ready)) {
        Assert-NotLinked (Get-Item -LiteralPath $ready -Force)
        if ([IO.File]::ReadAllText($ready, $Utf8) -cne $fingerprint) {
            throw 'Bundle was moved after setup or its configuration changed. Use a fresh extraction of a prepared bundle.'
        }
        Set-LocalEnvironment $state
        $setup = 'SKIPPED'
    } else {
        if (Test-Path -LiteralPath $venv) {
            throw 'A .venv exists without a readiness marker. Re-extract the prepared ZIP into a new local folder.'
        }
        Write-Host 'Please wait: verifying the bundle and installing its wheels offline...'
        Verify-Bundle
        if ((Get-Hash (Join-Path $Root 'uv.exe')) -ne $pins['uv-exe-sha256']) {
            throw 'Bundled uv.exe failed pinned SHA-256 verification.'
        }
        Set-LocalEnvironment $state
        Initialize-OfflineVenv $Root $venv
        $setup = 'PERFORMED'
    }
    foreach ($path in @((Join-Path $venv 'Scripts'), $python, (Join-Path $venv 'pyvenv.cfg'))) {
        Assert-NotLinked (Get-Item -LiteralPath $path -Force)
    }
    Confirm-Interpreter $python $pins['requires-python'] $runtime $venv
    if ($setup -eq 'PERFORMED') { [IO.File]::WriteAllText($ready, $fingerprint, $Utf8) }
    Write-Host 'PORTABLE PYTHON STATUS: READY'
    Write-Host "Setup: $setup"
    Write-Host 'Interpreter: .venv\Scripts\python.exe'

    $code = 20
    $child = Invoke-Native 'application' $python @('-u', '-E', '-s', '-B', '-X', 'utf8', '-m', 'application')
    Write-Host "Application exit code: $child"
    if ($child -eq 0) {
        Write-Host 'APPLICATION STATUS: SUCCESS' -ForegroundColor Green
        $code = 0
    } else {
        Write-Host 'APPLICATION STATUS: FAILURE' -ForegroundColor Red
    }
} catch {
    $stage = if ($code -eq 20) { 'APPLICATION' } else { 'PORTABLE PYTHON' }
    Write-Host "${stage} STATUS: FAILURE - $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
    Set-Location -LiteralPath $originalLocation.Path
    [Console]::OutputEncoding = $originalEncoding
}
Write-Host "Overall exit code: $code"
if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
exit $code
