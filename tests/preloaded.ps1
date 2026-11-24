param([Parameter(Mandatory=$true)][string]$Zip, [switch]$BlockNetwork)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'workspace.ps1')
$starterZip = (Get-Item -LiteralPath $Zip).FullName
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

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($scenario in @('stdlib', 'wheels')) {
        $source = Join-Path $testRoot "$scenario online"
        [IO.Compression.ZipFile]::ExtractToDirectory($starterZip, $source)
        if ((Invoke-Target $source 10) -notmatch 'No prepared bundle found') {
            throw 'START on the starter did not give an actionable error.'
        }
        if ($scenario -eq 'wheels') {
            $project = Join-Path $source 'pyproject.toml'
            $toml = [IO.File]::ReadAllText($project).Replace('dependencies = []', @'
dependencies = [
    "more-itertools==11.1.0",
    "numpy==2.5.2",
    "openpyxl>=3.1,<4",
    "colorama==0.4.6; sys_platform == 'win32'",
]
'@)
            [IO.File]::WriteAllText($project, $toml, $utf8)
            [IO.File]::WriteAllText((Join-Path $source 'application\__main__.py'), @'
from pathlib import Path
import sys
import colorama
import numpy
import openpyxl
from .nested.probe import value
from more_itertools import chunked
assert Path(sys._base_executable).resolve() == Path("runtime/python.exe").resolve()
assert sum(numpy.arange(5)) == 10
assert openpyxl.Workbook().active.title == "Sheet"
assert list(chunked(range(5), 3)) == [[0, 1, 2], [3, 4]]
assert value == 42
print("WHEELS AND NESTED IMPORTS SUCCESS")
'@, $utf8)
            [IO.Directory]::CreateDirectory((Join-Path $source 'application\nested')) | Out-Null
            [IO.File]::WriteAllText((Join-Path $source 'application\nested\probe.py'), 'value = 42', $utf8)
        } else {
            [IO.File]::WriteAllText((Join-Path $source 'application\__main__.py'), @'
import os
if os.getenv('PORTABLE_TEST_EXIT'):
    raise SystemExit(7)
print('STDLIB APPLICATION SUCCESS')
'@, $utf8)
        }
        # Use the actual setup wrapper in the default scenario.
        if ($scenario -eq 'stdlib') {
            & cmd.exe /d /c ('echo x|call "' + (Join-Path $source 'SETUP.bat') + '"')
        } else {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $source 'prepare.ps1')
        }
        if ($LASTEXITCODE -ne 0) { throw 'Online preparation failed.' }
        if (@(Get-ChildItem -LiteralPath $source -Directory -Force -Filter '.prepare-*').Count) {
            throw 'Online preparation left scratch work.'
        }
        $bundle = Join-Path $source 'bundle'
        foreach ($forbidden in @('.venv', '.portable-python', 'prepare.ps1', 'prepare.py', 'SETUP.bat')) {
            if (Test-Path -LiteralPath (Join-Path $bundle $forbidden)) {
                throw "Prepared bundle includes unshippable content: $forbidden"
            }
        }
        $preparedZip = Join-Path $testRoot "$scenario prepared.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($bundle, $preparedZip)
        # Destroy the input before starting the target. Nothing on the target
        # can silently rely on the online directory or its prepared venv.
        [IO.Directory]::Delete($source, $true)
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
        if (Test-Path -LiteralPath (Join-Path $target '.portable-python\cache')) { throw 'Offline START retained a uv cache.' }
        if ($scenario -eq 'stdlib') {
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
            # Follow the documented non-destructive recovery, preserving data.
            [IO.Directory]::Move($venv, (Join-Path $testRoot 'quarantined-venv'))
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
Write-Host 'WINDOWS PRELOADED ACCEPTANCE: SUCCESS'
# The last child intentionally failed the damaged-wheel test. Do not let
# PowerShell's CI wrapper return that child's expected failure as ours.
exit 0
