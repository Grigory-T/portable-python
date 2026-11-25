# Shared by the online preparer and the offline launcher. No network code here.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Assert-LocalWindows([string]$Path) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        -not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw 'Use 64-bit Windows PowerShell on Windows 11 x86-64.'
    }
    # Leave room for legacy PowerShell/.NET and Windows ZIP tools. Native
    # packages can still have deeply nested paths: prefer a short drive path.
    if ($Path.Length -gt 125) {
        throw 'Folder path is too long for reliable setup. Extract into a short local path (125 characters maximum), e.g. C:\apps\portable.'
    }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path))
    if ($drive.DriveType -ne [IO.DriveType]::Fixed) { throw 'Use a local fixed-drive folder.' }
    $parent = Get-Item -LiteralPath $Path -Force
    while ($null -ne $parent) {
        Assert-NotLinked $parent
        $parent = $parent.Parent
    }
}

function Assert-NotLinked($Item) {
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Linked files and directories are not supported.'
    }
}

function Open-WorkspaceLock([string]$Path) {
    if (Test-Path -LiteralPath $Path) { Assert-NotLinked (Get-Item -LiteralPath $Path -Force) }
    try {
        return [IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'None')
    } catch [IO.IOException] {
        throw 'Workspace lock is unavailable. Check for another SETUP or START in this folder.'
    }
}

function Get-TreeFiles([string]$Directory) {
    # Inspect each entry before descending, including hidden files.
    foreach ($item in (Get-ChildItem -LiteralPath $Directory -Force)) {
        Assert-NotLinked $item
        if ($item.PSIsContainer) { Get-TreeFiles $item.FullName } else { $item }
    }
}

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Set-LocalEnvironment([string]$Work) {
    foreach ($name in (Get-ChildItem Env:).Name) {
        if ($name -match '^(UV_|PYTHON|SSL_CERT_(FILE|DIR)$|VIRTUAL_ENV$|CONDA_PREFIX$)') {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }
    $env:UV_CACHE_DIR = Join-Path $Work 'cache'
    $env:TEMP = Join-Path $Work 'temp'
    $env:TMP = $env:TEMP
    Assert-NotLinked ([IO.Directory]::CreateDirectory($env:TEMP))
    if (Test-Path -LiteralPath $env:UV_CACHE_DIR) {
        Assert-NotLinked (Get-Item -LiteralPath $env:UV_CACHE_DIR -Force)
    }
}

function Show-Line([object]$Line) {
    # PowerShell 5.1 wraps native stderr, including empty progress lines.
    $message = if ($Line -is [System.Management.Automation.ErrorRecord]) { $Line.Exception.Message } else { [string]$Line }
    Write-Host ([regex]::Replace([string]$message, '[\x00-\x08\x0B-\x1F\x7F-\x9F]', ''))
}

function Invoke-Native([string]$Phase, [string]$Exe, [string[]]$Arguments) {
    Write-Host "[$Phase]"
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Exe @Arguments 2>&1 | ForEach-Object { Show-Line $_ }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [int]$code
}

function Invoke-Checked([string]$Phase, [string]$Exe, [string[]]$Arguments) {
    $code = Invoke-Native $Phase $Exe $Arguments
    if ($code -ne 0) { throw "$Phase failed with exit code $code." }
}

function Initialize-OfflineVenv([string]$Bundle, [string]$Venv) {
    $runtime = Join-Path $Bundle 'runtime'
    $uv = Join-Path $runtime 'uv.exe'
    $requirements = Join-Path $Bundle 'install-plan.txt'
    $wheels = Join-Path $Bundle 'wheelhouse'
    # uv selects local wheels for the locked versions; it cannot use a
    # network index, download Python, build sources or keep a persistent cache.
    $flags = @('--offline', '--no-config', '--no-python-downloads', '--no-cache')
    Push-Location -LiteralPath $runtime
    try {
        Invoke-Checked 'venv_create' $uv ($flags + @('venv', '--no-project', '--python', (Join-Path $runtime 'python.exe'), $Venv))
        $python = Join-Path $Venv 'Scripts\python.exe'
        $links = if ([IO.Directory]::Exists($wheels)) { @('--find-links', $wheels) } else { @() }
        Invoke-Checked 'offline_wheel_install' $uv ($flags + @(
            'pip', 'sync', '--python', $python, '--no-index', '--require-hashes',
            '--no-build', '--allow-empty-requirements',
            '--link-mode', 'copy'
        ) + $links + @($requirements))
        Invoke-Checked 'dependency_check' $uv ($flags + @('pip', 'check', '--python', $python))
    } finally { Pop-Location }
}

function Read-EnvironmentPackages([string]$Venv, [string]$Version, [string]$Base) {
    $scripts = Join-Path $Venv 'Scripts'
    $python = Join-Path $scripts 'python.exe'
    $config = Join-Path $Venv 'pyvenv.cfg'
    foreach ($path in @($Venv, $scripts, $python, $config)) {
        Assert-NotLinked (Get-Item -LiteralPath $path -Force)
    }
    $cfg = [IO.File]::ReadAllText($config, $Utf8)
    $runtimePathSetting = [regex]::Matches($cfg, '(?im)^home[ \t]*=[ \t]*(.+?)\r?$')
    $site = [regex]::Matches($cfg, '(?im)^include-system-site-packages[ \t]*=[ \t]*(.+?)\r?$')
    if ($runtimePathSetting.Count -ne 1 -or
        $runtimePathSetting[0].Groups[1].Value.Trim() -ne [IO.Path]::GetDirectoryName($Base) -or
        $site.Count -ne 1 -or $site[0].Groups[1].Value.Trim() -ne 'false') {
        throw 'pyvenv.cfg no longer points to the isolated bundled runtime.'
    }
    # Inspect local metadata without imports or executing site/.pth hooks.
    $probe = @'
from importlib.metadata import distributions
from pathlib import Path
import sys

venv = Path(sys.argv[3]).resolve()
assert sys.implementation.name == 'cpython'
assert '.'.join(map(str, sys.version_info[:3])) == sys.argv[1]
assert Path(sys._base_executable).resolve() == Path(sys.argv[2]).resolve()
assert Path(sys.executable).parent.parent.resolve() == venv
for dist in sorted('{}=={}'.format(p.metadata['Name'], p.version) for p in distributions(path=[venv / 'Lib' / 'site-packages'])):
    print(dist)
'@
    # Single-quote-only Python source works with PS 5.1 native argument quoting.
    $packages = & $python -I -S -B -X utf8 -c $probe $Version $Base $Venv
    if ($LASTEXITCODE -ne 0) { throw 'Project-local Python check failed.' }
    return $packages
}
