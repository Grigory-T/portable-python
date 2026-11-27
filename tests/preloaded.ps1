[CmdletBinding(DefaultParameterSetName='Starter')]
param(
    [Parameter(Mandatory=$true, ParameterSetName='Starter')][string]$Zip,
    [Parameter(ParameterSetName='Starter')][string]$ExportBundle,
    [Parameter(Mandatory=$true, ParameterSetName='Target')][string]$TargetBundle,
    [switch]$BlockNetwork,
    [switch]$PolarsCompatibilityRuntime
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$unicodeFixture = ('zip-' + [char]0x00e9 + '.txt')
$pins = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'library-pins.json') -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'workspace.ps1')
$starterZip = if ($Zip) { (Get-Item -LiteralPath $Zip).FullName }
$inputBundle = if ($TargetBundle) { (Get-Item -LiteralPath $TargetBundle).FullName }
$testRoot = New-TestWorkspace 'preloaded'
$group = 'Portable Python acceptance ' + [guid]::NewGuid().ToString('N')

function Invoke-Target([string]$Root, [int]$Expected) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'portable-python.ps1') -NoPause 2>&1
        $exit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    $text = $lines -join "`n"
    Write-Host $text
    if ($exit -ne $Expected) { throw "Expected target exit code $Expected, got $exit" }
    return $text
}

function Get-TestRequirements {
    $pins.data.PSObject.Properties | ForEach-Object {
        $override = $pins.preloaded.PSObject.Properties[$_.Name]
        $version = if ($override) { $override.Value } else { $_.Value }
        $name = if ($PolarsCompatibilityRuntime -and $_.Name -eq 'polars') { 'polars[rtcompat]' } else { $_.Name }
        $marker = if ($_.Name -eq 'more-itertools') { "; sys_platform == 'win32'" } else { '' }
        "$name==$version$marker"
    }
}

