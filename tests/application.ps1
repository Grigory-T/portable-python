param([Parameter(Mandatory=$true)][string]$Zip, [switch]$Audit, [switch]$BlockNetwork, [switch]$KeepWorkspace)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'workspace.ps1')
$testRoot = New-TestWorkspace 'application'
$firewallGroup = 'Portable Python application acceptance ' + [guid]::NewGuid().ToString('N')
try {
$folderName = -join ([char[]]@(0x0075,0x006e,0x0069,0x0063,0x006f,0x0064,0x0065,0x002d,0x00e9))
$root = Join-Path $testRoot ($folderName + ' [literal]')
New-Item -ItemType Directory -Path $root -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory((Get-Item -LiteralPath $Zip).FullName, $root)
$env:UV_INDEX = 'https://invalid.invalid/simple'
$env:SSL_CERT_FILE = 'C:\invalid-portable-test\ca.pem'
$env:SSL_CERT_DIR = 'C:\invalid-portable-test\certs'

function Invoke-Profile([int]$Expected) {
    $script:lastOutput = ''
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'portable-python.ps1') -NoPause 2>&1 | ForEach-Object {
            $script:lastOutput += [string]$_ + "`n"
            Write-Host ([string]$_)
        }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($code -ne $Expected) { throw "Expected $Expected, got $code" }
}

Invoke-Profile 0
if ($lastOutput -notmatch 'Setup:\s+PERFORMED' -or $lastOutput -notmatch 'APPLICATION RESULT') { throw 'First START did not prepare and run' }
& (Join-Path $PSScriptRoot 'encoding.ps1') -Launcher (Join-Path $root 'portable-python.ps1') -Root $root -TestRoot $testRoot -Profile Application
# Infrastructure checks must not import project-root startup hooks.
$marker = Join-Path $root 'unexpected-startup.txt'
[IO.File]::WriteAllText((Join-Path $root 'sitecustomize.py'), "from pathlib import Path`nPath(" + "'" + $marker.Replace('\', '/') + "'" + ").write_text('unexpected')", $utf8)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'portable-python.ps1') -SetupOnly -NoPause
if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $marker)) { throw 'Infrastructure ran a project startup hook' }
[IO.File]::Delete((Join-Path $root 'sitecustomize.py'))
Invoke-Profile 0
if ($lastOutput -notmatch 'Setup:\s+SKIPPED') { throw 'Recurring start did not skip setup' }
$main = Join-Path $root 'application\__main__.py'
$originalMain = [IO.File]::ReadAllBytes($main)
New-Item -ItemType Directory -Path (Join-Path $root 'application\nested') | Out-Null
[IO.File]::WriteAllText((Join-Path $root 'application\nested\__init__.py'), '', $utf8)
[IO.File]::WriteAllText((Join-Path $root 'application\nested\probe.py'), 'VALUE=42', $utf8)
[IO.File]::WriteAllText($main, "import os`nassert 'SSL_CERT_FILE' not in os.environ and 'SSL_CERT_DIR' not in os.environ`nfrom .nested.probe import VALUE`nfrom application.nested.probe import VALUE as OTHER`nassert VALUE==OTHER==42`nprint('NESTED IMPORTS SUCCESS')", $utf8)
Invoke-Profile 0
if ($lastOutput -notmatch 'NESTED IMPORTS SUCCESS') { throw 'Nested imports failed' }
[IO.File]::WriteAllText($main, 'raise SystemExit(7)', $utf8)
Invoke-Profile 20
if ($lastOutput -notmatch 'Application exit code:\s+7') { throw 'Child exit code lost' }
[IO.File]::WriteAllBytes($main, $originalMain)
$project = Join-Path $root 'pyproject.toml'
$originalProject = [IO.File]::ReadAllBytes($project)
[IO.File]::AppendAllText($project, "`n# changed`n", $utf8)
Invoke-Profile 10
if ($lastOutput -match 'APPLICATION RUN') { throw 'Application started with changed configuration' }
[IO.File]::WriteAllBytes($project, $originalProject)

