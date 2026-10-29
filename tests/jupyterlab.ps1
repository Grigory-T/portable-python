param([Parameter(Mandatory=$true)][string]$Zip, [switch]$Audit, [switch]$KeepWorkspace)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'workspace.ps1')
$testRoot = New-TestWorkspace 'jupyterlab'
$server = $null
$script:serverInfo = $null
try {
# Build the Unicode folder name independently of the PowerShell source encoding.
$folderName = -join ([char[]]@(0x0075,0x006e,0x0069,0x0063,0x006f,0x0064,0x0065,0x002d,0x00e9))
$root = Join-Path $testRoot ($folderName + ' [literal]')
New-Item -ItemType Directory -Path $root -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory((Get-Item -LiteralPath $Zip).FullName, $root)
$launcher = Join-Path $root 'portable-jupyter.ps1'
$projectPath = Join-Path $root 'pyproject.toml'
$venvPython = Join-Path $root '.venv\Scripts\python.exe'

function Write-ServerDiagnostics {
    foreach ($name in @('server.stdout', 'server.stderr')) {
        $path = Join-Path $testRoot $name
        if (Test-Path -LiteralPath $path) {
            Get-Content -LiteralPath $path -Tail 35 | ForEach-Object {
                $line = ([string]$_).Replace($root, '<project>').Replace($env:USERNAME, '<account>')
                $line = $line -replace '(?i)(token=)[^\s&]+', '$1<redacted>'
                Write-Host $line
            }
        }
    }
}

function Read-LiveServerOutput([string]$Name) {
    # Redirected output is still open for writing while the server is running.
    $stream = [IO.File]::Open((Join-Path $testRoot $Name), 'Open', 'Read', 'ReadWrite')
    $reader = New-Object IO.StreamReader($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Invoke-Profile([int]$Expected = 0) {
    $script:lastOutput = ''
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -SetupOnly -NoPause 2>&1 | ForEach-Object {
            $script:lastOutput += [string]$_ + "`n"
            Write-Host ([string]$_)
        }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($code -ne $Expected) { throw "Expected exit $Expected, got $code" }
}

    # An inherited alternate uv source must not affect the profile.
    $env:UV_INDEX = 'https://invalid.invalid/simple'
    $env:SSL_CERT_FILE = 'C:\invalid-portable-test\ca.pem'
    $env:SSL_CERT_DIR = 'C:\invalid-portable-test\certs'
    $env:BROWSER = 'invalid-portable-browser-command'
    Invoke-Profile
    if ($lastOutput -notmatch 'Setup:\s+PERFORMED') { throw 'Fresh setup not performed' }
    & (Join-Path $PSScriptRoot 'encoding.ps1') -Launcher $launcher -Root $root -TestRoot $testRoot -Profile Jupyter
    $configPath = Join-Path $root '.portable-jupyter\jupyter-config\portable-server.json'
    if ([IO.File]::ReadAllText($configPath) -match '"token"\s*:') { throw 'Configured token would hide the browser fallback URL' }
    Invoke-Profile
    if ($lastOutput -notmatch 'Setup:\s+SKIPPED') { throw 'Unchanged setup not skipped' }

    # Stale auto-loaded config must not disable authentication or execute code.
    $staleConfig = Join-Path $root '.portable-jupyter\jupyter-config\jupyter_config.json'
    [IO.File]::WriteAllText($staleConfig, '{"IdentityProvider":{"token":""}}', $utf8)
    Invoke-Profile 10
    if ($lastOutput -notmatch 'Unexpected Jupyter base configuration') { throw 'Stale base config was accepted' }
    [IO.File]::Delete($staleConfig)
    Invoke-Profile

    $project = [IO.File]::ReadAllText($projectPath)
    [IO.File]::WriteAllText($projectPath, $project.Replace('dependencies = []', 'dependencies = ["more-itertools==11.1.0"]'), $utf8)
    Invoke-Profile
    if ($lastOutput -notmatch 'Setup:\s+UPDATED') { throw 'Library addition did not update' }
    & $venvPython -I -c "import more_itertools; assert list(more_itertools.chunked(range(3),2))==[[0,1],[2]]"
    if ($LASTEXITCODE -ne 0) { throw 'User library failed to import' }
    [IO.File]::WriteAllText($projectPath, $project, $utf8)
    Invoke-Profile
    if ($lastOutput -notmatch 'Setup:\s+UPDATED') { throw 'Library removal did not update' }
    & $venvPython -I -c "import importlib.util; assert importlib.util.find_spec('more_itertools') is None"
    if ($LASTEXITCODE -ne 0) { throw 'Exact sync did not remove user library' }

    # Regression: own libraries must not replace the mandatory infrastructure.
    $wrongGroup = $project.Replace('"jupyterlab==4.6.4",', '"openpyxl",').Replace('"ipykernel==7.4.0",', '"polars",')
    [IO.File]::WriteAllText($projectPath, $wrongGroup, $utf8)
    Invoke-Profile 10
    if ($lastOutput -notmatch 'Put your own libraries in \[project\]\.dependencies') { throw 'Missing actionable group-placement message' }
    [IO.File]::WriteAllText($projectPath, $project, $utf8)
    Invoke-Profile

    # Exact reported sequence: start with openpyxl, then add polars and restart.
    [IO.File]::WriteAllText($projectPath, $project.Replace('dependencies = []', 'dependencies = ["openpyxl"]'), $utf8)
    Invoke-Profile
    [IO.File]::WriteAllText($projectPath, $project.Replace('dependencies = []', 'dependencies = ["openpyxl", "polars"]'), $utf8)
    Invoke-Profile
    if ($lastOutput -notmatch 'Setup:\s+UPDATED') { throw 'Polars addition did not update' }
    & $venvPython -I -c "import openpyxl,polars as pl; assert pl.DataFrame(dict(x=[1,2])).select(pl.col('x').sum()).item()==3; print('POLARS IMPORT AND COMPUTE SUCCESS',pl.__version__)"
    if ($LASTEXITCODE -ne 0) { throw 'Polars failed after declared addition' }

    # A marker alone must not permit SKIPPED when an installed package vanished.
    & $venvPython -I -c "import importlib.metadata as m,pathlib,shutil; d=m.distribution('polars'); metadata=next(f.locate().parent for f in d.files if f.name=='METADATA'); shutil.rmtree(d.locate_file('polars')); shutil.rmtree(metadata)"
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare missing-package fixture' }
    Invoke-Profile
    if ($lastOutput -notmatch 'Setup:\s+UPDATED') { throw 'Missing installed package was incorrectly skipped' }
    & $venvPython -I -c "import polars; print('POLARS REPAIR SUCCESS',polars.__version__)"
    if ($LASTEXITCODE -ne 0) { throw 'Missing Polars package was not repaired' }

    # Preserve a copied notebook in a nested directory across synchronization.
    New-Item -ItemType Directory -Path (Join-Path $root 'notebooks\nested') | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'notebooks\WELCOME.ipynb') -Destination (Join-Path $root 'notebooks\nested\copy.ipynb')
    $notebookHash = (Get-FileHash -LiteralPath (Join-Path $root 'notebooks\nested\copy.ipynb')).Hash
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '" -NoBrowser -NoPause -Port 8898'
    $server = Start-Process powershell.exe -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $testRoot 'server.stdout') -RedirectStandardError (Join-Path $testRoot 'server.stderr')
    # Retain the native handle so Windows PowerShell can report ExitCode later.
    $serverHandle = $server.Handle
    $runtime = Join-Path $root '.portable-jupyter\jupyter-runtime'
    $info = $null
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        if ($server.HasExited) { throw ('Server exited early: ' + [IO.File]::ReadAllText((Join-Path $testRoot 'server.stderr'))) }
        $record = Get-ChildItem -LiteralPath $runtime -Filter 'jpserver-*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($record) {
            try {
                $candidate = [IO.File]::ReadAllText($record.FullName) | ConvertFrom-Json
                $headers = @{ Authorization = ('token ' + $candidate.token) }
                Invoke-RestMethod -Uri ($candidate.url + 'api/status') -Headers $headers | Out-Null
                $info = $candidate
                break
            } catch { }
        }
        Start-Sleep -Milliseconds 500
    }
    if ($null -eq $info) { throw 'Jupyter server did not become ready' }
    $script:serverInfo = $info
    if (-not $info.token) { throw 'Authentication token was disabled' }
    $console = (Read-LiveServerOutput 'server.stdout') + (Read-LiveServerOutput 'server.stderr')
    if ($console -notmatch ('http://127\.0\.0\.1:' + $info.port + '/lab\?token=' + [regex]::Escape($info.token))) {
        throw 'No usable full tokenized JupyterLab URL in the console'
    }
    $kernelSpecs = Invoke-RestMethod -Uri ($info.url + 'api/kernelspecs') -Headers $headers
    $names = @($kernelSpecs.kernelspecs.PSObject.Properties.Name)
    if ($names.Count -ne 1 -or $names[0] -ne 'python3') { throw 'Non-project kernels were exposed' }
    $actualPython = $kernelSpecs.kernelspecs.python3.spec.argv[0]
    # Windows runners can expose TEMP using an 8.3 name; compare file identity,
    # not the spelling returned by different Windows/Python APIs.
    & $venvPython -I -c "import pathlib,sys; assert pathlib.Path(sys.argv[1]).samefile(pathlib.Path(sys.argv[2]))" $actualPython $venvPython
    if ($LASTEXITCODE -ne 0) { throw 'Kernel points outside project environment' }
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $info.port)
    if (@($listeners | Where-Object LocalAddress -ne '127.0.0.1').Count) { throw 'Non-loopback listener found' }
    Invoke-Profile 10
    if ($lastOutput -notmatch 'already in use') { throw 'Concurrent workspace was not blocked' }

    $probe = @'