function Add-TestApplication([string]$Target, [string]$Scenario) {
    $app = [IO.Directory]::CreateDirectory((Join-Path $Target 'application')).FullName
    [IO.File]::WriteAllText((Join-Path $app '__init__.py'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $app $unicodeFixture), 'packaged application data', $utf8)
    if ($Scenario -eq 'wheels') {
        [IO.File]::WriteAllLines((Join-Path $app 'test-requirements.txt'), [string[]]@(Get-TestRequirements), $utf8)
        [IO.File]::WriteAllText((Join-Path $Target 'application\__main__.py'), @'
from pathlib import Path
from importlib import import_module
from importlib.metadata import version
from io import BytesIO
import sys
import openpyxl
import polars as pl
import xlrd
import xlsxwriter
from python_calamine import CalamineWorkbook
from .nested.probe import value
from more_itertools import chunked
assert Path(sys._base_executable).resolve() == Path("runtime/python.exe").resolve()
assert sys.version_info[:3] == (3, 15, 2)
requirements = Path(__file__).with_name('test-requirements.txt').read_text(encoding='utf-8').splitlines()
for requirement in requirements:
    name, expected = requirement.split(';')[0].strip().split('==')
    assert version(name.split('[')[0]) == expected, name
polars_runtime = '_polars_runtime_compat' if any('[rtcompat]' in req for req in requirements) else '_polars_runtime_32'
plr = import_module('polars._plr')
assert plr is import_module(f'{polars_runtime}._polars_runtime'), plr.__file__
assert pl.DataFrame({"x": [1, 2, 3]})["x"].sum() == 6
stream = BytesIO()
with xlsxwriter.Workbook(stream, {"in_memory": True}) as workbook:
    workbook.add_worksheet("Check").write("A1", 42)
stream.seek(0)
workbook = openpyxl.load_workbook(stream, read_only=True)
assert workbook["Check"]["A1"].value == 42
workbook.close()
stream.seek(0)
assert CalamineWorkbook.from_filelike(stream).get_sheet_by_name("Check").to_python() == [[42]]
assert list(chunked(range(5), 3)) == [[0, 1, 2], [3, 4]]
assert value == 42
assert Path('input').is_dir() and Path('output').is_dir() and Path('workings').is_dir()
assert Path('input/user-input.txt').read_text(encoding='utf-8') == 'added offline'
assert Path('run-settings.txt').read_text(encoding='utf-8') == 'local user file'
print("WHEELS AND NESTED IMPORTS SUCCESS")
'@, $utf8)
        [IO.Directory]::CreateDirectory((Join-Path $Target 'application\nested')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $Target 'application\nested\probe.py'), 'value = 42', $utf8)
    } else {
        [IO.File]::WriteAllText((Join-Path $Target 'application\__main__.py'), @'
import os
from pathlib import Path
import sys

if os.getenv('PORTABLE_TEST_EXIT'):
    raise SystemExit(7)
assert not Path('data').exists()
assert Path('input/user-input.txt').read_text(encoding='utf-8') == 'added offline'
text = '\u0424\u043e\u0440\u043c\u0438\u0440\u043e\u0432\u0430\u043d\u0438\u0435 | \u0401\u0451 | \u20ac | \u65e5\u672c\u8a9e | \U0001f600'
print('UTF8_STDOUT|' + text)
print('UTF8_STDERR|' + text, file=sys.stderr)
print(text)
sys.stderr.write('\n\rUTF8_PROGRESS|' + text + '\n')
print('STDLIB APPLICATION SUCCESS')
'@, $utf8)
    }
}

function Read-TestSetupLog([string]$Source, [bool]$Success) {
    $lines = [IO.File]::ReadAllLines((Join-Path $Source 'setup.log'))
    $prefix = '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} UTC \| (INFO|DETAIL|ERROR) \| [^|]+ \| .+'
    if (-not $lines.Count -or @($lines | Where-Object { $_ -cnotmatch $prefix }).Count) {
        throw 'setup.log has a missing or malformed UTC record.'
    }
    $log = $lines -join "`n"
    if ($log -match [regex]::Escape($Source) -or $log -match [regex]::Escape($Source.Replace('\', '/'))) {
        throw 'setup.log exposed its absolute Starter ZIP extraction path.'
    }
    $result = if ($Success) { '\| INFO \| Result \| SUCCESS \(exit 0;' } else { '\| ERROR \| Result \| FAILURE \(exit 10;' }
    if ($lines[-1] -notmatch $result) { throw 'setup.log did not finish with the expected result.' }
    return $log
}

function New-PreparedTestZip([string]$Scenario) {
        $source = Join-Path $testRoot "$scenario online"
        if ($scenario -eq 'wheels') { $source += 'x' * (125 - $source.Length) }
        [IO.Compression.ZipFile]::ExtractToDirectory($starterZip, $source)
        # Ensure the online preparer does not ship even accidentally present code.
        [IO.Directory]::CreateDirectory((Join-Path $source 'application')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'application\not-shipped.py'), 'raise SystemExit(1)', $utf8)
        if ((Invoke-Target $source 10) -notmatch 'No prepared bundle found') {
            throw 'START on the starter did not give an actionable error.'
        }
        if ($scenario -eq 'wheels') {
            $project = Join-Path $source 'pyproject.toml'
            $requirements = @(Get-TestRequirements)
            $toml = [IO.File]::ReadAllText($project).Replace('dependencies = []',
                ('dependencies = ' + (ConvertTo-Json -InputObject $requirements -Compress)))
            [IO.File]::WriteAllText($project, $toml, $utf8)
        } else {
            $setupLock = [IO.File]::Open((Join-Path $source '.prepare.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
            try {
                $blocked = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $source 'prepare.ps1')
                if ($LASTEXITCODE -ne 10 -or ($blocked -join "`n") -notmatch 'Workspace lock is unavailable' -or
                    @(Get-ChildItem -LiteralPath $source -Directory -Filter '.prepare-*').Count) {
                    throw 'Concurrent SETUP was not rejected before preparation.'
                }
            } finally { $setupLock.Dispose() }
            $project = Join-Path $source 'pyproject.toml'
            $original = [IO.File]::ReadAllText($project)
            $badPin = $original -replace '(?m)(uv-archive-sha256 = ")[0-9a-f]{64}', ('${1}' + ('0' * 64))
            [IO.File]::WriteAllText($project, $badPin, $utf8)
            try {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $source 'prepare.ps1') | Out-Host
                if ($LASTEXITCODE -ne 10 -or (Test-Path -LiteralPath (Join-Path $source 'bundle')) -or
                    (Test-Path -LiteralPath (Join-Path $source 'prepared-app.zip'))) {
                    throw 'A bad pinned SHA-256 did not fail closed with a setup.log entry.'
                }
                $failedLog = Read-TestSetupLog $source $false
                if ($failedLog -notmatch '\| ERROR \| uv and license downloads \| FAILED: SHA-256 mismatch for uv-.*expected [a-f0-9]{64}; got [a-f0-9]{64}' -or
                    $failedLog -match '\| Verify and inspect uv \| BEGIN') {
                    throw 'setup.log did not record the hash failure or attempted to continue.'
                }
            } finally { [IO.File]::WriteAllText($project, $original, $utf8) }
        }
        # Use the actual setup wrapper in the default scenario.
        if ($scenario -eq 'stdlib') {
            & cmd.exe /d /c ('echo x|call "' + (Join-Path $source 'SETUP.bat') + '"') | Out-Host
        } else {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $source 'prepare.ps1') | Out-Host
        }
        if ($LASTEXITCODE -ne 0) { throw 'Online preparation failed.' }
        if (@(Get-ChildItem -LiteralPath $source -Directory -Force -Filter '.prepare-*').Count) {
            throw 'Online preparation left scratch work.'
        }
        $bundle = Join-Path $source 'bundle'
        $setupLog = Read-TestSetupLog $source $true
        if (@(Get-ChildItem -LiteralPath $source -File -Force -Filter '*.zip').Count -or
            (Test-Path -LiteralPath (Join-Path $bundle 'application')) -or
            $setupLog -notmatch 'Published prepared folder bundle/ and online build records bundle-records/\. No Transfer ZIP was created\.') {
            throw 'SETUP must publish a prepared folder without app code or a Transfer ZIP.'
        }
        $phases = @('Preflight', 'uv and license downloads', 'Verify and inspect uv', 'CPython archive download',
                    'Install CPython locally', 'Validate project settings', 'Resolve dependency lock',
                    'Export offline install plan', 'Wheel downloads', 'Trial offline installation',
                    'Write bundle manifest', 'Publish prepared folder')
        $observed = @($setupLog -split "`n" | ForEach-Object {
            if ($_ -match '\| INFO \| ([^|]+) \| BEGIN \(') { $Matches[1] }
        })
        if (($observed -join ',') -cne ($phases -join ',') -or
            $setupLog -notmatch 'Install CPython locally \| .*reading this local file' -or
            $setupLog -notmatch 'Trial offline installation \| .*required hashes' -or
            $setupLog -notmatch 'Cleanup \| Removed \.prepare-work/') {
            throw 'setup.log did not record the expected setup phases.'
        }
        if ($scenario -eq 'wheels' -and
            $setupLog -notmatch 'Resolve dependency lock \| .*Sending fresh GET request for: https://pypi\.org/simple/') {
            throw 'setup.log did not record the actual PyPI metadata request.'
        }
        $records = Join-Path $source 'bundle-records'
        $provenance = [IO.File]::ReadAllText((Join-Path $records 'provenance.json')) | ConvertFrom-Json
        $locked = Join-Path $records 'uv.lock'
        if ($provenance.uv_lock_sha256 -ne (Get-FileHash -LiteralPath $locked).Hash -or
            $provenance.uv_exe_sha256 -ne (Get-FileHash -LiteralPath (Join-Path $bundle 'runtime\uv.exe')).Hash -or
            (Get-FileHash -LiteralPath (Join-Path $source 'pyproject.toml')).Hash -ne
                (Get-FileHash -LiteralPath (Join-Path $records 'pyproject.toml')).Hash -or
            @($provenance.downloads | Where-Object { $_.url -notmatch '^https://' -or $_.sha256 -notmatch '^[a-f0-9]{64}$' }).Count) {
            throw 'Bundle provenance is incomplete or inconsistent.'
        }
        $wheels = @()
        $wheelhouse = Join-Path $bundle 'wheelhouse'
        if ([IO.Directory]::Exists($wheelhouse)) {
            $wheels = @(Get-ChildItem -LiteralPath $wheelhouse -Filter '*.whl')
        }
        if (@($provenance.downloads).Count -ne (4 + $wheels.Count)) {
            throw 'A downloaded artifact is missing from provenance.'
        }
        foreach ($entry in $provenance.downloads) {
            $file = [IO.Path]::GetFileName($entry.file)
            if (-not $setupLog.Contains("GET: $($entry.url)") -or
                $setupLog -notmatch ('HTTP 200 received [1-9]\d* bytes: ' + [regex]::Escape($file)) -or
                -not $setupLog.Contains("SHA-256 VERIFIED: $file $($entry.sha256)")) {
                throw "setup.log download receipt is incomplete for $file."
            }
        }
        foreach ($wheel in $wheels) {
            $entry = @($provenance.downloads | Where-Object file -ceq ("wheelhouse/" + $wheel.Name))
            if ($entry.Count -ne 1 -or $entry[0].sha256 -ne (Get-FileHash -LiteralPath $wheel.FullName).Hash) {
                throw 'Wheel receipt does not match shipped bytes.'
            }
        }
        if ($scenario -eq 'wheels' -and -not $ExportBundle) {
            $manifestPath = Join-Path $bundle 'bundle-manifest.json'
            $firstManifest = (Get-FileHash -LiteralPath $manifestPath).Hash
            [IO.File]::Copy($locked, (Join-Path $source 'uv.lock'))
            [IO.Directory]::Delete($bundle, $true)
            [IO.Directory]::Delete($records, $true)
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $source 'prepare.ps1') | Out-Host
            if ($LASTEXITCODE -ne 0 -or (Get-FileHash -LiteralPath $manifestPath).Hash -ne $firstManifest -or
                @(Get-ChildItem -LiteralPath $source -File -Force -Filter '*.zip').Count) {
                throw 'Replaying the saved lock changed the verified payload or created a ZIP.'
            }
            $replayLog = Read-TestSetupLog $source $true
            if ($replayLog -notmatch 'Using supplied uv.lock unchanged' -or $replayLog -match '\| Resolve dependency lock \|') {
                throw 'Replaying the saved lock silently resolved.'
            }
        }
        # Model the IT specialist assembling the final package after SETUP.
        Add-TestApplication $bundle $Scenario
        foreach ($folder in @('input', 'output', 'workings', 'other [local]')) {
            [IO.Directory]::CreateDirectory((Join-Path $bundle $folder)) | Out-Null
        }
        # Include both Unicode filenames and empty directories in the ZIP.
        foreach ($folder in @('input', 'other [local]')) {
            [IO.File]::WriteAllText((Join-Path (Join-Path $bundle $folder) $unicodeFixture), "keep $folder", $utf8)
        }
        [IO.File]::WriteAllText((Join-Path $bundle 'run-settings.txt'), 'local user file', $utf8)
        foreach ($name in @('uv.toml', 'pyproject.toml', 'uv.lock', '.python-version')) {
            [IO.File]::WriteAllText((Join-Path $bundle $name), 'unrelated user file', $utf8)
        }
        $preparedZip = Join-Path $testRoot "$scenario prepared.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($bundle, $preparedZip, [IO.Compression.CompressionLevel]::Optimal, $false)
        # Destroy the input before starting the target. Nothing on the target
        # can silently rely on the online directory or its prepared venv.
        [IO.Directory]::Delete($source, $true)
        return $preparedZip
}

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if ($starterZip) {
        $longRoot = Join-Path $testRoot ('x' * (125 - $testRoot.Length))
        [IO.Compression.ZipFile]::ExtractToDirectory($starterZip, $longRoot)
        $longOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $longRoot 'prepare.ps1')
        if ($LASTEXITCODE -ne 10 -or ($longOutput -join ' ') -notmatch 'Folder path is too long' -or
            (Test-Path -LiteralPath (Join-Path $longRoot '.prepare.lock'))) {
            throw 'SETUP did not reject an over-long path before writing state.'
        }
        if ((Invoke-Target $longRoot 10) -notmatch 'Folder path is too long' -or
            (Test-Path -LiteralPath (Join-Path $longRoot '.portable-python'))) {
            throw 'START did not reject an over-long path before writing state.'
        }
    }
    $scenarios = if ($inputBundle -or $ExportBundle) { @('wheels') } else { @('stdlib', 'wheels') }
    foreach ($scenario in $scenarios) {
        $preparedZip = if ($inputBundle) { $inputBundle } else { New-PreparedTestZip $scenario }
        if ($ExportBundle) {
            [IO.File]::Copy($preparedZip, $ExportBundle)
            Write-Host 'Prepared compatibility fixture ZIP exported.'
            continue
        }
        $target = Join-Path $testRoot ("$scenario target " + [char]0x00e9 + ' [literal]')
        [IO.Compression.ZipFile]::ExtractToDirectory($preparedZip, $target)
        $expected = @('START.bat', 'portable-common.ps1', 'portable-python.ps1', 'bundle-manifest.json',
                      'install-plan.txt', 'runtime', 'application', 'input', 'output', 'workings', 'other [local]',
                      'run-settings.txt', 'uv.toml', 'pyproject.toml', 'uv.lock', '.python-version')
        if ($scenario -eq 'wheels') { $expected += 'wheelhouse' }
        $actual = @(Get-ChildItem -LiteralPath $target -Force | ForEach-Object { $_.Name })
        if (Compare-Object $expected $actual -CaseSensitive) {
            throw 'Transfer ZIP does not match the reviewed flat layout, including empty project folders.'
        }
        $notices = [IO.File]::ReadAllText((Join-Path $target 'runtime\BUNDLE-LICENSES.txt'))
        if ($notices -notmatch 'Portable Python launcher \(MIT\)' -or
            $notices -notmatch 'Astral Software Inc\.' -or $notices -notmatch 'Apache License') {
            throw 'Transferred launcher and uv license notices are incomplete.'
        }
        if ($BlockNetwork) {
            foreach ($exe in @('runtime\uv.exe', 'runtime\python.exe', '.venv\Scripts\python.exe')) {
                New-NetFirewallRule -DisplayName "Preloaded test: $exe" -Group $group -Direction Outbound -Action Block -Profile Any -Program (Join-Path $target $exe) | Out-Null
            }
            if (@(Get-NetFirewallRule -Group $group | Where-Object { $_.Enabled -eq 'True' -and $_.Action -eq 'Block' }).Count -lt 3) {
                throw 'Outbound firewall rules were not applied.'
            }
        }
        $env:UV_INDEX = 'https://invalid.invalid/simple'
        $env:UV_PYTHON_INSTALL_DIR = 'C:\not-the-portable-runtime'
        $env:UV_OFFLINE = 'false'
        [IO.File]::WriteAllText((Join-Path $target 'input\user-input.txt'), 'added offline', $utf8)
        $first = Invoke-Target $target 0
        if ($first -notmatch 'Setup: PERFORMED' -or $first -notmatch 'APPLICATION STATUS: SUCCESS') {
            throw 'The Transfer ZIP did not run after adding only user input.'
        }
        if ($scenario -eq 'stdlib') {
            $noApp = Join-Path $testRoot 'missing app'
            [IO.Compression.ZipFile]::ExtractToDirectory($preparedZip, $noApp)
            [IO.Directory]::Move((Join-Path $noApp 'application'), (Join-Path $testRoot 'removed app'))
            $emptyApp = Invoke-Target $noApp 20
            if ($emptyApp -notmatch 'Setup: PERFORMED' -or $emptyApp -notmatch 'Transfer ZIP is missing application' -or
                (Test-Path -LiteralPath (Join-Path $noApp 'application'))) {
                throw 'A missing app did not leave a ready environment and show actionable instructions.'
            }
        }
        if ($scenario -eq 'wheels' -and $first -notmatch 'WHEELS AND NESTED IMPORTS SUCCESS') { throw 'Bundled wheels did not import.' }
        [IO.File]::AppendAllText((Join-Path $target 'application\__main__.py'),
            "`nprint('OFFLINE EDIT SUCCESS')`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $target 'output\new-file.txt'), 'new local file', $utf8)
        $edited = Invoke-Target $target 0
        if ($edited -notmatch 'Setup: SKIPPED' -or $edited -notmatch 'OFFLINE EDIT SUCCESS') {
            throw 'Editing application code required setup or did not run the edited code.'
        }
        if (Test-Path -LiteralPath (Join-Path $target 'data')) { throw 'START created an unnecessary data/ folder.' }
        if (Test-Path -LiteralPath (Join-Path $target '.portable-python\cache')) { throw 'Offline START retained a uv cache.' }
        if ($scenario -eq 'stdlib') {
            & (Join-Path $PSScriptRoot 'encoding.ps1') -Launcher (Join-Path $target 'portable-python.ps1') -Root $target -TestRoot $testRoot -Profile Preloaded
            & cmd.exe /d /c ('echo x|call "' + (Join-Path $target 'START.bat') + '"')
            if ($LASTEXITCODE -ne 0) { throw 'START.bat failed.' }
            $env:PORTABLE_TEST_EXIT = '1'
            if ((Invoke-Target $target 20) -notmatch 'Application exit code: 7') { throw 'Application exit code lost.' }
            $env:PORTABLE_TEST_EXIT = $null
            $cfg = Join-Path $target '.venv\pyvenv.cfg'
            $originalConfig = [IO.File]::ReadAllText($cfg)
            [IO.File]::WriteAllText($cfg, $originalConfig.Replace('include-system-site-packages = false', 'include-system-site-packages = true'), $utf8)
            if ((Invoke-Target $target 10) -notmatch 'pyvenv.cfg no longer points') { throw 'Changed isolation was not rejected.' }
            [IO.File]::WriteAllText($cfg, $originalConfig, $utf8)
        } else {
            $venv = Join-Path $target '.venv'
            $site = Join-Path $venv 'Lib\site-packages'
            $dist = Get-ChildItem -LiteralPath $site -Directory -Filter 'more_itertools-*.dist-info' | Select-Object -First 1
            [IO.Directory]::Move($dist.FullName, (Join-Path $testRoot 'missing-dist-info'))
            if ((Invoke-Target $target 10) -notmatch 'Installed package names or versions differ') {
                throw 'Missing package metadata was not rejected.'
            }
            [IO.File]::Delete((Join-Path $target '.portable-python\ready.state'))
            if ((Invoke-Target $target 10) -notmatch 'without a readiness marker') { throw 'Partial venv accepted.' }
            # Remove only our disposable test venv. START's recovery contract
            # is the same when a user has moved their venv outside the bundle.
            [IO.Directory]::Delete($venv, $true)
            $recovered = Invoke-Target $target 0
            if ($recovered -notmatch 'Setup: PERFORMED' -or $recovered -notmatch 'OFFLINE EDIT SUCCESS' -or
                $recovered -notmatch 'WHEELS AND NESTED IMPORTS SUCCESS' -or
                [IO.File]::ReadAllText((Join-Path $target 'output\new-file.txt')) -ne 'new local file') {
                throw 'Offline recovery failed or changed user data.'
            }

            $bad = Join-Path $testRoot 'damaged'
            [IO.Compression.ZipFile]::ExtractToDirectory($preparedZip, $bad)
            $unexpected = Join-Path $bad 'runtime\extra.txt'
            [IO.File]::WriteAllText($unexpected, 'unexpected runtime file', $utf8)
            if ((Invoke-Target $bad 10) -notmatch 'failed SHA-256 verification: runtime/extra.txt') {
                throw 'Unexpected files inside the protected runtime were accepted.'
            }
            [IO.File]::Delete($unexpected)
            $runtimeUv = Join-Path $bad 'runtime\uv.exe'
            $missing = Join-Path $testRoot 'missing-uv.exe'
            [IO.File]::Move($runtimeUv, $missing)
            if ((Invoke-Target $bad 10) -notmatch 'missing one or more declared files') {
                throw 'Missing payload file was not detected.'
            }
            [IO.File]::Move($missing, $runtimeUv)
            $wheel = Get-ChildItem -LiteralPath (Join-Path $bad 'wheelhouse') -Filter '*.whl' | Select-Object -First 1
            [IO.File]::AppendAllText($wheel.FullName, 'damaged', $utf8)
            if ((Invoke-Target $bad 10) -notmatch 'failed SHA-256 verification' -or
                (Test-Path -LiteralPath (Join-Path $bad '.venv'))) { throw 'Damaged wheel was not rejected before installation.' }
        }
        foreach ($folder in @('input', 'other [local]')) {
            if ([IO.File]::ReadAllText((Join-Path (Join-Path $target $folder) $unicodeFixture)) -ne "keep $folder") {
                throw "User data changed: $folder"
            }
        }
        $env:UV_INDEX = $null
        $env:UV_PYTHON_INSTALL_DIR = $null
        $env:UV_OFFLINE = $null
    }
} finally {
    try {
        if ($BlockNetwork) {
            Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction Stop
        }
    } finally {
        Complete-TestWorkspace -Path $testRoot
        if (Test-Path -LiteralPath $testRoot) { throw 'Test workspace remains.' }
    }
}
if ($ExportBundle) {
    Write-Host 'WINDOWS PRELOADED TEST PREPARATION: SUCCESS'
} else {
    Write-Host 'WINDOWS PRELOADED ACCEPTANCE: SUCCESS'
}
# The last child intentionally failed the damaged-wheel test. Do not let
# PowerShell's CI wrapper return that child's expected failure as ours.
exit 0
