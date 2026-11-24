[CmdletBinding()]
param()

$Root = $PSScriptRoot
. (Join-Path $Root 'portable-common.ps1')
$originalEncoding = [Console]::OutputEncoding
$originalLocation = Get-Location
$stage = $null
$setupLock = $null
$setupLog = $null
$code = 10

function Write-SetupNote([string]$Message) {
    $text = $Message.Replace($Root, '<starter>').Replace($env:USERPROFILE, '<profile>')
    $text = $text -replace '(?i)(https?://)[^\s/@]+@', '$1<redacted>@'
    $text = ($text -replace '(?i)(https?://[^?\s]+)\?[^\s]+', '$1?<redacted>') -replace '[\x00-\x1F\x7F]', ' '
    Write-Host $text
    if ($null -ne $setupLog) {
        [IO.File]::AppendAllText($setupLog, ([DateTime]::UtcNow.ToString('o') + ' ' + $text + [Environment]::NewLine), $Utf8)
    }
}

function Invoke-SetupStep([string]$Step, [string]$Exe, [string[]]$Arguments) {
    Write-SetupNote "BEGIN: $Step"
    Invoke-Checked $Step $Exe $Arguments 6>&1 | ForEach-Object { Write-SetupNote ([string]$_) }
    Write-SetupNote "PASS: $Step"
}

function Save-VerifiedDownload([uri]$Source, [string]$Destination, [string]$ExpectedHash, [string]$Artifact) {
    $uri = $Source
    # Check every destination before sending its request, including redirects.
    $hosts = @('releases.astral.sh', 'raw.githubusercontent.com', 'github.com', 'release-assets.githubusercontent.com')
    for ($hop = 0; $hop -lt 6; $hop++) {
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Host -notin $hosts) {
            throw "Unapproved download destination for $Artifact."
        }
        Write-SetupNote "GET: $($uri.GetLeftPart([UriPartial]::Path))"
        $request = [Net.WebRequest]::CreateHttp($uri)
        $request.AllowAutoRedirect = $false
        $request.Timeout = 60000
        $request.ReadWriteTimeout = 60000
        if ($null -ne $request.Proxy) { $request.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials }
        try { $response = $request.GetResponse() }
        catch { throw "Download failed for $Artifact from $($uri.Host): $($_.Exception.Message)" }
        try {
            $status = [int]$response.StatusCode
            if ($status -in @(301,302,303,307,308)) {
                $location = $response.Headers['Location']
                if (-not $location) { throw "Redirect without Location for $Artifact." }
                $uri = [uri]::new($uri, $location)
                continue
            }
            if ($status -ne 200) { throw "Unexpected HTTP $status for $Artifact." }
            $output = [IO.File]::Open($Destination, 'CreateNew')
            try { $response.GetResponseStream().CopyTo($output) } finally { $output.Dispose() }
        } finally { $response.Dispose() }
        $actual = Get-Hash $Destination
        if ($actual -cne $ExpectedHash) { throw "SHA-256 mismatch for $Artifact (expected $ExpectedHash; got $actual)." }
        Write-SetupNote "SHA-256 VERIFIED: $Artifact $actual"
        return [ordered]@{ file = $Artifact; url = $Source.AbsoluteUri; sha256 = $actual; verification = 'pinned SHA-256' }
    }
    throw "Too many download redirects for $Artifact."
}

function Remove-PreparationScratch([string]$Path) {
    # Only for this invocation's own scratch directory. Antivirus/file handles
    # can briefly hold freshly extracted binaries on Windows.
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            if ([IO.Directory]::Exists($Path)) { [IO.Directory]::Delete($Path, $true) }
            return
        } catch {
            if ($attempt -eq 2) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}