import json
import pathlib
import sys
import time
import urllib.request
import urllib.error
import uuid
from datetime import datetime, timezone
import websocket

root = pathlib.Path(sys.argv[1]).resolve()
runtime = root / ".portable-jupyter" / "jupyter-runtime"
info = json.loads(next(runtime.glob("jpserver-*.json")).read_text(encoding="utf-8"))
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def api(path, method="GET", body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(info["url"] + "api/" + path, data=data, method=method,
        headers={"Authorization": "token " + info["token"], "Content-Type": "application/json"})
    with opener.open(request, timeout=20) as response:
        result = response.read()
        return json.loads(result) if result else None

try:
    opener.open(urllib.request.Request(info["url"] + "api/kernelspecs", headers={"Accept": "application/json"}), timeout=10)
except urllib.error.HTTPError as error:
    assert error.code in (401, 403), error.code
else:
    raise AssertionError("Unauthenticated kernel access was allowed")
contents = api("contents")
assert "WELCOME.ipynb" in {item["name"] for item in contents["content"]}
session = api("sessions", "POST", {"path": "nested/copy.ipynb", "name": "copy.ipynb", "type": "notebook", "kernel": {"name": "python3"}})
connection = runtime / ("kernel-" + session["kernel"]["id"] + ".json")
for _ in range(60):
    if connection.exists():
        break
    time.sleep(.5)
ws_url = info["url"].replace("http://", "ws://") + "api/kernels/" + session["kernel"]["id"] + "/channels?token=" + info["token"]
channel = websocket.create_connection(ws_url, timeout=45, origin=info["url"].rstrip("/"), http_no_proxy=["127.0.0.1", "localhost"])
try:
    code = "import os,pathlib,site,sys,openpyxl,polars as pl; assert pl.DataFrame(dict(x=[1,2])).select(pl.col('x').sum()).item()==3; assert not any(k in os.environ for k in ('SSL_CERT_FILE','SSL_CERT_DIR','BROWSER')); assert sys.version_info[:3]==(3,13,18); assert pathlib.Path(sys.prefix).resolve()==pathlib.Path(" + repr(str(root / ".venv")) + ").resolve(); assert not site.ENABLE_USER_SITE; assert pathlib.Path.cwd().resolve()==pathlib.Path(" + repr(str(root / "notebooks" / "nested")) + ").resolve(); print('LOCAL KERNEL EXECUTION AND POLARS COMPUTE SUCCESS')"
    unicode_text = '\u0424\u043e\u0440\u043c\u0438\u0440\u043e\u0432\u0430\u043d\u0438\u0435 | \u0401\u0451 | \u20ac | \u65e5\u672c\u8a9e | \U0001f600'
    code += "; print(" + repr(unicode_text) + ")"
    msg_id = uuid.uuid4().hex
    request = {"header": {"msg_id": msg_id, "username": "test", "session": uuid.uuid4().hex,
        "msg_type": "execute_request", "version": "5.3", "date": datetime.now(timezone.utc).isoformat()},
        "parent_header": {}, "metadata": {}, "channel": "shell", "buffers": [],
        "content": {"code": code, "silent": False, "store_history": False, "user_expressions": {}, "allow_stdin": False, "stop_on_error": True}}
    channel.send(json.dumps(request))
    output = ""
    while True:
        message = json.loads(channel.recv())
        if message["parent_header"].get("msg_id") != msg_id:
            continue
        msg_type = message["header"]["msg_type"]
        if msg_type == "error":
            raise AssertionError(message["content"])
        if msg_type == "stream":
            output += message["content"]["text"]
        if msg_type == "status" and message["content"]["execution_state"] == "idle":
            break
    assert "LOCAL KERNEL EXECUTION AND POLARS COMPUTE SUCCESS" in output
    assert unicode_text in output
    print(output.strip())
finally:
    channel.close()
    api("sessions/" + session["id"], "DELETE")
api("shutdown", "POST", {})
'@
    $probePath = Join-Path $testRoot 'probe.py'
    [IO.File]::WriteAllText($probePath, $probe, $utf8)
    & $venvPython -I -X utf8 $probePath $root
    if ($LASTEXITCODE -ne 0) { throw 'Server/kernel API probe failed' }
    # Wait for the owned launcher, not asynchronous redirected-stream events.
    # CI/antivirus/kernel cleanup can take longer than a desktop's 30 seconds.
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while (-not $server.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $server.Refresh()
    }
    if (-not $server.HasExited) {
        Write-ServerDiagnostics
        throw 'Server did not stop within 90 seconds after API shutdown'
    }
    $server.Refresh()
    if ($server.ExitCode -ne 0) { throw "Server returned $($server.ExitCode)" }
    if (@(Get-NetTCPConnection -State Listen -LocalPort $info.port -ErrorAction SilentlyContinue).Count) {
        throw 'Listener remained after successful server shutdown'
    }
    $server = $null
    $stdout = [IO.File]::ReadAllText((Join-Path $testRoot 'server.stdout'))
    if ($stdout -notmatch 'Setup:\s+SKIPPED' -or $stdout -notmatch 'STOPPED NORMALLY') { throw 'Missing recurring/server result' }
    $stderr = [IO.File]::ReadAllText((Join-Path $testRoot 'server.stderr'))
    if ($stderr -match 'Config option .+ not recognized') { throw 'Unrecognized Jupyter configuration' }
    if ((Get-FileHash -LiteralPath (Join-Path $root 'notebooks\nested\copy.ipynb')).Hash -ne $notebookHash) { throw 'Notebook was changed by infrastructure' }
    $log = [IO.File]::ReadAllText((Join-Path $root '.portable-jupyter\portable-jupyter.log'))
    foreach ($private in @($root, $env:USERNAME, $info.token)) {
        if ($private -and $log.IndexOf($private, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'Private identity/token in diagnostic journal' }
    }
    if ($Audit) {
        $env:SSL_CERT_FILE = $null
        $env:SSL_CERT_DIR = $null
        & $venvPython -I (Join-Path $PSScriptRoot '..\scripts\audit.py')
        if ($LASTEXITCODE -ne 0) { throw 'Advisory check failed' }
    }
} finally {
    try {
    if ($null -ne $server -and -not $server.HasExited) {
        if ($script:serverInfo) {
            try { Invoke-RestMethod -Uri ($script:serverInfo.url + 'api/shutdown') -Method Post -TimeoutSec 5 -Headers @{Authorization=('token ' + $script:serverInfo.token)} | Out-Null } catch { }
        }
        if (-not $server.WaitForExit(10000)) {
            # Cleanup only this test-created process tree; a forced kill never passes the test.
            & taskkill.exe /PID $server.Id /T /F 2>&1 | Out-Null
            if (-not $server.WaitForExit(10000)) { throw 'Owned test process did not stop; cleanup is not complete' }
        }
    }
    } finally {
        Complete-TestWorkspace -Path $testRoot -KeepWorkspace:$KeepWorkspace
    }
}
Write-Host 'WINDOWS JUPYTERLAB ACCEPTANCE: SUCCESS'
