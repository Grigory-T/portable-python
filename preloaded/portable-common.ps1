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

function Read-Pins([string]$Path) {
    Assert-NotLinked (Get-Item -LiteralPath $Path -Force)
    $text = [IO.File]::ReadAllText($Path, $Utf8)
    $pins = @{}
    foreach ($entry in @(
        @('project', 'requires-python', '==(?<value>3\.(?:11|12|13|14)\.\d+)'),
        @('tool.uv', 'required-version', '==(?<value>\d+\.\d+\.\d+)'),
        @('tool.portable-python', 'uv-archive-sha256', '(?<value>[0-9a-fA-F]{64})'),
        @('tool.portable-python', 'uv-exe-sha256', '(?<value>[0-9a-fA-F]{64})')
    )) {
        $section, $key, $pattern = $entry
        $tables = [regex]::Matches($text, '(?ms)^[ \t]*\[' + [regex]::Escape($section) + '\][ \t]*(?:#[^\r\n]*)?\r?\n(?<body>.*?)(?=^[ \t]*\[|\z)')
        if ($tables.Count -ne 1) { throw "Expected one [$section] table in pyproject.toml." }
        $matched = [regex]::Matches($tables[0].Groups['body'].Value, '(?m)^[ \t]*' + [regex]::Escape($key) + '[ \t]*=[ \t]*"' + $pattern + '"[ \t]*(?:#[^\r\n]*)?\r?$')
        if ($matched.Count -ne 1) { throw "Invalid exact $section.$key pin in pyproject.toml." }
        $pins[$key] = $matched[0].Groups['value'].Value.ToLowerInvariant()
    }
    if ([version]$pins['required-version'] -lt [version]'0.13.6') {
        throw 'uv must be at least 0.13.6.'
    }
    return $pins
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
    foreach ($directory in @($env:TEMP, $env:UV_CACHE_DIR)) {
        $item = [IO.Directory]::CreateDirectory($directory)
        Assert-NotLinked $item
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
    $uv = Join-Path $Bundle 'uv.exe'
    $runtime = Join-Path $Bundle 'runtime\python.exe'
    $requirements = Join-Path $Bundle 'install-plan.txt'
    $wheels = Join-Path $Bundle 'wheelhouse'
    # No target resolver, indexes, Python downloads, source builds, or external
    # caches. All binaries come from the verified bundle. Copy, never link.
    $flags = @('--offline', '--no-config', '--no-python-downloads')
    Invoke-Checked 'venv_create' $uv ($flags + @('venv', '--python', $runtime, $Venv))
    $python = Join-Path $Venv 'Scripts\python.exe'
    $links = if ([IO.Directory]::Exists($wheels)) { @('--find-links', $wheels) } else { @() }
    Invoke-Checked 'offline_wheel_install' $uv ($flags + @(
        'pip', 'sync', '--python', $python, '--no-index', '--require-hashes',
        '--no-build', '--allow-empty-requirements',
        '--link-mode', 'copy'
    ) + $links + @($requirements))
    Invoke-Checked 'dependency_check' $uv ($flags + @('pip', 'check', '--python', $python))
}

function Confirm-Interpreter([string]$Python, [string]$Version, [string]$Base, [string]$Venv) {
    Invoke-Checked 'runtime_check' $Python @(
        '-I', '-S', '-B', '-X', 'utf8', '-c',
        "import pathlib,sys; p=pathlib.Path; assert sys.implementation.name=='cpython'; assert '.'.join(map(str,sys.version_info[:3]))==sys.argv[1]; assert p(sys._base_executable).resolve()==p(sys.argv[2]).resolve(); assert p(sys.executable).parent.parent.resolve()==p(sys.argv[3]).resolve(); print('Verified project-local CPython ' + sys.argv[1])",
        $Version, $Base, $Venv
    )
}