# Test the actual user wrapper; the pause gets its input from the pipe.
& cmd.exe /d /c ('echo x|call "' + (Join-Path $root 'START.bat') + '"')
if ($LASTEXITCODE -ne 0) { throw 'START.bat failed' }
$venvPython = Join-Path $root '.venv\Scripts\python.exe'
& $venvPython -I -c "import importlib.util,site,sys; assert sys.version_info[:3]==(3,15,2); assert not site.ENABLE_USER_SITE; assert importlib.util.find_spec('jupyterlab') is None; assert importlib.util.find_spec('matplotlib') is None"
if ($LASTEXITCODE -ne 0) { throw 'Unexpected runtime/default libraries' }
$log = [IO.File]::ReadAllText((Join-Path $root '.portable-python\portable-python.log'))
if ($log.IndexOf($env:USERNAME, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'Identity in journal' }

# Cold install with native Windows x64 wheels for the application fixture.
$root = Join-Path $testRoot 'selected-library'
New-Item -ItemType Directory -Path $root | Out-Null
[System.IO.Compression.ZipFile]::ExtractToDirectory((Get-Item -LiteralPath $Zip).FullName, $root)
$project = Join-Path $root 'pyproject.toml'
$requirements = @('polars==2.2.0', 'python-calamine==0.9.1', 'xlsxwriter==3.3.4',
    'openpyxl==3.1.5', 'xlrd==2.0.2', 'more-itertools==11.2.1')
$text = [IO.File]::ReadAllText($project).Replace('dependencies = []',
    ('dependencies = ' + (ConvertTo-Json -InputObject $requirements -Compress)))
[IO.File]::WriteAllText($project, $text, $utf8)
$fixture = @'
from io import BytesIO
from pathlib import Path
from importlib.metadata import version
from more_itertools import chunked
from python_calamine import CalamineWorkbook
import openpyxl
import polars
import xlrd
import xlsxwriter

assert version('polars-runtime-32') == '2.2.0'
assert version('et-xmlfile') == '2.0.0'
assert all(Path(folder).is_dir() for folder in ('input', 'output', 'workings'))
assert polars.DataFrame({'value': [1, 2, 3]})['value'].sum() == 6
assert list(chunked(range(3), 2)) == [[0, 1], [2]]
stream = BytesIO()
with xlsxwriter.Workbook(stream, {'in_memory': True}) as writer:
    writer.add_worksheet('Check').write('A1', 42)
stream.seek(0)
assert CalamineWorkbook.from_filelike(stream).get_sheet_by_name('Check').to_python() == [[42]]
stream.seek(0)
workbook = openpyxl.load_workbook(stream, read_only=True)
try:
    assert workbook['Check']['A1'].value == 42
finally:
    workbook.close()
print('SELECTED LIBRARY SUCCESS')
'@
foreach ($folder in @('input', 'output', 'workings')) {
    [IO.Directory]::CreateDirectory((Join-Path $root $folder)) | Out-Null
}
[IO.File]::WriteAllText((Join-Path $root 'application\__main__.py'), $fixture, $utf8)
Invoke-Profile 0
if ($lastOutput -notmatch 'SELECTED LIBRARY SUCCESS') { throw 'Selected library failed' }
if ($Audit) {
    $env:SSL_CERT_FILE = $null
    $env:SSL_CERT_DIR = $null
    & (Join-Path $root '.venv\Scripts\python.exe') -I (Join-Path $PSScriptRoot '..\scripts\audit.py')
    if ($LASTEXITCODE -ne 0) { throw 'Advisory check failed' }
}

# Optional developer lock: use an already installed uv/Python without running
# START or the app in the developer folder. Only TOML and the lock are shipped.
$developer = [IO.Directory]::CreateDirectory((Join-Path $testRoot 'developer')).FullName
[IO.File]::WriteAllText((Join-Path $developer 'pyproject.toml'), $text, $utf8)
$developerUv = Join-Path $root '.portable-python\uv.exe'
$developerPython = Join-Path $root '.portable-python\python\cpython-3.15.2-windows-x86_64-none\python.exe'
$developerCache = Join-Path $testRoot 'developer-cache'
$originalIndex = $env:UV_INDEX
$originalCertFile = $env:SSL_CERT_FILE
$originalCertDir = $env:SSL_CERT_DIR
try {
    $env:UV_INDEX = $null
    $env:SSL_CERT_FILE = $null
    $env:SSL_CERT_DIR = $null
    & $developerUv --no-config --no-python-downloads --system-certs --cache-dir $developerCache lock --project $developer --python $developerPython --no-build --no-sources --default-index https://pypi.org/simple
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath (Join-Path $developer '.venv'))) {
        throw 'Developer lock must resolve successfully without creating a project venv.'
    }
} finally {
    $env:UV_INDEX = $originalIndex
    $env:SSL_CERT_FILE = $originalCertFile
    $env:SSL_CERT_DIR = $originalCertDir
}
$sourceLock = Join-Path $developer 'uv.lock'
$expectedHash = (Get-FileHash -LiteralPath $sourceLock).Hash
$root = Join-Path $testRoot 'locked-replay'
[System.IO.Compression.ZipFile]::ExtractToDirectory((Get-Item -LiteralPath $Zip).FullName, $root)
$lockPath = Join-Path $root 'uv.lock'
$project = Join-Path $root 'pyproject.toml'
[IO.File]::Copy($sourceLock, $lockPath)
[IO.File]::WriteAllText((Join-Path $root 'application\__main__.py'), $fixture, $utf8)
foreach ($folder in @('input', 'output', 'workings')) {
    [IO.Directory]::CreateDirectory((Join-Path $root $folder)) | Out-Null
}

