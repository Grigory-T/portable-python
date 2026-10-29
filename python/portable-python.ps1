[CmdletBinding()]
param(
    [switch]$SetupOnly,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-StrictMode -Version 2.0

$Mode = if ($SetupOnly) { "Setup" } else { "Start" }
$ProfileSchema = "application-public-2"
$UvVersion = "unknown"
$UvArchiveUrl = ""
$UvArchiveSha256 = ""
$UvExeSha256 = ""
$PyPiIndex = "https://pypi.org/simple"
$ApplicationModule = "application"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PyprojectPath = Join-Path $Root "pyproject.toml"
$ApplicationRoot = Join-Path $Root "application"
$LockPath = Join-Path $Root "uv.lock"
$VenvRoot = Join-Path $Root ".venv"
$VenvPython = Join-Path $VenvRoot "Scripts\python.exe"
$StateRoot = Join-Path $Root ".portable-python"
$UvExe = Join-Path $StateRoot "uv.exe"
$UvCache = Join-Path $StateRoot "cache"
$RuntimeRoot = Join-Path $StateRoot "python"
$RuntimeBin = Join-Path $StateRoot "python-bin"
$ReadyMarker = Join-Path $StateRoot "ready.state"
$LogPath = Join-Path $StateRoot "portable-python.log"
$LocalRootApproved = $false
$WorkspaceLock = $null
$LocalTemp = Join-Path $StateRoot "temp"

function ConvertTo-NeutralText([string]$Text) {
    # Upstream messages must not inject terminal controls or expose URL credentials.
    $Text = [regex]::Replace($Text, '[\x00-\x08\x0B-\x1F\x7F-\x9F]', '')
    $Text = [regex]::Replace($Text, '(?i)(https?://)[^\s/@]+@', '$1<redacted>@')
    foreach ($privatePath in @($Root, $env:USERPROFILE, $env:TEMP, $env:TMP)) {
        if ($privatePath) {
            $Text = [regex]::Replace($Text, [regex]::Escape($privatePath), "<local>", "IgnoreCase")
            $Text = [regex]::Replace($Text, [regex]::Escape($privatePath.Replace('\', '/')), "<local>", "IgnoreCase")
        }
    }
    foreach ($identity in @($env:USERNAME)) {
        if ($identity) {
            $Text = [regex]::Replace($Text, '\b' + [regex]::Escape($identity) + '\b', "<local>", "IgnoreCase")
        }
    }
    return $Text
}

# Bootstrap only needs four quoted scalar values before Python/tomllib exists.
function Get-QuotedSetting([string]$Section, [string]$Key) {
    $text = Get-Content -LiteralPath $PyprojectPath -Raw -Encoding UTF8
    $tables = [regex]::Matches($text, '(?ms)^[ \t]*\[' + [regex]::Escape($Section) + '\][ \t]*(?:#[^\r\n]*)?\r?\n(?<body>.*?)(?=^[ \t]*\[|\z)')
    if ($tables.Count -ne 1) { throw "Expected one [$Section] table in pyproject.toml." }
    $values = [regex]::Matches($tables[0].Groups['body'].Value, '(?m)^[ \t]*' + [regex]::Escape($Key) + '[ \t]*=[ \t]*"(?<value>[^"\r\n]+)"[ \t]*(?:#[^\r\n]*)?\r?$')
    if ($values.Count -ne 1) { throw "Expected one quoted $Section.$Key setting in pyproject.toml." }
    return $values[0].Groups['value'].Value
}

function Read-BootstrapSettings {
    $requiredUv = Get-QuotedSetting "tool.uv" "required-version"
    if ($requiredUv -notmatch '^==(?<version>\d+\.\d+\.\d+)$') {
        throw 'tool.uv.required-version must be exactly "==x.y.z".'
    }
    $script:UvVersion = $Matches['version']
    if ([version]$UvVersion -lt [version]'0.13.6') {
        throw 'uv must be at least 0.13.6 (reviewed security baseline).'
    }
    $script:UvArchiveSha256 = (Get-QuotedSetting "tool.portable-python" "uv-archive-sha256").ToLowerInvariant()
    $script:UvExeSha256 = (Get-QuotedSetting "tool.portable-python" "uv-exe-sha256").ToLowerInvariant()
    foreach ($hash in @($UvArchiveSha256, $UvExeSha256)) {
        if ($hash -notmatch '^[a-f0-9]{64}$') { throw 'uv SHA-256 pins must contain 64 hexadecimal characters.' }
    }
    $script:UvArchiveUrl = "https://releases.astral.sh/github/uv/releases/download/$UvVersion/uv-x86_64-pc-windows-msvc.zip"
}

function Set-PortableEnvironment {
    # Prevent inherited uv mirrors, indexes, or environment selection overriding this profile.
    Get-ChildItem Env: | Where-Object { $_.Name -like 'UV_*' } | ForEach-Object {
        [Environment]::SetEnvironmentVariable($_.Name, $null, 'Process')
    }
    $env:UV_CACHE_DIR = $UvCache
    $env:UV_PROJECT_ENVIRONMENT = $VenvRoot
    $env:UV_PYTHON_INSTALL_DIR = $RuntimeRoot
    $env:UV_PYTHON_BIN_DIR = $RuntimeBin
    # This profile deliberately trusts the Windows certificate store only.
    $env:SSL_CERT_FILE = $null
    $env:SSL_CERT_DIR = $null
    $env:PYTHONPATH = $null
    $env:PYTHONHOME = $null
    $env:PYTHONNOUSERSITE = "1"
    $env:PYTHONDONTWRITEBYTECODE = "1"
    $env:TEMP = $LocalTemp
    $env:TMP = $LocalTemp
}

function Get-Sha256([string]$Path) {
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $algorithm.Dispose()
    }
}

function Write-PortableLog(
    [string]$Phase,
    [string]$Event,
    [string]$Status,
    [string]$Detail
) {
    if (-not $LocalRootApproved) { return }
    try {
        if (-not (Test-Path -LiteralPath $StateRoot -PathType Container)) {
            [System.IO.Directory]::CreateDirectory($StateRoot) | Out-Null
        }
        $record = [ordered]@{
            timestamp = [DateTime]::UtcNow.ToString("o")
            phase = $Phase
            event = $Event
            status = $Status
            detail = (ConvertTo-NeutralText $Detail)
        }
        Add-Content -LiteralPath $LogPath -Value ($record | ConvertTo-Json -Compress) -Encoding UTF8
    } catch {
        # Logging is diagnostic and must not replace the real failure.
    }
}

function Confirm-LocalFixedDrive([string]$Path) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith("\\")) {
        throw "Copy and extract the project locally before starting it; UNC paths are not supported."
    }
    $driveRoot = [System.IO.Path]::GetPathRoot($fullPath)
    $drive = New-Object System.IO.DriveInfo($driveRoot)
    if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
        throw "The project must run from a local fixed drive, not $driveRoot ($($drive.DriveType))."
    }
    $ancestor = Get-Item -LiteralPath $fullPath
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Use a real local directory, not a junction or symbolic link."
        }
        $ancestor = $ancestor.Parent
    }
}

