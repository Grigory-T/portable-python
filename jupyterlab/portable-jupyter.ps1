[CmdletBinding()]
param(
    [switch]$NoPause,
    [switch]$NoBrowser,
    [switch]$SetupOnly,
    [ValidateRange(0, 65535)]
    [int]$Port = 0
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-StrictMode -Version 2.0

$ProfileSchema = "jupyterlab-public-3"
$UvVersion = "unknown"
$UvArchiveUrl = ""
$UvArchiveSha256 = ""
$UvExeSha256 = ""
$PyPiIndex = "https://pypi.org/simple"
$JupyterLabVersion = "4.6.4"
$IpKernelVersion = "7.4.0"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PyprojectPath = Join-Path $Root "pyproject.toml"
$LockPath = Join-Path $Root "uv.lock"
$NotebooksRoot = Join-Path $Root "notebooks"
$VenvRoot = Join-Path $Root ".venv"
$VenvPython = Join-Path $VenvRoot "Scripts\python.exe"
$StateRoot = Join-Path $Root ".portable-jupyter"
$UvExe = Join-Path $StateRoot "uv.exe"
$UvCache = Join-Path $StateRoot "cache"
$RuntimeRoot = Join-Path $StateRoot "python"
$RuntimeBin = Join-Path $StateRoot "python-bin"
$ReadyMarker = Join-Path $StateRoot "ready.state"
$LogPath = Join-Path $StateRoot "portable-jupyter.log"
$JupyterConfig = Join-Path $StateRoot "jupyter-config"
$JupyterData = Join-Path $StateRoot "jupyter-data"
$JupyterRuntime = Join-Path $StateRoot "jupyter-runtime"
$IPythonRoot = Join-Path $StateRoot "ipython"
$MatplotlibConfig = Join-Path $StateRoot "matplotlib"
$LocalTemp = Join-Path $StateRoot "temp"
$ServerConfig = Join-Path $JupyterConfig "portable-server.json"
$KernelRoot = Join-Path $JupyterData "kernels"
$LocalRootApproved = $false
$WorkspaceLock = $null

function ConvertTo-NeutralText([string]$Text) {
    $Text = [regex]::Replace($Text, '[\x00-\x08\x0B-\x1F\x7F-\x9F]', '')
    $Text = [regex]::Replace($Text, '(?i)(https?://)[^\s/@]+@', '$1<redacted>@')
    foreach ($privatePath in @($Root, $env:USERPROFILE, $env:TEMP, $env:TMP)) {
        if ($privatePath) {
            $Text = [regex]::Replace($Text, [regex]::Escape($privatePath), "<local>", "IgnoreCase")
            $Text = [regex]::Replace($Text, [regex]::Escape($privatePath.Replace('\', '/')), "<local>", "IgnoreCase")
        }
    }
    if ($env:USERNAME) {
        $Text = [regex]::Replace($Text, '\b' + [regex]::Escape($env:USERNAME) + '\b', "<local>", "IgnoreCase")
    }
    return $Text
}

# Read only bootstrap scalars before a Python interpreter is available.
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
            throw "Use a real local project directory, not a junction or symbolic link."
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
    Write-PortableLog "portable-python" "command_start" "running" $Name
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $previousPreference = $ErrorActionPreference
    try {
        # Native stderr (including uv progress) is not itself a failure in PS 5.1.
        $ErrorActionPreference = "Continue"
        & $Executable @Arguments 2>&1 | ForEach-Object {
            $line = ConvertTo-NeutralText ([string]$_)
            Write-Host $line
            Write-PortableLog "portable-python" "command_output" "info" $line
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
        $timer.Stop()
    }
    Write-PortableLog "portable-python" "command_finish" $(if ($code -eq 0) { "success" } else { "failure" }) "$Name; exit=$code; seconds=$($timer.Elapsed.TotalSeconds.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture))"
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

    if ((Get-Sha256 $partial) -ne $ExpectedSha256) {
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

function Get-SelectedPythonVersion([string]$Path) {
    $requirement = Get-QuotedSetting "project" "requires-python"
    if ($requirement -notmatch '^==(?<version>3\.(?:11|12|13|14)\.\d+)$') {
        throw 'pyproject.toml must contain exactly one requires-python = "==3.x.y" line for CPython 3.11, 3.12, 3.13, or 3.14.'
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
        "jupyterlab=$JupyterLabVersion"
        "ipykernel=$IpKernelVersion"
        "pyproject_sha256=$(Get-Sha256 $PyprojectPath)"
        "uv_lock_sha256=$(Get-Sha256 $LockPath)"
        "launcher_sha256=$(Get-Sha256 $PSCommandPath)"
    ) -join "`n"
}

function Confirm-ApprovedLockOrigins([string]$Path) {
    $approvedHosts = @("pypi.org", "files.pythonhosted.org")
    $lockText = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($lockText, '[A-Za-z][A-Za-z0-9+.-]*://[^"\s]+')) {
        $uri = [Uri]$match.Value
        if ($uri.Scheme -ne "https" -or $approvedHosts -notcontains $uri.Host) {
            throw "uv.lock contains an unapproved package origin: $($uri.AbsoluteUri)"
        }
    }
}

function Test-PreparedState(
    [string]$PythonVersion,
    [string]$PythonRequest
) {
    foreach ($required in @($LockPath, $VenvPython, $ReadyMarker, $UvExe)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            return $false
        }
    }
    if ((Get-Sha256 $UvExe) -ne $UvExeSha256) {
        return $false
    }
    try {
        $expected = Get-DesiredState $PythonVersion $PythonRequest
        $actual = (Get-Content -LiteralPath $ReadyMarker -Raw).TrimEnd()
        if ($actual -ne $expected) {
            return $false
        }
        Confirm-ApprovedLockOrigins $LockPath
        $expectedBase = Join-Path $RuntimeRoot "$PythonRequest\python.exe"
        & $VenvPython -I -B -X utf8 -c "import importlib.metadata as m,pathlib,site,sys; actual='.'.join(map(str,sys.version_info[:3])); valid=actual==sys.argv[1] and not site.ENABLE_USER_SITE and pathlib.Path(sys._base_executable).resolve()==pathlib.Path(sys.argv[2]).resolve() and m.version('jupyterlab')==sys.argv[3] and m.version('ipykernel')==sys.argv[4]; raise SystemExit(0 if valid else 3)" $PythonVersion $expectedBase $JupyterLabVersion $IpKernelVersion
        if ($LASTEXITCODE -ne 0) { return $false }

        # A readiness fingerprint is not proof that the installed environment
        # still matches the lock. Check locally, without installing or networking.
        Write-Host "[dependency_state_check]"
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $checkOutput = & $UvExe --no-config --offline --managed-python --no-python-downloads sync --project $Root --locked --group jupyter --no-install-project --no-build --no-sources --python $PythonRequest --check --default-index $PyPiIndex 2>&1
            $checkCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        if ($checkCode -ne 0) {
            Write-Host "Local packages need synchronization; setup will run." -ForegroundColor Yellow
            Write-PortableLog "portable-python" "dependency_state_check" "update_required" (($checkOutput | Out-String).Trim())
            return $false
        }
        Write-PortableLog "portable-python" "dependency_state_check" "success" "installed packages match uv.lock; offline check"
        return $true
    } catch {
        return $false
    }
}

function Set-PortableEnvironment {
    # Child-process scope only: inherited uv overrides must not change sources/runtime.
    Get-ChildItem Env: | Where-Object { $_.Name -like 'UV_*' -or $_.Name -like 'JUPYTER_*' } | ForEach-Object {
        [Environment]::SetEnvironmentVariable($_.Name, $null, 'Process')
    }
    $env:UV_CACHE_DIR = $UvCache
    $env:UV_PROJECT_ENVIRONMENT = $VenvRoot
    $env:UV_PYTHON_INSTALL_DIR = $RuntimeRoot
    $env:UV_PYTHON_BIN_DIR = $RuntimeBin
    $env:SSL_CERT_FILE = $null
    $env:SSL_CERT_DIR = $null
    $env:BROWSER = $null
    $env:PYTHONPATH = $null
    $env:PYTHONHOME = $null
    $env:PYTHONNOUSERSITE = "1"
    $env:PYTHONDONTWRITEBYTECODE = "1"
    $env:JUPYTER_CONFIG_DIR = $JupyterConfig
    $env:JUPYTER_DATA_DIR = $JupyterData
    $env:JUPYTER_RUNTIME_DIR = $JupyterRuntime
    $env:JUPYTER_CONFIG_PATH = $JupyterConfig
    $env:JUPYTER_PATH = $JupyterData
    $env:JUPYTER_PREFER_ENV_PATH = "1"
    $env:IPYTHONDIR = $IPythonRoot
    $env:MPLCONFIGDIR = $MatplotlibConfig
    $env:TEMP = $LocalTemp
    $env:TMP = $LocalTemp
}

function Set-ProjectKernel {
    # A local kernelspec prevents notebook metadata/global registrations selecting
    # another Python. No user/global kernelspec is registered or modified.
    $kernelCode = @'
import json
import pathlib
import sys
import tomllib
from importlib.metadata import version
from jupyter_core.paths import secure_write
from packaging.requirements import Requirement

project = tomllib.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
requirements = [Requirement(item) for item in project["project"]["dependencies"]]
for requirement in requirements:
    if requirement.marker is None or requirement.marker.evaluate():
        print(f"User library: {requirement.name}=={version(requirement.name)}")
if not requirements:
    print("User libraries: none")

# This directory is launcher-owned, not a user configuration interface.
# Refuse stale auto-loaded base config, including executable Python config.
config_path = pathlib.Path(sys.argv[2])
for pattern in ("jupyter*_config.py", "jupyter*_config.json"):
    if any(config_path.parent.glob(pattern)):
        raise SystemExit("Unexpected Jupyter base configuration in generated state. Use a fresh extraction; do not copy generated config.")

kernel_root = pathlib.Path(sys.argv[1])
spec_dir = kernel_root / "python3"
spec_dir.mkdir(parents=True, exist_ok=True)
spec = {
    "argv": [sys.executable, "-u", "-E", "-s", "-B", "-X", "utf8", "-m", "ipykernel_launcher", "-f", "{connection_file}"],
    "display_name": "Python (project .venv)",
    "language": "python",
    "metadata": {"debugger": True},
}
(spec_dir / "kernel.json").write_text(json.dumps(spec, indent=2), encoding="utf-8")
# Let Jupyter generate the session token. Supplying a token in config makes
# Jupyter intentionally hide it as token=... in the console connection URL.
# Environment token overrides are cleared and stale base config is refused.
config = {"LabApp": {
    "extension_manager": "readonly",
    "news_url": None,
    "check_for_updates_class": "jupyterlab.NeverCheckForUpdate",
}, "KernelSpecManager": {
    "allowed_kernelspecs": ["python3"],
    "ensure_native_kernel": False,
}}
with secure_write(str(config_path)) as handle:
    json.dump(config, handle, indent=2)
print("Kernel: project-local .venv only")
'@
    $kernelPath = Join-Path $StateRoot "project-kernel.py"
    [System.IO.File]::WriteAllText($kernelPath, $kernelCode, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-Checked "kernel_config" $VenvPython @(
        "-I", "-B", "-X", "utf8", $kernelPath, $KernelRoot, $ServerConfig, $PyprojectPath
    )
}

function Initialize-PortableJupyter(
    [string]$PythonVersion,
    [string]$PythonRequest
) {
    Write-Host "Please wait: preparing portable Python, JupyterLab, and the local environment..." -ForegroundColor Yellow
    Write-PortableLog "portable-python" "setup_start" "running" "CPython $PythonVersion"

    if (Test-Path -LiteralPath $ReadyMarker) {
        [System.IO.File]::Delete($ReadyMarker)
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

    Set-PortableEnvironment
    Invoke-Checked "python_install" $UvExe @(
        "--no-config", "--system-certs", "--managed-python",
        "python", "install", $PythonRequest,
        "--install-dir", $RuntimeRoot, "--no-bin", "--no-registry"
    )

    $runtimePython = Join-Path $RuntimeRoot "$PythonRequest\python.exe"
    if (-not (Test-Path -LiteralPath $runtimePython -PathType Leaf)) {
        throw "uv did not create the expected project-local CPython runtime."
    }

    if (Test-Path -LiteralPath $VenvRoot -PathType Container) {
        $venvVersion = ""
        if (Test-Path -LiteralPath $VenvPython -PathType Leaf) {
            $venvVersion = (& $VenvPython -E -s -B -X utf8 -c "import pathlib,platform,sys; print(platform.python_version() if pathlib.Path(sys._base_executable).resolve()==pathlib.Path(sys.argv[1]).resolve() else 'foreign-runtime')" $runtimePython | Out-String).Trim()
        }
        if ($venvVersion -ne $PythonVersion) {
            [System.IO.Directory]::Delete($VenvRoot, $true)
        }
    }

    $projectPolicyCode = @'
import pathlib
import sys
import tomllib

path = pathlib.Path(sys.argv[1])
selected = sys.argv[2]
jupyterlab_version = sys.argv[3]
ipykernel_version = sys.argv[4]
uv_version = sys.argv[5]
data = tomllib.loads(path.read_text(encoding="utf-8"))
project = data.get("project", {})
if set(data) - {"project", "dependency-groups", "tool"}:
    raise SystemExit("this profile supports only project, dependency-groups, and tool tables")
if set(project) - {"name", "version", "description", "requires-python", "dependencies"}:
    raise SystemExit("unsupported project metadata; use the ordinary project.dependencies list")
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
        raise SystemExit("direct-URL dependencies are not allowed: " + dependency)
groups = data.get("dependency-groups", {})
expected_group = [f"jupyterlab=={jupyterlab_version}", f"ipykernel=={ipykernel_version}"]
if groups != {"jupyter": expected_group}:
    raise SystemExit(f"Keep dependency-groups.jupyter exactly {expected_group!r}. Put your own libraries in [project].dependencies, not in the jupyter group.")
uv = data.get("tool", {}).get("uv", {})
if set(uv) != {"package", "default-groups", "required-version", "index"} or uv.get("package") is not False or uv.get("default-groups") != ["jupyter"] or uv.get("required-version") != f"=={uv_version}":
    raise SystemExit("tool.uv must use package=false, default-groups=['jupyter'], and no custom sources")
indexes = uv.get("index", [])
expected_index = [{"name": "pypi", "url": "https://pypi.org/simple", "default": True}]
if indexes != expected_index:
    raise SystemExit("the only package index must be https://pypi.org/simple")
print(f"Project: {project['name']} {project['version']}")
print(f"Python: CPython {selected}")
print(f"User libraries: {len(dependencies)}")
print(f"Jupyter infrastructure: jupyterlab {jupyterlab_version}, ipykernel {ipykernel_version}")
'@

    $policyPath = Join-Path $StateRoot "project-policy.py"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($policyPath, $projectPolicyCode, $utf8NoBom)
    Invoke-Checked "project_policy_check" $runtimePython @(
        "-I", "-E", "-s", "-B", "-X", "utf8",
        $policyPath, $PyprojectPath, $PythonVersion, $JupyterLabVersion, $IpKernelVersion, $UvVersion
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
        "sync", "--project", $Root, "--locked", "--group", "jupyter",
        "--no-install-project", "--no-build", "--no-sources",
        "--python", $PythonRequest, "--link-mode", "copy",
        "--default-index", $PyPiIndex
    )
    Invoke-Checked "dependency_check" $UvExe @(
        "--no-config", "--system-certs", "--managed-python", "--no-python-downloads",
        "sync", "--project", $Root, "--locked", "--group", "jupyter",
        "--no-install-project", "--no-build", "--no-sources",
        "--python", $PythonRequest, "--check", "--default-index", $PyPiIndex
    )

    Invoke-Checked "runtime_check" $VenvPython @(
        "-I", "-B", "-X", "utf8", "-c",
        "import pathlib,site,sys; actual='.'.join(map(str,sys.version_info[:3])); valid=actual==sys.argv[1] and not site.ENABLE_USER_SITE and pathlib.Path(sys._base_executable).resolve()==pathlib.Path(sys.argv[2]).resolve(); print('Python '+actual); print('Interpreter: project-local .venv'); raise SystemExit(0 if valid else 3)",
        $PythonVersion, $runtimePython
    )
    Invoke-Checked "jupyter_check" $VenvPython @(
        "-I", "-B", "-X", "utf8", "-c",
        "import importlib.metadata as m; print('JupyterLab '+m.version('jupyterlab')); print('ipykernel '+m.version('ipykernel'))"
    )

    $desiredState = Get-DesiredState $PythonVersion $PythonRequest
    [System.IO.File]::WriteAllText($ReadyMarker, $desiredState + "`r`n", [System.Text.Encoding]::ASCII)
    Write-PortableLog "portable-python" "setup_finish" "success" "CPython $PythonVersion; JupyterLab $JupyterLabVersion"
}

$PortableExitCode = 0
$JupyterExitCode = $null
$OverallExitCode = 30
$SetupMode = "NOT STARTED"
$PythonVersion = "unknown"
$PythonRequest = "unknown"
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
    # Check generated state paths before any logging or directory creation.
    foreach ($localPath in @($StateRoot, $VenvRoot, $NotebooksRoot, $PyprojectPath, $LockPath)) {
        if ((Test-Path -LiteralPath $localPath) -and ((Get-Item -LiteralPath $localPath).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "Project files/state must not be junctions or symbolic links."
        }
    }
    $LocalRootApproved = $true
    if (-not (Test-Path -LiteralPath $PyprojectPath -PathType Leaf)) {
        throw "Required project file is missing: $PyprojectPath"
    }
    if (-not (Test-Path -LiteralPath $NotebooksRoot -PathType Container)) {
        throw "Required notebook folder is missing: $NotebooksRoot"
    }
    foreach ($directory in @(
        $StateRoot, $NotebooksRoot, $JupyterConfig, $JupyterData,
        $JupyterRuntime, $IPythonRoot, $LocalTemp
    )) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    try {
        $WorkspaceLock = [System.IO.File]::Open((Join-Path $StateRoot "workspace.lock"), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch {
        throw "This workspace is already in use. Stop its running server/setup before starting it again."
    }

    Read-BootstrapSettings
    $PythonVersion = Get-SelectedPythonVersion $PyprojectPath
    $PythonRequest = "cpython-$PythonVersion-windows-x86_64-none"
    Set-PortableEnvironment

    Write-Host ""
    Write-Host "PORTABLE PYTHON FOR JUPYTERLAB"
    Write-Host "Project root:   local extracted folder"
    Write-Host "Python:        CPython $PythonVersion"
    Write-Host "Package tool:  uv $UvVersion"
    Write-Host "JupyterLab:    $JupyterLabVersion"
    Write-Host "User libraries: project.dependencies in pyproject.toml"

    $hadMarker = Test-Path -LiteralPath $ReadyMarker -PathType Leaf
    if (Test-PreparedState $PythonVersion $PythonRequest) {
        $SetupMode = "SKIPPED"
        Write-PortableLog "portable-python" "prepared_state_check" "success" "setup skipped"
    } else {
        $SetupMode = if ($hadMarker) { "UPDATED" } else { "PERFORMED" }
        Initialize-PortableJupyter $PythonVersion $PythonRequest
    }
    if (-not (Test-PreparedState $PythonVersion $PythonRequest)) {
        throw "Prepared environment validation failed. Review the setup log."
    }
    Set-ProjectKernel

    $PortableReady = $true
    Write-Host ""
    Write-Host "PORTABLE PYTHON RESULT"
    Write-Host "Status:                    READY" -ForegroundColor Green
    Write-Host "Setup:                     $SetupMode"
    Write-Host "Portable Python exit code: 0"
    Write-Host "Python path:               .venv\Scripts\python.exe"
    Write-Host "Notebook folder:           notebooks"
    Write-Host "Log:                       .portable-jupyter\portable-jupyter.log"
} catch {
    if ($_.Exception.Data.Contains("NativeExitCode")) {
        $PortableExitCode = [int]$_.Exception.Data["NativeExitCode"]
    } else {
        $PortableExitCode = 1
    }
    $OverallExitCode = 10
    Write-PortableLog "portable-python" "failure" "failure" $_.Exception.Message
    Write-Host ""
    Write-Host "PORTABLE PYTHON RESULT"
    Write-Host "Status:                    FAILURE - PORTABLE PYTHON" -ForegroundColor Red
    Write-Host "Setup:                     $SetupMode"
    Write-Host "Portable Python exit code: $PortableExitCode" -ForegroundColor Red
    Write-Host "Problem:                   $(ConvertTo-NeutralText $_.Exception.Message)" -ForegroundColor Red
    Write-Host "JupyterLab status:         NOT STARTED" -ForegroundColor Yellow
    Write-Host "Log:                       .portable-jupyter\portable-jupyter.log"
}

if ($PortableReady) {
    if ($SetupOnly) {
        $OverallExitCode = 0
        Write-Host ""
        Write-Host "JUPYTERLAB SERVER"
        Write-Host "Status:     NOT STARTED - SETUP ONLY"
    } else {
        try {
            $openBrowser = if ($NoBrowser) { "False" } else { "True" }
            $serverArguments = @(
                "-u", "-E", "-s", "-B", "-X", "utf8", "-m", "jupyterlab",
                "--config=$ServerConfig",
                "--ServerApp.root_dir=$NotebooksRoot",
                "--ServerApp.ip=127.0.0.1",
                "--ServerApp.allow_remote_access=False",
                "--ServerApp.open_browser=$openBrowser",
                "--ServerApp.port_retries=50"
            )
            if ($Port -gt 0) {
                $serverArguments += "--ServerApp.port=$Port"
            }

            Write-Host ""
            Write-Host "JUPYTERLAB SERVER"
            Write-Host "Status:          STARTING"
            Write-Host "Notebook folder: notebooks (under the local project root)"
            Write-Host "Network bind:    127.0.0.1 only"
            Write-Host "Browser:         $(if ($NoBrowser) { 'disabled by technical option' } else { 'opening requested; Windows default browser' })"
            Write-Host "Browser fallback: copy Jupyter's full localhost URL, including its token, printed below."
            Write-Host "Keep the token private; it grants access to this local server."
            Write-Host "Stop server:     JupyterLab File > Shut Down, or Ctrl+C in this window"
            Write-Host "Please wait: starting JupyterLab..." -ForegroundColor Yellow
            Write-PortableLog "jupyterlab" "server_start" "running" "root=notebooks; browser=$openBrowser"

            $previousLocation = Get-Location
            try {
                Set-Location -LiteralPath $Root
                & $VenvPython @serverArguments
                $JupyterExitCode = $LASTEXITCODE
            } finally {
                Set-Location -LiteralPath $previousLocation
            }

            Write-Host ""
            Write-Host "JUPYTERLAB RESULT"
            if ($JupyterExitCode -eq 0) {
                Write-Host "Status:                  STOPPED NORMALLY" -ForegroundColor Green
                Write-Host "JupyterLab exit code:    0"
                Write-PortableLog "jupyterlab" "server_stop" "success" "exit code 0"
                $OverallExitCode = 0
            } else {
                Write-Host "Status:                  FAILURE - JUPYTERLAB SERVER" -ForegroundColor Red
                Write-Host "JupyterLab exit code:    $JupyterExitCode" -ForegroundColor Red
                Write-PortableLog "jupyterlab" "server_stop" "failure" "exit code $JupyterExitCode"
                $OverallExitCode = 20
            }
        } catch {
            $JupyterExitCode = 1
            if ($_.Exception.Data.Contains("NativeExitCode")) {
                $JupyterExitCode = [int]$_.Exception.Data["NativeExitCode"]
            }
            $OverallExitCode = 20
            Write-PortableLog "jupyterlab" "server_failure" "failure" $_.Exception.Message
            Write-Host ""
            Write-Host "JUPYTERLAB RESULT"
            Write-Host "Status:                  FAILURE - JUPYTERLAB SERVER" -ForegroundColor Red
            Write-Host "JupyterLab exit code:    $JupyterExitCode" -ForegroundColor Red
            Write-Host "Problem:                 $(ConvertTo-NeutralText $_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Write-Host ""
if ($OverallExitCode -eq 0) {
    Write-Host "OVERALL STATUS: SUCCESS" -ForegroundColor Green
} elseif ($OverallExitCode -eq 20) {
    Write-Host "OVERALL STATUS: FAILURE - JUPYTERLAB SERVER" -ForegroundColor Red
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

} finally {
    if ($null -ne $OriginalConsoleOutputEncoding) {
        [Console]::OutputEncoding = $OriginalConsoleOutputEncoding
    }
}

exit $OverallExitCode