# The unchanged starter TOML has no dependencies, so the supplied lock is stale.
Invoke-Profile 10
if ($lastOutput -notmatch 'Using existing uv.lock' -or $lastOutput -match 'APPLICATION RUN|\[dependency_lock\]' -or
    (Get-FileHash -LiteralPath $lockPath).Hash -ne $expectedHash) {
    throw 'A stale supplied lock was replaced or allowed to run.'
}
[IO.File]::WriteAllText($project, $text, $utf8)
Invoke-Profile 0
if ($lastOutput -notmatch 'Using existing uv.lock' -or $lastOutput -notmatch 'SELECTED LIBRARY SUCCESS' -or
    $lastOutput -match '\[dependency_lock\]' -or (Get-FileHash -LiteralPath $lockPath).Hash -ne $expectedHash) {
    throw 'Fresh target did not replay the supplied lock unchanged.'
}

[IO.Directory]::Move((Join-Path $root '.venv'), (Join-Path $testRoot 'old-venv'))
Invoke-Profile 0
if ($lastOutput -notmatch 'Setup:\s+PERFORMED' -or $lastOutput -notmatch 'SELECTED LIBRARY SUCCESS' -or
    $lastOutput -match '\[dependency_lock\]' -or (Get-FileHash -LiteralPath $lockPath).Hash -ne $expectedHash) {
    throw 'Target rebuild did not preserve its lock.'
}

if ($BlockNetwork) {
    foreach ($exe in @('.portable-python\uv.exe', '.venv\Scripts\python.exe',
        '.portable-python\python\cpython-3.15.2-windows-x86_64-none\python.exe')) {
        New-NetFirewallRule -DisplayName "Application test: $exe" -Group $firewallGroup -Direction Outbound -Action Block -Profile Any -Program (Join-Path $root $exe) | Out-Null
    }
}
Invoke-Profile 0
if ($lastOutput -notmatch 'Setup:\s+SKIPPED' -or $lastOutput -notmatch 'SELECTED LIBRARY SUCCESS') {
    throw 'An unchanged start did not run from the installed environment.'
}
} finally {
    try {
        if ($BlockNetwork) {
            Get-NetFirewallRule -Group $firewallGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction Stop
        }
    } finally {
        Complete-TestWorkspace -Path $testRoot -KeepWorkspace:$KeepWorkspace
    }
}
Write-Host 'WINDOWS ONE-LAUNCHER ACCEPTANCE: SUCCESS'
