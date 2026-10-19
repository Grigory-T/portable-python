param([Parameter(Mandatory=$true)][string]$Zip)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$testRoot = Join-Path $env:TEMP ('portable-app acceptance (' + [guid]::NewGuid().ToString('N') + ')')
$folderName = -join ([char[]]@(0x0075,0x006e,0x0069,0x0063,0x006f,0x0064,0x0065,0x002d,0x00e9))
$root = Join-Path $testRoot $folderName
New-Item -ItemType Directory -Path $root -Force | Out-Null
Expand-Archive -LiteralPath $Zip -DestinationPath $root
$env:UV_INDEX = 'https://invalid.invalid/simple'

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
Invoke-Profile 0
if ($lastOutput -notmatch 'Setup:\s+SKIPPED') { throw 'Recurring start did not skip setup' }
$main = Join-Path $root 'application\__main__.py'
$originalMain = [IO.File]::ReadAllBytes($main)
New-Item -ItemType Directory -Path (Join-Path $root 'application\nested') | Out-Null
[IO.File]::WriteAllText((Join-Path $root 'application\nested\__init__.py'), '', $utf8)
[IO.File]::WriteAllText((Join-Path $root 'application\nested\probe.py'), 'VALUE=42', $utf8)
[IO.File]::WriteAllText($main, "from .nested.probe import VALUE`nfrom application.nested.probe import VALUE as OTHER`nassert VALUE==OTHER==42`nprint('NESTED IMPORTS SUCCESS')", $utf8)
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
& $venvPython -I -c "import importlib.util,site,sys; assert sys.version_info[:3]==(3,13,16); assert not site.ENABLE_USER_SITE; assert importlib.util.find_spec('jupyterlab') is None; assert importlib.util.find_spec('matplotlib') is None"
if ($LASTEXITCODE -ne 0) { throw 'Unexpected runtime/default libraries' }
$log = [IO.File]::ReadAllText((Join-Path $root '.portable-python\portable-python.log'))
if ($log.IndexOf($env:USERNAME, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'Identity in journal' }

# One extra small library in a fresh project proves dynamic requirement ranges.
$root = Join-Path $testRoot 'selected-library'
New-Item -ItemType Directory -Path $root | Out-Null
Expand-Archive -LiteralPath $Zip -DestinationPath $root
$project = Join-Path $root 'pyproject.toml'
$text = [IO.File]::ReadAllText($project).Replace('dependencies = []', 'dependencies = ["more-itertools>=11,<12"]')
[IO.File]::WriteAllText($project, $text, $utf8)
[IO.File]::WriteAllText((Join-Path $root 'application\__main__.py'), "import more_itertools`nassert list(more_itertools.chunked(range(3),2))==[[0,1],[2]]`nprint('SELECTED LIBRARY SUCCESS')", $utf8)
Invoke-Profile 0
if ($lastOutput -notmatch 'SELECTED LIBRARY SUCCESS') { throw 'Selected library failed' }
Write-Host 'WINDOWS ONE-LAUNCHER ACCEPTANCE: SUCCESS'
Write-Host "Retained test workspace: $testRoot"