function Invoke-Checked(
    [string]$Name,
    [string]$Executable,
    [string[]]$Arguments
) {
    Write-Host "[$Name]"
    Write-PortableLog $Mode "command_start" "running" $Name
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $Executable @Arguments 2>&1 | ForEach-Object {
            $line = ConvertTo-NeutralText ([string]$_)
            Write-Host $line
            Write-PortableLog $Mode "command_output" "info" $line
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
        $timer.Stop()
    }
    Write-PortableLog $Mode "command_finish" "info" "$Name; exit code $code; seconds=$($timer.Elapsed.TotalSeconds.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture))"
    if ($code -ne 0) {
        $exception = New-Object System.Exception("$Name failed with exit code $code")
        $exception.Data["NativeExitCode"] = $code
        throw $exception
    }
}

function Download-VerifiedFile(
    [string]$Url,
    [string]$Destination,
    [string]$ExpectedSha256
) {
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        if ((Get-Sha256 $Destination) -eq $ExpectedSha256) {
            Write-Host "Using verified download: $([System.IO.Path]::GetFileName($Destination))"
            return
        }
        [System.IO.File]::Delete($Destination)
    }

    $partial = "$Destination.part"
    if (Test-Path -LiteralPath $partial) {
        [System.IO.File]::Delete($partial)
    }

    Write-Host "Download: $Url"
    try {
        $defaultProxy = [System.Net.WebRequest]::DefaultWebProxy
        if ($null -ne $defaultProxy) {
            $defaultProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
        }
        # WebClient writes a literal filename; PS 5.1 -OutFile treats brackets as wildcards.
        $client = New-Object System.Net.WebClient
        try {
            $client.Proxy = $defaultProxy
            $client.DownloadFile($Url, $partial)
        } finally {
            $client.Dispose()
        }
    } catch {
        if (Test-Path -LiteralPath $partial) {
            [System.IO.File]::Delete($partial)
        }
        Write-Host "PowerShell download failed; retrying with Windows BITS proxy authentication."
        try {
            Import-Module BitsTransfer -ErrorAction Stop
            $bitsSucceeded = $false
            foreach ($proxyUsage in @("AutoDetect", "SystemDefault")) {
                try {
                    Start-BitsTransfer -Source $Url -Destination $partial -TransferType Download -Priority Foreground -ProxyUsage $proxyUsage -ProxyAuthentication Negotiate -ErrorAction Stop
                    $bitsSucceeded = $true
                    break
                } catch {
                    if (Test-Path -LiteralPath $partial) {
                        [System.IO.File]::Delete($partial)
                    }
                }
            }
            if (-not $bitsSucceeded) {
                throw "BITS could not download through the available network path."
            }
        } catch {
            if (Test-Path -LiteralPath $partial) {
                [System.IO.File]::Delete($partial)
            }
            throw "The official uv archive could not be downloaded. Check Internet/proxy access and start again."
        }
    }

    $actualSha256 = Get-Sha256 $partial
    if ($actualSha256 -ne $ExpectedSha256) {
        [System.IO.File]::Delete($partial)
        throw "Downloaded uv archive failed pinned SHA-256 verification."
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

function Install-VerifiedUv {
    $uvReady = (
        (Test-Path -LiteralPath $UvExe -PathType Leaf) -and
        ((Get-Sha256 $UvExe) -eq $UvExeSha256)
    )
    if (-not $uvReady) {
        $archive = Join-Path $StateRoot "uv-$UvVersion-windows-x86_64.zip"
        $extractRoot = Join-Path $StateRoot "uv-extract"
        Download-VerifiedFile $UvArchiveUrl $archive $UvArchiveSha256

        if (Test-Path -LiteralPath $extractRoot) {
            [System.IO.Directory]::Delete($extractRoot, $true)
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($archive, $extractRoot)
        $extractedUv = Join-Path $extractRoot "uv.exe"
        if (-not (Test-Path -LiteralPath $extractedUv -PathType Leaf)) {
            throw "The verified uv archive does not contain uv.exe."
        }
        if ((Get-Sha256 $extractedUv) -ne $UvExeSha256) {
            throw "Extracted uv.exe failed pinned SHA-256 verification."
        }
        Move-Item -LiteralPath $extractedUv -Destination $UvExe -Force
        [System.IO.Directory]::Delete($extractRoot, $true)
        [System.IO.File]::Delete($archive)
    }

    $versionOutput = (& $UvExe --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch ('^uv ' + [regex]::Escape($UvVersion) + '\b')) {
        throw "Unexpected uv executable: $versionOutput"
    }
    Write-Host "uv:            $versionOutput"
}

function Get-SelectedPythonVersion {
    $requirement = Get-QuotedSetting "project" "requires-python"
    if ($requirement -notmatch '^==(?<version>3\.(?:11|12|13|14)\.\d+)$') {
        throw 'project.requires-python must be exactly "==3.x.y" for CPython 3.11-3.14.'
    }
    return $Matches['version']
}

function Get-DesiredState(
    [string]$PythonVersion,
    [string]$PythonRequest
) {
    return @(
        "schema=$ProfileSchema"
        "uv=$UvVersion"
        "uv_exe_sha256=$UvExeSha256"
        "python=$PythonVersion"
        "python_request=$PythonRequest"
        "pyproject_sha256=$(Get-Sha256 $PyprojectPath)"
        "uv_lock_sha256=$(Get-Sha256 $LockPath)"
        "launcher_sha256=$(Get-Sha256 $PSCommandPath)"
    ) -join "`n"
}

function Confirm-ApprovedLockOrigins([string]$Path) {
    $approvedHosts = @("pypi.org", "files.pythonhosted.org")
    $lockText = Get-Content -LiteralPath $Path -Raw
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($lockText, '[A-Za-z][A-Za-z0-9+.-]*://[^"\s]+')) {
        $uri = [Uri]$match.Value
        if ($uri.Scheme -ne "https" -or $approvedHosts -notcontains $uri.Host) {
            throw "uv.lock contains an unapproved package origin: $($uri.AbsoluteUri)"
        }
    }
}

function Confirm-PreparedState(
    [string]$PythonVersion,
    [string]$PythonRequest
) {
    foreach ($required in @($LockPath, $VenvPython, $ReadyMarker, $UvExe)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Prepared state is incomplete. Run START.bat in a fresh extracted folder."
        }
    }
    $expected = Get-DesiredState $PythonVersion $PythonRequest
    $actual = (Get-Content -LiteralPath $ReadyMarker -Raw).TrimEnd()
    if ($actual -ne $expected) {
        throw "Prepared configuration changed. Use a fresh extraction and run START.bat. Application code may be changed independently."
    }
    if ((Get-Sha256 $UvExe) -ne $UvExeSha256) { throw "Prepared uv.exe failed SHA-256 verification." }
    Confirm-ApprovedLockOrigins $LockPath
    $expectedBase = Join-Path $RuntimeRoot "$PythonRequest\python.exe"
    Invoke-Checked "runtime_check" $VenvPython @(
        "-I", "-B", "-X", "utf8", "-c",
        "import pathlib,site,sys; actual='.'.join(map(str,sys.version_info[:3])); valid=actual==sys.argv[1] and not site.ENABLE_USER_SITE and pathlib.Path(sys._base_executable).resolve()==pathlib.Path(sys.argv[2]).resolve(); print('Python '+actual); print('Interpreter: project-local .venv'); raise SystemExit(0 if valid else 3)",
        $PythonVersion, $expectedBase
    )
}

