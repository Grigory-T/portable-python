# Test-only workspace ownership and cleanup. Never use user/system Temp for
# expanded runtimes, environments or caches. This file is not shipped in ZIPs.
$script:TestWorkspaceBase = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.test-workspaces'))

function New-TestWorkspace {
    param([ValidateSet('application', 'jupyterlab', 'cleanup')][string]$Profile)
    $tempPaths = @([IO.Path]::GetTempPath(), $env:TEMP, $env:TMP)
    if ($env:SystemRoot) { $tempPaths += (Join-Path $env:SystemRoot 'Temp') }
    foreach ($tempPath in $tempPaths) {
        if (-not $tempPath) { continue }
        $tempRoot = [IO.Path]::GetFullPath($tempPath).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
        if ($TestWorkspaceBase -eq $tempRoot -or
            $TestWorkspaceBase.StartsWith($tempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Move the test checkout outside user/system Temp before running tests.'
        }
    }
    if ((Test-Path -LiteralPath $TestWorkspaceBase) -and
        ((Get-Item -LiteralPath $TestWorkspaceBase -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The test workspace base must not be a symbolic link or junction.'
    }
    if ([IO.Directory]::Exists($TestWorkspaceBase) -and
        @([IO.Directory]::EnumerateDirectories($TestWorkspaceBase, "$Profile-*")).Count) {
        throw "A previous $Profile test workspace remains. Review/remove it before running another test; do not accumulate environments."
    }
    $name = $Profile + '-' + [guid]::NewGuid().ToString('N')
    $path = Join-Path $TestWorkspaceBase $name
    [IO.Directory]::CreateDirectory($path) | Out-Null
    [IO.File]::WriteAllText((Join-Path $path '.test-owner'), $name)
    return $path
}

function Complete-TestWorkspace {
    param([string]$Path, [switch]$KeepWorkspace)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $name = [IO.Path]::GetFileName($fullPath)
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if ($parent -ne $TestWorkspaceBase -or $name -notmatch '^(application|jupyterlab|cleanup)-[a-f0-9]{32}$') {
        throw 'Refusing cleanup outside the exact test-created workspace.'
    }
    if (-not (Test-Path -LiteralPath $fullPath)) { return }
    if ((Get-Item -LiteralPath $fullPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Refusing cleanup of a linked test workspace.'
    }
    $owner = Join-Path $fullPath '.test-owner'
    if (-not [IO.File]::Exists($owner) -or [IO.File]::ReadAllText($owner) -ne $name) {
        throw 'Refusing cleanup without a matching test ownership marker.'
    }
    if ($KeepWorkspace) {
        Write-Warning "Explicitly retained test workspace: $fullPath. Remove it after diagnosis; do not copy it to Temp."
        return
    }
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            [IO.Directory]::Delete($fullPath, $true)
            Write-Host 'Test workspace removed.'
            return
        } catch {
            if ($attempt -eq 2) {
                throw "TEST CLEANUP FAILED: remove the owned workspace before another test: $fullPath"
            }
            Start-Sleep -Milliseconds 500
        }
    }
}
