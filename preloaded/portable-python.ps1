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
$ready = Join-Path $state 'ready.state'
$app = Join-Path $Root 'application'
$lock = $null
$code = 10

function Verify-Bundle($record) {
    $files = $record.sha256.PSObject.Properties
    $verified = 0
    # Only shipped paths are reserved. Unrelated root files and directories
    # can be added before or after setup, and survive a rebuild untouched.
    $payload = foreach ($name in @('START.bat', 'portable-common.ps1', 'portable-python.ps1',
                                    'install-plan.txt', 'runtime', 'wheelhouse')) {
        $path = Join-Path $Root $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -Force
        Assert-NotLinked $item
        if ($item.PSIsContainer -ne ($name -in @('runtime', 'wheelhouse'))) {
            throw "Bundle path has the wrong type: $name"
        }
        if ($item.PSIsContainer) { Get-TreeFiles $item.FullName } else { $item }
    }
    foreach ($item in $payload) {
        $relative = $item.FullName.Substring($Root.Length + 1).Replace('\', '/')
        $entry = $files[$relative]
        if ($null -eq $entry -or $entry.Value -cnotmatch '^[a-f0-9]{64}$' -or (Get-Hash $item.FullName) -cne $entry.Value) {
            throw "Bundle file is unexpected or failed SHA-256 verification: $relative"
        }
        $verified++
    }
    if ($verified -ne @($files).Count) { throw 'The bundle is missing one or more declared files.' }
    Write-Host "Verified bundle files: $verified"
}

try {
    [Console]::OutputEncoding = $Utf8
    Assert-LocalWindows $Root
    if (-not [IO.File]::Exists($manifest)) {
        throw 'No prepared bundle found. Extract the Transfer ZIP, not the Starter ZIP. On the online setup machine, run SETUP.bat, add the application to bundle/, then ZIP its contents.'
    }
    foreach ($path in @($state, $venv, $ready, $manifest, $runtime, (Join-Path $Root 'runtime'))) {
        if (Test-Path -LiteralPath $path) { Assert-NotLinked (Get-Item -LiteralPath $path -Force) }
    }
    # Allow concurrent-start rejection without writing into the payload. The
    # existing opened user script/common are trusted, not signed by the manifest.
    $stateItem = [IO.Directory]::CreateDirectory($state)
    Assert-NotLinked $stateItem
    $lock = Open-WorkspaceLock (Join-Path $state 'workspace.lock')
    $record = [IO.File]::ReadAllText($manifest, $Utf8) | ConvertFrom-Json
    if ($record.schema -ne 4) { throw 'Unsupported bundle manifest.' }
    $fingerprint = @($Root, (Get-Hash $manifest)) -join "`n"
    Set-Location -LiteralPath $Root
    Write-Host "PORTABLE PYTHON (OFFLINE): CPython $($record.python), uv $($record.uv)"

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
        Write-Host 'First START or rebuild: verifying the prepared environment and creating .venv from local files. No downloads.'
        Verify-Bundle $record
        if ([IO.File]::Exists($ready)) { [IO.File]::Delete($ready) }
        Initialize-OfflineVenv $Root $venv
        $setup = 'PERFORMED'
    }
    try {
        $packages = @(Read-EnvironmentPackages $venv $record.python $runtime)
        if (($packages -join "`n") -cne ($record.installed_packages -join "`n")) {
            throw 'Installed package names or versions differ from the prepared bundle.'
        }
    } catch {
        throw "$($_.Exception.Message) $recovery"
    }
    if ($setup -eq 'PERFORMED') { [IO.File]::WriteAllText($ready, $fingerprint, $Utf8) }
    Write-Host 'PORTABLE PYTHON STATUS: READY'
    Write-Host "Setup: $setup"
    Write-Host 'Interpreter: .venv\Scripts\python.exe'

    $code = 20
    if ([IO.Directory]::Exists($app)) { Assert-NotLinked (Get-Item -LiteralPath $app -Force) }
    foreach ($name in @('__main__.py', '__init__.py')) {
        $file = Join-Path $app $name
        if (-not [IO.File]::Exists($file)) {
            throw "The Transfer ZIP is missing application\$name. Ask the IT specialist for the complete Transfer ZIP. The offline Python environment is ready."
        }
        Assert-NotLinked (Get-Item -LiteralPath $file -Force)
    }
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