function Initialize-PortablePython(
    [string]$PythonVersion,
    [string]$PythonRequest
) {
    Write-Host "Please wait: preparing portable Python, packages, and the local environment..." -ForegroundColor Yellow
    Write-PortableLog "portable-python" "setup_start" "running" "CPython $PythonVersion"

    foreach ($generated in @($VenvRoot, $LockPath, $ReadyMarker)) {
        if (Test-Path -LiteralPath $generated) {
            if ([System.IO.Directory]::Exists($generated)) {
                if ((Get-Item -LiteralPath $generated).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    throw "Refusing to replace linked generated state. Use a fresh extraction."
                }
                [System.IO.Directory]::Delete($generated, $true)
            } else {
                [System.IO.File]::Delete($generated)
            }
        }
    }

    Install-VerifiedUv

    $catalogJson = & $UvExe --no-config python list $PythonRequest --all-versions --all-platforms --all-arches --only-downloads --show-urls --output-format json
    if ($LASTEXITCODE -ne 0) {
        throw "uv could not inspect its managed-Python catalog."
    }
    $catalog = @($catalogJson | ConvertFrom-Json)
    if ($catalog.Count -ne 1) {
        throw "CPython $PythonVersion is not an exact downloadable Windows x86-64 choice in uv $UvVersion."
    }
    $pythonSource = [Uri][string]$catalog[0].url
    if ($pythonSource.Scheme -ne "https" -or $pythonSource.Host -ne "releases.astral.sh") {
        throw "uv selected an unapproved managed-Python origin: $($pythonSource.AbsoluteUri)"
    }
    Write-Host "Python source: $($pythonSource.AbsoluteUri)"

    Invoke-Checked "python_install" $UvExe @(
        "--no-config", "--system-certs", "--managed-python",
        "python", "install", $PythonRequest,
        "--install-dir", $RuntimeRoot, "--no-bin", "--no-registry"
    )

    $runtimePython = Join-Path $RuntimeRoot "$PythonRequest\python.exe"
    if (-not (Test-Path -LiteralPath $runtimePython -PathType Leaf)) {
        throw "uv did not create the expected project-local CPython runtime."
    }

    $projectPolicyCode = @'
import pathlib
import re
import sys
import tomllib

path = pathlib.Path(sys.argv[1])
selected = sys.argv[2]
selected_uv = sys.argv[3]
data = tomllib.loads(path.read_text(encoding="utf-8"))
project = data.get("project", {})
if set(data) - {"project", "tool"} or set(project) - {"name", "version", "description", "requires-python", "dependencies"}:
    raise SystemExit("use project.dependencies only; extra groups/build metadata are not supported")
for key in ("name", "version", "description", "requires-python"):
    value = project.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"project.{key} must be a non-empty string")
