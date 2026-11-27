[CmdletBinding()]
param()

$Root = $PSScriptRoot
. (Join-Path $Root 'portable-common.ps1')
$originalEncoding = [Console]::OutputEncoding
$originalLocation = Get-Location
$stage = $null
$setupLock = $null
$setupLog = $null
$setupPhase = 'Preflight'
$setupTimer = [Diagnostics.Stopwatch]::StartNew()
$phaseTimer = [Diagnostics.Stopwatch]::new()
$code = 10

function Read-Pins([string]$Path) {
    Assert-NotLinked (Get-Item -LiteralPath $Path -Force)
    $text = [IO.File]::ReadAllText($Path, $Utf8)
    $pins = @{}
    foreach ($entry in @(
        @('project', 'requires-python', '==(?<value>3\.(?:11|12|13|14|15)\.\d+)'),
        @('tool.uv', 'required-version', '==(?<value>\d+\.\d+\.\d+)'),
        @('tool.portable-python', 'uv-archive-sha256', '(?<value>[0-9a-fA-F]{64})'),
        @('tool.portable-python', 'uv-exe-sha256', '(?<value>[0-9a-fA-F]{64})'),
        @('tool.portable-python', 'uv-license-mit-sha256', '(?<value>[0-9a-fA-F]{64})'),
        @('tool.portable-python', 'uv-license-apache-sha256', '(?<value>[0-9a-fA-F]{64})'),
        @('tool.portable-python', 'python-archive-sha256', '(?<value>[0-9a-fA-F]{64})')
    )) {
        $section, $key, $pattern = $entry
        $tables = [regex]::Matches($text, '(?ms)^[ \t]*\[' + [regex]::Escape($section) + '\][ \t]*(?:#[^\r\n]*)?\r?\n(?<body>.*?)(?=^[ \t]*\[|\z)')
        if ($tables.Count -ne 1) { throw "Expected one [$section] table in pyproject.toml." }
        $matched = [regex]::Matches($tables[0].Groups['body'].Value, '(?m)^[ \t]*' + [regex]::Escape($key) + '[ \t]*=[ \t]*"' + $pattern + '"[ \t]*(?:#[^\r\n]*)?\r?$')
        if ($matched.Count -ne 1) { throw "Invalid exact $section.$key pin in pyproject.toml." }
        $pins[$key] = $matched[0].Groups['value'].Value.ToLowerInvariant()
    }
    if ([version]$pins['required-version'] -lt [version]'0.13.10') {
        throw 'uv must be at least 0.13.10.'
    }
    return $pins
}