try {
    [Console]::OutputEncoding = $Utf8
    Assert-LocalWindows $Root
    $setupLock = Open-WorkspaceLock (Join-Path $Root '.prepare.lock')
    $logPath = Join-Path $Root 'setup.log'
    if (Test-Path -LiteralPath $logPath) { Assert-NotLinked (Get-Item -LiteralPath $logPath -Force) }
    [IO.File]::WriteAllText($logPath, '', $Utf8)
    $setupLog = $logPath
    $destination = Join-Path $Root 'bundle'
    $destinationZip = Join-Path $Root 'prepared-app.zip'
    if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $destinationZip)) {
        throw 'bundle/ or prepared-app.zip already exists. Move the previous outputs aside or use a fresh starter folder.'
    }
    if (@(Get-ChildItem -LiteralPath $Root -Directory -Force -Filter '.prepare-*').Count) {
        throw 'An earlier preparation is active or was interrupted. Review its .prepare-* folder before retrying.'
    }

    $project = Join-Path $Root 'pyproject.toml'
    $pins = Read-Pins $project
    $pythonVersion = $pins['requires-python']
    $uvVersion = $pins['required-version']
    $request = "cpython-$pythonVersion-windows-x86_64-none"
    $uvUrl = "https://releases.astral.sh/github/uv/releases/download/$uvVersion/uv-x86_64-pc-windows-msvc.zip"
    Write-SetupNote "PREPARE (ONLINE): CPython $pythonVersion, uv $uvVersion"

    $stage = Join-Path $Root ('.prepare-' + [guid]::NewGuid().ToString('N'))
    $bundle = Join-Path $stage 'bundle'
    $work = Join-Path $stage 'work'
    [IO.Directory]::CreateDirectory($bundle) | Out-Null
    Set-LocalEnvironment $work
    Set-Location -LiteralPath $bundle
    foreach ($name in @('START.bat', 'portable-python.ps1', 'portable-common.ps1', 'pyproject.toml',
                       'README.txt', 'LICENSE', 'THIRD_PARTY.md')) {
        $source = Get-Item -LiteralPath (Join-Path $Root $name) -Force
        Assert-NotLinked $source
        [IO.File]::Copy($source.FullName, (Join-Path $bundle $name))
    }
    $sourceLock = Join-Path $Root 'uv.lock'
    $reuseLock = Test-Path -LiteralPath $sourceLock
    if ($reuseLock) {
        Assert-NotLinked (Get-Item -LiteralPath $sourceLock -Force)
        [IO.File]::Copy($sourceLock, (Join-Path $bundle 'uv.lock'))
        Write-SetupNote 'Using supplied uv.lock; changes require a new lock. No fallback to resolution.'
    } else {
        Write-SetupNote 'No uv.lock supplied; resolving from PyPI.'
    }
    $appRoot = Join-Path $Root 'application'
    Assert-NotLinked (Get-Item -LiteralPath $appRoot -Force)
    foreach ($name in @('__main__.py', '__init__.py')) {
        if (-not [IO.File]::Exists((Join-Path $appRoot $name))) { throw "Missing application/$name" }
    }
    Get-TreeFiles $appRoot | ForEach-Object {
        $relative = $_.FullName.Substring($Root.Length + 1)
        if ($relative -match '(?:^|\\)(?:__pycache__|\.venv|\.git)(?:\\|$)' -or $relative -match '\.py[co]$') {
            throw 'Remove generated bytecode, nested venvs and git metadata from application/ before preparing.'
        }
        $target = Join-Path $bundle $relative
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
        [IO.File]::Copy($_.FullName, $target)
    }

    # These downloads run only on the setup machine. Keep TLS validation on.
    $archive = Join-Path $work 'uv.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $downloads = @(Save-VerifiedDownload $uvUrl $archive $pins['uv-archive-sha256'] 'uv-x86_64-pc-windows-msvc.zip')
    $notices = Join-Path $bundle 'licenses'
    [IO.Directory]::CreateDirectory($notices) | Out-Null
    foreach ($license in @('mit', 'apache')) {
        $upstreamFile = "LICENSE-$($license.ToUpperInvariant())"
        $licenseUrl = "https://raw.githubusercontent.com/astral-sh/uv/$uvVersion/$upstreamFile"
        $downloads += Save-VerifiedDownload $licenseUrl (Join-Path $notices "uv-$upstreamFile") $pins["uv-license-$license-sha256"] "licenses/uv-$upstreamFile"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extract = Join-Path $work 'uv'
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $extract)
    $uv = Join-Path $bundle 'uv.exe'
    [IO.File]::Move((Join-Path $extract 'uv.exe'), $uv)
    if ((Get-Hash $uv) -ne $pins['uv-exe-sha256']) { throw 'uv.exe failed pinned SHA-256 verification.' }
    Write-SetupNote "SHA-256 VERIFIED: uv.exe $($pins['uv-exe-sha256'])"
    $reported = & $uv --version
    if ($LASTEXITCODE -ne 0 -or $reported -notmatch ('^uv ' + [regex]::Escape($uvVersion) + '\b')) {
        throw 'Unexpected uv version.'
    }

    $catalogJson = & $uv --no-config python list $request --all-versions --all-platforms --all-arches --only-downloads --show-urls --output-format json
    if ($LASTEXITCODE -ne 0) { throw 'uv could not inspect the managed CPython catalog.' }
    $catalog = @($catalogJson | ConvertFrom-Json)
    if ($catalog.Count -ne 1 -or $catalog[0].key -cne $request) {
        throw "CPython $pythonVersion is not in the selected uv Windows x86-64 catalog."
    }
    $pythonUrl = [string]$catalog[0].url
    $pattern = '^https://releases\.astral\.sh/github/python-build-standalone/releases/download/(?<release>[0-9]{8})/(?<file>cpython-' +
        [regex]::Escape($pythonVersion) + '%2B\k<release>-x86_64-pc-windows-msvc-install_only_stripped\.tar\.gz)$'
    if ($pythonUrl -cnotmatch $pattern) {
        throw 'The catalog selected an unexpected CPython archive URL.'
    }
    $mirror = Join-Path $work 'python-archive'
    $releaseFolder = Join-Path $mirror $Matches['release']
    $pythonFile = [Uri]::UnescapeDataString($Matches['file'])
    [IO.Directory]::CreateDirectory($releaseFolder) | Out-Null
    $downloads += Save-VerifiedDownload $pythonUrl (Join-Path $releaseFolder $pythonFile) $pins['python-archive-sha256'] $pythonFile
    $installDir = Join-Path $work 'python'
    Invoke-SetupStep 'python_install_from_verified_archive' $uv @(
        '--offline', '--no-config', 'python', 'install', $request,
        '--mirror', ([uri]::new($mirror).AbsoluteUri), '--install-dir', $installDir, '--no-bin', '--no-registry'
    )
    $runtime = Join-Path $bundle 'runtime'
    [IO.Directory]::Move((Join-Path $installDir $request), $runtime)
    Get-TreeFiles $runtime | Out-Null
    $python = Join-Path $runtime 'python.exe'
    $helper = Join-Path $Root 'prepare.py'
    $pythonFlags = @('-I', '-S', '-B', '-X', 'utf8', $helper)
    Invoke-SetupStep 'project_policy_check' $python ($pythonFlags + @('validate', (Join-Path $bundle 'pyproject.toml'), $pythonVersion, $uvVersion))
    $index = 'https://pypi.org/simple'
    $flags = @('--no-config', '--system-certs', '--no-python-downloads')
    if (-not $reuseLock) {
        Invoke-SetupStep 'dependency_lock' $uv ($flags + @(
            'lock', '--project', $bundle, '--python', $python, '--no-sources', '--no-build', '--default-index', $index
        ))
    }
    Invoke-SetupStep 'export_install_plan' $uv ($flags + @(
        '--offline', 'export', '--project', $bundle, '--python', $python, '--locked', '--no-default-groups',
        '--no-emit-project', '--no-header', '--format', 'requirements.txt',
        '--output-file', (Join-Path $bundle 'install-plan.txt'), '--quiet'
    ))
    $provenance = [ordered]@{
        schema = 1
        python = $pythonVersion
        uv = $uvVersion
        uv_exe_sha256 = $pins['uv-exe-sha256']
        index = $index
        uv_lock_sha256 = Get-Hash (Join-Path $bundle 'uv.lock')
        downloads = $downloads
    }
    [IO.File]::WriteAllText((Join-Path $bundle 'provenance.json'), ($provenance | ConvertTo-Json -Depth 4), $Utf8)
    Invoke-SetupStep 'download_wheelhouse' $python ($pythonFlags + @('wheels', $bundle, $pythonVersion))
    # Fresh venv and no retained cache. Fail if the exact target command fails
    # without network, even if every downloaded file passed its own checksum.
    Write-SetupNote 'BEGIN: trial offline installation'
    Set-LocalEnvironment (Join-Path $work 'offline')
    $probeVenv = Join-Path $work 'probe-venv'
    Initialize-OfflineVenv $bundle $probeVenv 6>&1 | ForEach-Object { Write-SetupNote ([string]$_) }
    $inventory = Join-Path $work 'installed-packages.txt'
    [IO.File]::WriteAllLines($inventory, [string[]]@(Read-EnvironmentPackages $probeVenv $pythonVersion $python), $Utf8)
    Write-SetupNote 'PASS: trial offline installation'
    Invoke-SetupStep 'manifest' $python ($pythonFlags + @('manifest', $bundle, $inventory))

    $stagedZip = Join-Path $stage 'prepared-app.zip'
    Invoke-SetupStep 'transfer_zip' $python ($pythonFlags + @('zip', $bundle, $stagedZip))
    $zipHash = Get-Hash $stagedZip
    Set-Location -LiteralPath $Root
    Remove-PreparationScratch $work
    [IO.Directory]::Move($bundle, $destination)
    [IO.File]::Move($stagedZip, $destinationZip)
    Write-SetupNote 'Transfer artifact: prepared-app.zip'
    Write-SetupNote "ZIP SHA-256: $zipHash"
    Write-SetupNote 'PREPARATION SUCCESS: transfer prepared-app.zip, not the starter folder.'
    $code = 0
} catch {
    $problem = $_.Exception.Message
    try { Write-SetupNote "PREPARATION FAILED: $problem" }
    catch { Write-Host 'PREPARATION FAILED; setup.log was not writable.' -ForegroundColor Red }
} finally {
    Set-Location -LiteralPath $originalLocation.Path
    [Console]::OutputEncoding = $originalEncoding
    if ($null -ne $stage -and [IO.Directory]::Exists($stage)) {
        try {
            Remove-PreparationScratch $stage
        } catch {
            Write-Host "PREPARATION CLEANUP FAILED: review the retained .prepare-* folder before retrying. $($_.Exception.Message)" -ForegroundColor Red
            $code = 10
        }
    }
    if ($null -ne $setupLock) { $setupLock.Dispose() }
}
exit $code