if project["requires-python"] != f"=={selected}":
    raise SystemExit(f'project.requires-python must be exactly "=={selected}"')
dependencies = project.get("dependencies")
if not isinstance(dependencies, list) or not all(isinstance(item, str) for item in dependencies):
    raise SystemExit("project.dependencies must be a TOML list of strings")
if len(dependencies) != len(set(dependencies)):
    raise SystemExit("project.dependencies contains a duplicate entry")
for dependency in dependencies:
    if "@" in dependency or "://" in dependency:
        raise SystemExit("use ordinary PyPI requirements, not direct URLs or paths")
if project.get("optional-dependencies") or data.get("dependency-groups"):
    raise SystemExit("place runtime packages in project.dependencies only")
uv = data.get("tool", {}).get("uv", {})
if uv.get("package") is not False or "sources" in uv:
    raise SystemExit("tool.uv must use package=false and no custom sources")
if uv.get("required-version") != f"=={selected_uv}":
    raise SystemExit("tool.uv.required-version must match the verified bootstrap")
if set(uv) != {"package", "required-version", "index"}:
    raise SystemExit("unsupported tool.uv settings")
indexes = uv.get("index", [])
expected = [{"name": "pypi", "url": "https://pypi.org/simple", "default": True}]
if indexes != expected:
    raise SystemExit("the only package index must be https://pypi.org/simple")