function Write-SetupNote([string]$Message, [string]$Level = 'INFO') {
    $text = $Message
    foreach ($entry in @(@($Root, '<starter>'), @($env:USERPROFILE, '<profile>'))) {
        $path, $replacement = $entry
        if ($path) {
            $text = ($text -ireplace [regex]::Escape($path), $replacement) -ireplace [regex]::Escape($path.Replace('\', '/')), $replacement
        }
    }
    $text = $text -replace '(?i)(https?://)[^\s/@]+@', '$1<redacted>@'
    $text = ($text -replace '(?i)(https?://[^?#\s]+)[?#][^\s]*', '$1?<redacted>') -replace '[\x00-\x1F\x7F-\x9F]', ' '
    if (-not $text.Trim()) { return }
    if ($null -ne $setupLog) {
        $stamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss.fff 'UTC'", [Globalization.CultureInfo]::InvariantCulture)
        [IO.File]::AppendAllText($setupLog, "$stamp | $Level | $setupPhase | $text" + [Environment]::NewLine, $Utf8)
    }
    Write-Host "[$setupPhase] $text"
}

function Format-Duration([Diagnostics.Stopwatch]$Timer) {
    return $Timer.Elapsed.ToString('hh\:mm\:ss\.fff', [Globalization.CultureInfo]::InvariantCulture)
}

function Start-SetupPhase([string]$Name, [string]$Mode = 'local') {
    $script:setupPhase = $Name
    $phaseTimer.Restart()
    Write-SetupNote "BEGIN ($Mode)"
}

function Complete-SetupPhase {
    Write-SetupNote "PASS (elapsed $(Format-Duration $phaseTimer))"
}

function Invoke-SetupCommand([string]$Step, [string]$Exe, [string[]]$Arguments) {
    Invoke-Checked $Step $Exe $Arguments 6>&1 | ForEach-Object { Write-SetupNote ([string]$_) 'DETAIL' }
}

function Save-VerifiedDownload([uri]$Source, [string]$Destination, [string]$ExpectedHash, [string]$Artifact) {
    $uri = $Source
    # Check every destination before sending its request, including redirects.
    $hosts = @('releases.astral.sh', 'raw.githubusercontent.com', 'github.com', 'release-assets.githubusercontent.com')
    for ($hop = 0; $hop -lt 6; $hop++) {
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Host -notin $hosts) {
            $origin = if ($uri.IsAbsoluteUri) { "$($uri.Scheme)://$($uri.Host):$($uri.Port)" } else { '<relative URL>' }
            throw "Blocked unapproved download destination for ${Artifact}: $origin. No request was sent to it."
        }
        Write-SetupNote "GET: $($uri.GetLeftPart([UriPartial]::Path)) ($Artifact)"
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
                Write-SetupNote "HTTP $status redirect for $Artifact; next URL must pass the HTTPS allowlist."
                $location = $response.Headers['Location']
                if (-not $location) { throw "Redirect without Location for $Artifact." }
                $uri = [uri]::new($uri, $location)
                continue
            }
            if ($status -ne 200) { throw "Unexpected HTTP $status for $Artifact." }
            $output = [IO.File]::Open($Destination, 'CreateNew')
            try {
                $response.GetResponseStream().CopyTo($output)
                Write-SetupNote "HTTP $status received $($output.Length) bytes: $Artifact"
            } finally { $output.Dispose() }
        } finally { $response.Dispose() }
        $actual = Get-Hash $Destination
        if ($actual -cne $ExpectedHash) { throw "SHA-256 mismatch for $Artifact (expected $ExpectedHash; got $actual)." }
        Write-SetupNote "SHA-256 VERIFIED: $Artifact $actual (pyproject.toml pin)"
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
    Start-SetupPhase 'Preflight'
    Write-SetupNote 'SETUP on the online setup machine. Target: Windows 11 x86-64. No application code will run.'
    $destination = Join-Path $Root 'bundle'
    $destinationRecords = Join-Path $Root 'bundle-records'
    foreach ($output in @($destination, $destinationRecords)) {
        if (Test-Path -LiteralPath $output) {
            throw 'A SETUP output already exists. Use a fresh starter folder or move bundle/ and bundle-records/ aside.'
        }
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
    Write-SetupNote "Requested in pyproject.toml: CPython $pythonVersion; uv $uvVersion."

    # Already protected by the exclusive lock and the stale-scratch check.
    $stage = Join-Path $Root '.prepare-work'
    $bundle = Join-Path $stage 'bundle'
    $records = Join-Path $stage 'records'
    $work = Join-Path $stage 'w'
    [IO.Directory]::CreateDirectory($bundle) | Out-Null
    [IO.Directory]::CreateDirectory($records) | Out-Null
    Set-LocalEnvironment $work
    Set-Location -LiteralPath $bundle
    foreach ($name in @('START.bat', 'portable-python.ps1', 'portable-common.ps1')) {
        $source = Get-Item -LiteralPath (Join-Path $Root $name) -Force
        Assert-NotLinked $source
        [IO.File]::Copy($source.FullName, (Join-Path $bundle $name))
    }
    [IO.File]::Copy($project, (Join-Path $records 'pyproject.toml'))
    $projectHash = Get-Hash (Join-Path $records 'pyproject.toml')
    Write-SetupNote "pyproject.toml SHA-256: $projectHash"
    $sourceLock = Join-Path $Root 'uv.lock'
    $reuseLock = Test-Path -LiteralPath $sourceLock
    if ($reuseLock) {
        Assert-NotLinked (Get-Item -LiteralPath $sourceLock -Force)
        [IO.File]::Copy($sourceLock, (Join-Path $records 'uv.lock'))
        $suppliedLockHash = Get-Hash (Join-Path $records 'uv.lock')
        Write-SetupNote 'Using supplied uv.lock unchanged; a stale lock fails instead of triggering resolution.'
    } else {
        Write-SetupNote 'No uv.lock supplied; one will be resolved from PyPI on the online setup machine.'
    }
    Complete-SetupPhase
    Start-SetupPhase 'uv and license downloads' 'internet'
    Write-SetupNote 'HTTPS/TLS verification on; allowed hosts: releases.astral.sh, raw.githubusercontent.com, github.com, release-assets.githubusercontent.com. Redirects are checked before each request; Windows proxy settings apply.'
    # These downloads run only on the setup machine. Keep TLS validation on.
    $archive = Join-Path $work 'uv.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $downloads = @(Save-VerifiedDownload $uvUrl $archive $pins['uv-archive-sha256'] 'uv-x86_64-pc-windows-msvc.zip')
    $launcherLicense = Get-Item -LiteralPath (Join-Path $Root 'LICENSE') -Force
    Assert-NotLinked $launcherLicense
    $notices = @('Portable Python launcher (MIT)', [IO.File]::ReadAllText($launcherLicense.FullName, $Utf8))
    foreach ($license in @('mit', 'apache')) {
        $upstreamFile = "LICENSE-$($license.ToUpperInvariant())"
        $licenseUrl = "https://raw.githubusercontent.com/astral-sh/uv/$uvVersion/$upstreamFile"
        $notice = Join-Path $work "uv-$upstreamFile"
        $downloads += Save-VerifiedDownload $licenseUrl $notice $pins["uv-license-$license-sha256"] "uv-$upstreamFile"
        $notices += @("uv $uvVersion - $upstreamFile", [IO.File]::ReadAllText($notice, $Utf8))
    }

    Complete-SetupPhase
    Start-SetupPhase 'Verify and inspect uv'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extract = Join-Path $work 'uv'
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $extract)
    $uv = Join-Path $extract 'uv.exe'
    if ((Get-Hash $uv) -ne $pins['uv-exe-sha256']) { throw 'uv.exe failed pinned SHA-256 verification.' }
    Write-SetupNote "SHA-256 VERIFIED: uv.exe $($pins['uv-exe-sha256']) (pyproject.toml pin; extracted locally)"
    $reported = & $uv --version
    if ($LASTEXITCODE -ne 0 -or $reported -notmatch ('^uv ' + [regex]::Escape($uvVersion) + '\b')) {
        throw 'Unexpected uv version.'
    }
    Write-SetupNote "Executable reports: $reported"

    $catalogJson = & $uv --offline --no-config python list $request --all-versions --all-platforms --all-arches --only-downloads --show-urls --output-format json
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
    Write-SetupNote "Local uv catalog selected $request from build $($Matches['release'])."
    $mirror = Join-Path $work 'p'
    $releaseFolder = Join-Path $mirror $Matches['release']
    $pythonFile = [Uri]::UnescapeDataString($Matches['file'])
    [IO.Directory]::CreateDirectory($releaseFolder) | Out-Null
    Complete-SetupPhase
    Start-SetupPhase 'CPython archive download' 'internet'
    $downloads += Save-VerifiedDownload $pythonUrl (Join-Path $releaseFolder $pythonFile) $pins['python-archive-sha256'] $pythonFile
    $installDir = Join-Path $work 'python'
    Complete-SetupPhase
    Start-SetupPhase 'Install CPython locally'
    Write-SetupNote 'Installing CPython from the verified local archive. uv may say "Downloading" while reading this local file; no network is used in this step.'
    Invoke-SetupCommand 'python_install_from_verified_archive' $uv @(
        '--offline', '--no-config', 'python', 'install', $request,
        '--mirror', ([uri]::new($mirror).AbsoluteUri), '--install-dir', $installDir, '--no-bin', '--no-registry'
    )
    $runtime = Join-Path $bundle 'runtime'
    [IO.Directory]::Move((Join-Path $installDir $request), $runtime)
    Get-TreeFiles $runtime | Out-Null
    $bundledUv = Join-Path $runtime 'uv.exe'
    [IO.File]::Move($uv, $bundledUv)
    $uv = $bundledUv
    [IO.File]::WriteAllText((Join-Path $runtime 'BUNDLE-LICENSES.txt'), ($notices -join "`n`n"), $Utf8)
    $python = Join-Path $runtime 'python.exe'
    $helper = Join-Path $Root 'prepare.py'
    $pythonFlags = @('-I', '-S', '-B', '-X', 'utf8', $helper)
    Complete-SetupPhase
    Start-SetupPhase 'Validate project settings'
    Invoke-SetupCommand 'project_policy_check' $python ($pythonFlags + @('validate', (Join-Path $records 'pyproject.toml'), $pythonVersion, $uvVersion))
    Complete-SetupPhase
    $index = 'https://pypi.org/simple'
    $flags = @('--no-config', '--system-certs', '--no-python-downloads')
    if (-not $reuseLock) {
        Start-SetupPhase 'Resolve dependency lock' 'internet metadata'
        Write-SetupNote "PyPI index: $index. uv may also read package metadata from files.pythonhosted.org. TLS uses system trust; metadata is not hash-pinned. No source builds or Python downloads."
        Write-SetupNote 'Resolution policy: highest compatible versions, using the pinned uv version. Save the generated uv.lock for replay.'
        Write-SetupNote 'uv may read metadata for other platforms. Only compatible Windows x86-64 or platform-independent wheels are bundled in the wheel download phase.'
        $previousRustLog = $env:RUST_LOG
        try {
            # Request/cache diagnostics, not verbose HTTP header or credential tracing.
            $env:RUST_LOG = 'warn,uv_client::cached_client=debug'
            Invoke-SetupCommand 'dependency_lock' $uv ($flags + @(
                'lock', '--project', $records, '--python', $python, '--no-sources', '--no-build', '--resolution', 'highest', '--default-index', $index
            ))
        } finally { $env:RUST_LOG = $previousRustLog }
        Complete-SetupPhase
    }
    Start-SetupPhase 'Export offline install plan'
    Invoke-SetupCommand 'export_install_plan' $uv ($flags + @(
        '--offline', 'export', '--project', $records, '--python', $python, '--locked', '--no-default-groups',
        '--no-emit-project', '--no-header', '--format', 'requirements.txt',
        '--output-file', (Join-Path $bundle 'install-plan.txt'), '--quiet'
    ))
    $lockHash = Get-Hash (Join-Path $records 'uv.lock')
    if ($reuseLock -and $lockHash -cne $suppliedLockHash) {
        throw 'The supplied uv.lock changed during export.'
    }
    Write-SetupNote "uv.lock SHA-256: $lockHash; exported hashed requirements to install-plan.txt."
    Complete-SetupPhase
    Start-SetupPhase 'Wheel downloads' 'internet if wheels are needed'
    Write-SetupNote 'Only locked HTTPS wheel URLs on files.pythonhosted.org/packages/ are allowed. Redirects are rejected; each wheel must match its uv.lock SHA-256.'
    $provenance = [ordered]@{
        schema = 1
        python = $pythonVersion
        uv = $uvVersion
        uv_exe_sha256 = $pins['uv-exe-sha256']
        index = $index
        pyproject_sha256 = $projectHash
        uv_lock_sha256 = $lockHash
        downloads = $downloads
    }
    [IO.File]::WriteAllText((Join-Path $records 'provenance.json'), ($provenance | ConvertTo-Json -Depth 4), $Utf8)
    Invoke-SetupCommand 'download_wheelhouse' $python ($pythonFlags + @('wheels', $bundle, $records, $pythonVersion))
    Complete-SetupPhase
    # Fresh venv and no retained cache. Fail if the exact target command fails
    # without network, even if every downloaded file passed its own checksum.
    Start-SetupPhase 'Trial offline installation'
    Write-SetupNote 'Create a temporary .venv from runtime/ and install only from local wheels with required hashes. Check dependency metadata; no app or package imports are tested.'
    Set-LocalEnvironment (Join-Path $work 'offline')
    $probeVenv = Join-Path $work 'probe-venv'
    Initialize-OfflineVenv $bundle $probeVenv 6>&1 | ForEach-Object { Write-SetupNote ([string]$_) 'DETAIL' }
    $inventory = Join-Path $work 'installed-packages.txt'
    $packages = @(Read-EnvironmentPackages $probeVenv $pythonVersion $python)
    [IO.File]::WriteAllLines($inventory, [string[]]$packages, $Utf8)
    Write-SetupNote "Verified isolated CPython and recorded $($packages.Count) installed distribution(s)."
    Complete-SetupPhase
    Start-SetupPhase 'Write bundle manifest'
    Invoke-SetupCommand 'manifest' $python ($pythonFlags + @('manifest', $bundle, $inventory, $pythonVersion, $uvVersion))
    $manifestHash = Get-Hash (Join-Path $bundle 'bundle-manifest.json')
    Write-SetupNote "bundle-manifest.json SHA-256: $manifestHash (prepared environment fingerprint, not a Transfer ZIP hash)."
    Complete-SetupPhase
    Start-SetupPhase 'Normalize output timestamps'
    Invoke-SetupCommand 'normalize_timestamps' $python ($pythonFlags + @('normalize', $bundle, $records))
    Complete-SetupPhase

    Start-SetupPhase 'Publish prepared folder'
    Set-Location -LiteralPath $Root
    Remove-PreparationScratch $work
    [IO.Directory]::Move($bundle, $destination)
    [IO.Directory]::Move($records, $destinationRecords)
    Write-SetupNote 'Published prepared folder bundle/ and online build records bundle-records/. No Transfer ZIP was created.'
    Complete-SetupPhase
    $code = 0
} catch {
    $problem = $_.Exception.Message
    try { Write-SetupNote "FAILED: $problem" 'ERROR' }
    catch { Write-Host 'SETUP FAILED; setup.log was not writable.' -ForegroundColor Red }
} finally {
    Set-Location -LiteralPath $originalLocation.Path
    if ($null -ne $stage -and [IO.Directory]::Exists($stage)) {
        $script:setupPhase = 'Cleanup'
        try {
            Remove-PreparationScratch $stage
            Write-SetupNote 'Removed .prepare-work/ (including any temporary trial environment).'
        } catch {
            $code = 10
            try { Write-SetupNote "Cleanup failed: $($_.Exception.Message) Review the retained .prepare-* folder before retrying." 'ERROR' }
            catch { Write-Host 'SETUP cleanup could not be recorded in setup.log.' -ForegroundColor Red }
        }
    }
    try {
        $script:setupPhase = 'Result'
        if ($code -eq 0) {
            Write-SetupNote 'Next: IT reviews the prepared folder, adds application/, input/, workings/ and output/, and creates the Transfer ZIP.'
            Write-SetupNote 'Keep setup.log and bundle-records/ on the online setup machine.'
            Write-SetupNote "SUCCESS (exit 0; elapsed $(Format-Duration $setupTimer))"
        } else {
            Write-SetupNote "FAILURE (exit $code; elapsed $(Format-Duration $setupTimer))" 'ERROR'
        }
    } catch {
        $code = 10
        Write-Host 'SETUP FAILED; setup.log was not writable.' -ForegroundColor Red
    } finally {
        [Console]::OutputEncoding = $originalEncoding
        if ($null -ne $setupLock) { $setupLock.Dispose() }
    }
}
exit $code
