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
$data = Join-Path $Root 'data'
$lock = $null
$code = 10

function Verify-Bundle($record) {
    $files = $record.sha256.PSObject.Properties
    $verified = 0
    $payload = foreach ($item in (Get-ChildItem -LiteralPath $Root -Force)) {
        if ($item.FullName -eq $state) { continue }
        Assert-NotLinked $item
        if ($item.PSIsContainer -and $item.Name -eq 'data') { continue }
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
    foreach ($path in @($state, $venv, $ready, $data, $manifest, $runtime, $project, (Join-Path $Root 'runtime'), (Join-Path $Root 'application'))) {
        if (Test-Path -LiteralPath $path) { Assert-NotLinked (Get-Item -LiteralPath $path -Force) }
    }
    # Allow concurrent-start rejection without writing into the payload. The
    # existing opened user script/common are trusted, not signed by the manifest.
    $stateItem = [IO.Directory]::CreateDirectory($state)
    Assert-NotLinked $stateItem
    $lock = Open-WorkspaceLock (Join-Path $state 'workspace.lock')
    $pins = Read-Pins $project
    $record = [IO.File]::ReadAllText($manifest, $Utf8) | ConvertFrom-Json
    if ($record.schema -ne 2) { throw 'Unsupported bundle manifest.' }
    $fingerprint = @($Root, (Get-Hash $manifest), (Get-Hash $project)) -join "`n"
    Set-Location -LiteralPath $Root
    Write-Host "PORTABLE PYTHON (OFFLINE): CPython $($pins['requires-python']), uv $($pins['required-version'])"

    $recovery = 'With the app stopped, move .venv out of this folder, then run START.bat to rebuild offline.'
    Set-LocalEnvironment $state
    if (Test-Path -LiteralPath $venv) {
        if (-not [IO.File]::Exists($ready)) {
            throw "A .venv exists without a readiness marker. $recovery"
        }
        if ([IO.File]::ReadAllText($ready, $Utf8) -cne $fingerprint) {
            throw 'Bundle was moved after setup or its configuration changed. Use a fresh extraction of a prepared bundle.'
        }
        $setup = 'SKIPPED'
    } else {
        Write-Host 'Please wait: verifying the bundle and installing its wheels offline...'
        Verify-Bundle $record
        if ((Get-Hash (Join-Path $Root 'uv.exe')) -ne $pins['uv-exe-sha256']) {
            throw 'Bundled uv.exe failed pinned SHA-256 verification.'
        }
        if ([IO.File]::Exists($ready)) { [IO.File]::Delete($ready) }
        Initialize-OfflineVenv $Root $venv
        $setup = 'PERFORMED'
    }
    try {
        $packages = @(Read-EnvironmentPackages $venv $pins['requires-python'] $runtime)
        if (($packages -join "`n") -cne ($record.installed_packages -join "`n")) {
            throw 'Installed package names or versions differ from the prepared bundle.'
        }
    } catch {
        throw "$($_.Exception.Message) $recovery"
    }
    if ($setup -eq 'PERFORMED') { [IO.File]::WriteAllText($ready, $fingerprint, $Utf8) }
    # The payload is immutable; applications get a writable data root.
    Assert-NotLinked ([IO.Directory]::CreateDirectory($data))
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