print(f"Project: {project['name']} {project['version']}")
print(f"Python: CPython {selected}")
print(f"uv: {selected_uv}")
print(f"Declared runtime dependencies: {len(dependencies)}")
'@

    $policyPath = Join-Path $StateRoot "project-policy.py"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($policyPath, $projectPolicyCode, $utf8NoBom)
    Invoke-Checked "project_policy_check" $runtimePython @(
        "-I", "-E", "-s", "-B", "-X", "utf8",
        $policyPath, $PyprojectPath, $PythonVersion, $UvVersion
    )

    Invoke-Checked "dependency_lock" $UvExe @(
        "--no-config", "--system-certs", "--managed-python", "--no-python-downloads",
        "lock", "--project", $Root, "--python", $PythonRequest,
        "--no-sources", "--no-build", "--default-index", $PyPiIndex
    )
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
        throw "uv did not create uv.lock."
    }
    Confirm-ApprovedLockOrigins $LockPath

    Invoke-Checked "dependency_sync" $UvExe @(
        "--no-config", "--system-certs", "--managed-python", "--no-python-downloads",
        "sync", "--project", $Root, "--locked", "--no-default-groups",
        "--no-install-project", "--no-build", "--no-sources",
        "--python", $PythonRequest, "--link-mode", "copy",
        "--default-index", $PyPiIndex
    )
    Invoke-Checked "dependency_check" $UvExe @(
        "--no-config", "--system-certs", "--managed-python", "--no-python-downloads",
        "sync", "--project", $Root, "--locked", "--no-default-groups",
        "--no-install-project", "--no-build", "--no-sources",
        "--python", $PythonRequest, "--check", "--default-index", $PyPiIndex
    )

    $previousLocation = Get-Location
    try {
        Set-Location -LiteralPath $Root
        Invoke-Checked "module_check" $VenvPython @(
            "-I", "-B", "-X", "utf8", "-c",
            "import importlib.util,sys; sys.path.insert(0,sys.argv[1]); spec=importlib.util.find_spec('application'); print('Module application: FOUND' if spec else 'Module application: NOT FOUND'); raise SystemExit(0 if spec else 4)",
            $Root
        )
    } finally {
        Set-Location -LiteralPath $previousLocation
    }

    $desiredState = Get-DesiredState $PythonVersion $PythonRequest
    [System.IO.File]::WriteAllText($ReadyMarker, $desiredState + "`r`n", [System.Text.Encoding]::ASCII)
    Write-PortableLog "portable-python" "setup_finish" "success" "CPython $PythonVersion"
}

