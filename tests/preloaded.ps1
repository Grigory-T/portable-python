[CmdletBinding(DefaultParameterSetName='Starter')]
param(
    [Parameter(Mandatory=$true, ParameterSetName='Starter')][string]$Zip,
    [Parameter(ParameterSetName='Starter')][string]$ExportBundle,
    [Parameter(Mandatory=$true, ParameterSetName='Target')][string]$TargetBundle,
    [switch]$BlockNetwork
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
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

function New-PreparedTestZip([string]$Scenario) {
        $source = Join-Path $testRoot "$scenario online"
        [IO.Compression.ZipFile]::ExtractToDirectory($starterZip, $source)
        if ((Invoke-Target $source 10) -notmatch 'No prepared bundle found') {
            throw 'START on the starter did not give an actionable error.'
        }
        if ($scenario -eq 'wheels') {
            $project = Join-Path $source 'pyproject.toml'
            $requirements = @($pins.data.PSObject.Properties | ForEach-Object { "$($_.Name)==$($_.Value)" })
            $requirements += "colorama==0.4.6; sys_platform == 'win32'"
            $toml = [IO.File]::ReadAllText($project).Replace('dependencies = []',
                ('dependencies = ' + (ConvertTo-Json -InputObject $requirements -Compress)))
            [IO.File]::WriteAllText($project, $toml, $utf8)
            [IO.File]::WriteAllText((Join-Path $source 'application\__main__.py'), @'
from pathlib import Path
from importlib.metadata import version
from io import BytesIO
import sys
import tomllib
import colorama
import openpyxl
import polars as pl
import xlrd
import xlsxwriter
from python_calamine import CalamineWorkbook
from .nested.probe import value
from more_itertools import chunked
assert Path(sys._base_executable).resolve() == Path("runtime/python.exe").resolve()
assert sys.version_info[:3] == (3, 13, 18)
for requirement in tomllib.loads(Path('pyproject.toml').read_text(encoding='utf-8'))['project']['dependencies']:
    name, expected = requirement.split(';')[0].strip().split('==')
    assert version(name) == expected, name
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
print("WHEELS AND NESTED IMPORTS SUCCESS")
'@, $utf8)
            [IO.Directory]::CreateDirectory((Join-Path $source 'application\nested')) | Out-Null
            [IO.File]::WriteAllText((Join-Path $source 'application\nested\probe.py'), 'value = 42', $utf8)
        } else {
            [IO.File]::WriteAllText((Join-Path $source 'application\__main__.py'), @'
import os
from pathlib import Path
import sys

if os.getenv('PORTABLE_TEST_EXIT'):
    raise SystemExit(7)
assert Path('data').is_dir()
text = '\u0424\u043e\u0440\u043c\u0438\u0440\u043e\u0432\u0430\u043d\u0438\u0435 | \u0401\u0451 | \u20ac | \u65e5\u672c\u8a9e | \U0001f600'
print('UTF8_STDOUT|' + text)
print('UTF8_STDERR|' + text, file=sys.stderr)
print(text)
sys.stderr.write('\n\rUTF8_PROGRESS|' + text + '\n')
print('STDLIB APPLICATION SUCCESS')
'@, $utf8)
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
                    [IO.File]::ReadAllText((Join-Path $source 'setup.log')) -notmatch 'SHA-256 mismatch for uv-') {
                    throw 'A bad pinned SHA-256 did not fail closed with a setup.log entry.'
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
        $provenance = [IO.File]::ReadAllText((Join-Path $bundle 'provenance.json')) | ConvertFrom-Json
        $locked = Join-Path $bundle 'uv.lock'
        if ($provenance.uv_lock_sha256 -ne (Get-FileHash -LiteralPath $locked).Hash -or
            @($provenance.downloads | Where-Object { $_.url -notmatch '^https://' -or $_.sha256 -notmatch '^[a-f0-9]{64}$' }).Count) {
            throw 'Bundle provenance is incomplete or inconsistent.'
        }
        $wheels = @(Get-ChildItem -LiteralPath (Join-Path $bundle 'wheelhouse') -Filter '*.whl')
        if (@($provenance.downloads).Count -ne (4 + $wheels.Count)) {
            throw 'A downloaded artifact is missing from provenance.'
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
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $source 'prepare.ps1') | Out-Host
            if ($LASTEXITCODE -ne 0 -or (Get-FileHash -LiteralPath $manifestPath).Hash -ne $firstManifest) {
                throw 'Replaying the saved lock changed the prepared payload.'
            }
            $replayLog = [IO.File]::ReadAllText((Join-Path $source 'setup.log'))
            if ($replayLog -notmatch 'Using supplied uv.lock' -or $replayLog -match 'BEGIN: dependency_lock') {
                throw 'Replaying the saved lock silently resolved.'
            }
        }
        foreach ($forbidden in @('.venv', '.portable-python', '.prepare.lock', 'prepare.ps1', 'prepare.py', 'SETUP.bat', 'setup.log', 'data')) {
            if (Test-Path -LiteralPath (Join-Path $bundle $forbidden)) {
                throw "Prepared bundle includes unshippable content: $forbidden"
            }
        }
        $preparedZip = Join-Path $testRoot "$scenario prepared.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($bundle, $preparedZip)
        # Destroy the input before starting the target. Nothing on the target
        # can silently rely on the online directory or its prepared venv.
        [IO.Directory]::Delete($source, $true)
        return $preparedZip
}

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
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
        if ($BlockNetwork) {
            foreach ($exe in @('uv.exe', 'runtime\python.exe', '.venv\Scripts\python.exe')) {
                New-NetFirewallRule -DisplayName "Preloaded test: $exe" -Group $group -Direction Outbound -Action Block -Profile Any -Program (Join-Path $target $exe) | Out-Null
            }
            if (@(Get-NetFirewallRule -Group $group | Where-Object { $_.Enabled -eq 'True' -and $_.Action -eq 'Block' }).Count -lt 3) {
                throw 'Outbound firewall rules were not applied.'
            }
        }
        $env:UV_INDEX = 'https://invalid.invalid/simple'
        $env:UV_PYTHON_INSTALL_DIR = 'C:\not-the-portable-runtime'
        $env:UV_OFFLINE = 'false'
        $first = Invoke-Target $target 0
        if ($first -notmatch 'Setup: PERFORMED' -or $first -notmatch 'APPLICATION STATUS: SUCCESS') { throw 'Missing first-run success.' }
        if ($scenario -eq 'wheels' -and $first -notmatch 'WHEELS AND NESTED IMPORTS SUCCESS') { throw 'Bundled wheels did not import.' }
        if ((Invoke-Target $target 0) -notmatch 'Setup: SKIPPED') { throw 'Unchanged run did not skip setup.' }
        if (-not [IO.Directory]::Exists((Join-Path $target 'data'))) { throw 'START did not create data/.' }
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
            $data = [IO.Directory]::CreateDirectory((Join-Path $target 'data'))
            $output = Join-Path $data.FullName 'keep.txt'
            [IO.File]::WriteAllText($output, 'keep', $utf8)
            $recovered = Invoke-Target $target 0
            if ($recovered -notmatch 'Setup: PERFORMED' -or $recovered -notmatch 'WHEELS AND NESTED IMPORTS SUCCESS' -or
                [IO.File]::ReadAllText($output) -ne 'keep') { throw 'Offline recovery failed or changed user data.' }

            $bad = Join-Path $testRoot 'damaged'
            [IO.Compression.ZipFile]::ExtractToDirectory($preparedZip, $bad)
            $wheel = Get-ChildItem -LiteralPath (Join-Path $bad 'wheelhouse') -Filter '*.whl' | Select-Object -First 1
            [IO.File]::AppendAllText($wheel.FullName, 'damaged', $utf8)
            if ((Invoke-Target $bad 10) -notmatch 'failed SHA-256 verification' -or
                (Test-Path -LiteralPath (Join-Path $bad '.venv'))) { throw 'Damaged wheel was not rejected before installation.' }
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