$PortableExitCode = 0
$ApplicationExitCode = $null
$OverallExitCode = 30
$SetupMode = "NOT STARTED"
$PythonVersion = "unknown"
$PythonRequest = "unknown"
$PortableError = $null
$PortableReady = $false
$OriginalConsoleOutputEncoding = $null

try {
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw 'Use 64-bit Windows PowerShell on Windows x86-64 (AMD64).'
    }
    # Python/uv emit UTF-8. PowerShell must decode their captured streams as UTF-8.
    $OriginalConsoleOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    Confirm-LocalFixedDrive $Root
    foreach ($localPath in @($StateRoot, $VenvRoot, $ApplicationRoot, $PyprojectPath, $LockPath)) {
        if ((Test-Path -LiteralPath $localPath) -and ((Get-Item -LiteralPath $localPath).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "Project files/state must not be junctions or symbolic links."
        }
    }
    $LocalRootApproved = $true
    foreach ($required in @(
        $PyprojectPath,
        (Join-Path $ApplicationRoot "__init__.py"),
        (Join-Path $ApplicationRoot "__main__.py")
    )) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required project file is missing: $required"
        }
    }

    foreach ($directory in @($StateRoot, $LocalTemp)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    try {
        $WorkspaceLock = [System.IO.File]::Open((Join-Path $StateRoot "workspace.lock"), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch {
        throw "This workspace is already in use. Stop its running application/setup first."
    }
    Read-BootstrapSettings
    $PythonVersion = Get-SelectedPythonVersion
    $PythonRequest = "cpython-$PythonVersion-windows-x86_64-none"
    Set-PortableEnvironment
    Set-Location -LiteralPath $Root

    Write-Host ""
    Write-Host "PORTABLE PYTHON"
    Write-Host "Action:        $Mode"
    Write-Host "Project root:  local extracted folder"
    Write-Host "Python:       CPython $PythonVersion"
    Write-Host "Package tool: uv $UvVersion"
    Write-Host "Application:  python -m $ApplicationModule"

    if (Test-Path -LiteralPath $ReadyMarker -PathType Leaf) {
        $SetupMode = "SKIPPED"
        Confirm-PreparedState $PythonVersion $PythonRequest
        Write-PortableLog "portable-python" "prepared_state_check" "success" "setup skipped"
    } else {
        $SetupMode = "PERFORMED"
        Initialize-PortablePython $PythonVersion $PythonRequest
        Confirm-PreparedState $PythonVersion $PythonRequest
    }
    $PortableReady = $true

    Write-Host ""
    Write-Host "PORTABLE PYTHON RESULT"
    Write-Host "Status:                    READY" -ForegroundColor Green
    Write-Host "Setup:                     $SetupMode"
    Write-Host "Portable Python exit code: 0"
    Write-Host "Python path:               .venv\Scripts\python.exe"
    Write-Host "Log:                       .portable-python\portable-python.log"

    if ($Mode -eq "Setup") {
        Write-Host "Application status:        NOT RUN - SETUP ONLY"
        Write-Host "Next action:               START.bat"
        $OverallExitCode = 0
    } else {
        Write-Host ""
        Write-Host "APPLICATION RUN"
        Write-Host "Please wait: starting the application..." -ForegroundColor Yellow
        Write-PortableLog "application" "run_start" "running" "python -m application"
        # Application output is streamed to the console; only its exit status is journaled.
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $VenvPython -u -E -s -B -X utf8 -m $ApplicationModule 2>&1 | ForEach-Object {
                Write-Host (ConvertTo-NeutralText ([string]$_))
            }
            $ApplicationExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        Write-Host ""
        Write-Host "APPLICATION RESULT"
        if ($ApplicationExitCode -eq 0) {
            Write-Host "Status:                SUCCESS" -ForegroundColor Green
            Write-Host "Application exit code: 0"
            Write-PortableLog "application" "run_finish" "success" "exit code 0"
            $OverallExitCode = 0
        } else {
            Write-Host "Status:                FAILURE - APPLICATION" -ForegroundColor Red
            Write-Host "Application exit code: $ApplicationExitCode" -ForegroundColor Red
            Write-PortableLog "application" "run_finish" "failure" "exit code $ApplicationExitCode"
            $OverallExitCode = 20
        }
    }
} catch {
    $PortableError = ConvertTo-NeutralText $_.Exception.Message
    if ($_.Exception.Data.Contains("NativeExitCode")) {
        $PortableExitCode = [int]$_.Exception.Data["NativeExitCode"]
    } else {
        $PortableExitCode = 1
    }
    $OverallExitCode = if ($PortableReady) { 20 } else { 10 }
    Write-PortableLog $(if ($PortableReady) { "application" } else { "portable-python" }) "failure" "failure" $PortableError

    Write-Host ""
    if ($PortableReady) {
        Write-Host "APPLICATION RESULT"
        Write-Host "Status:                FAILURE - APPLICATION" -ForegroundColor Red
        Write-Host "Application exit code: $PortableExitCode" -ForegroundColor Red
    } else {
        Write-Host "PORTABLE PYTHON RESULT"
        Write-Host "Status:                    FAILURE - PORTABLE PYTHON" -ForegroundColor Red
        Write-Host "Setup:                     $SetupMode"
        Write-Host "Portable Python exit code: $PortableExitCode" -ForegroundColor Red
        Write-Host "Application status:        NOT RUN" -ForegroundColor Yellow
    }
    Write-Host "Problem: $PortableError" -ForegroundColor Red
    Write-Host "Log:     .portable-python\portable-python.log"
} finally {
    Write-Host ""
    if ($OverallExitCode -eq 0) {
        Write-Host "OVERALL STATUS: SUCCESS" -ForegroundColor Green
    } elseif ($OverallExitCode -eq 20) {
        Write-Host "OVERALL STATUS: FAILURE - APPLICATION" -ForegroundColor Red
    } elseif ($OverallExitCode -eq 10) {
        Write-Host "OVERALL STATUS: FAILURE - PORTABLE PYTHON" -ForegroundColor Red
    } else {
        Write-Host "OVERALL STATUS: FAILURE - LAUNCHER" -ForegroundColor Red
    }
    Write-Host "Overall exit code: $OverallExitCode"
    if ($null -ne $WorkspaceLock) { $WorkspaceLock.Dispose() }
    if (-not $NoPause) {
        [void](Read-Host "Press Enter to close")
    }
}

} finally {
    if ($null -ne $OriginalConsoleOutputEncoding) {
        [Console]::OutputEncoding = $OriginalConsoleOutputEncoding
    }
}

exit $OverallExitCode
