$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'workspace.ps1')
$workspace = $null
try {
    $originalBase = $TestWorkspaceBase
    try {
        $script:TestWorkspaceBase = Join-Path ([IO.Path]::GetTempPath()) ('portable-test-rejected-' + [guid]::NewGuid().ToString('N'))
        $blocked = $false
        try { New-TestWorkspace 'cleanup' | Out-Null } catch { $blocked = $true }
        if (-not $blocked -or (Test-Path -LiteralPath $TestWorkspaceBase)) { throw 'Temp workspace was not rejected before creation' }
    } finally { $script:TestWorkspaceBase = $originalBase }
    $workspace = New-TestWorkspace 'cleanup'
    $nested = Join-Path $workspace 'nested'
    [IO.Directory]::CreateDirectory($nested) | Out-Null
    [IO.File]::WriteAllText((Join-Path $nested 'probe.txt'), 'test')
    Complete-TestWorkspace -Path $workspace -KeepWorkspace
    if (-not [IO.File]::Exists((Join-Path $nested 'probe.txt'))) { throw 'Explicit retention failed' }
    $blocked = $false
    try { New-TestWorkspace 'cleanup' | Out-Null } catch { $blocked = $true }
    if (-not $blocked) { throw 'Another workspace was allowed to accumulate' }
    $blocked = $false
    try { Complete-TestWorkspace -Path $TestWorkspaceBase } catch { $blocked = $true }
    if (-not $blocked) { throw 'Cleanup accepted a broad root' }
    $owner = Join-Path $workspace '.test-owner'
    $identity = [IO.File]::ReadAllText($owner)
    [IO.File]::WriteAllText($owner, 'wrong-owner')
    try {
        $blocked = $false
        try { Complete-TestWorkspace -Path $workspace } catch { $blocked = $true }
        if (-not $blocked -or -not [IO.File]::Exists($owner)) { throw 'Ownership guard failed' }
    } finally { [IO.File]::WriteAllText($owner, $identity) }
    Complete-TestWorkspace -Path $workspace
    if (Test-Path -LiteralPath $workspace) { throw 'Successful cleanup left files' }
    $workspace = New-TestWorkspace 'cleanup'
    try { throw 'simulated test failure' } catch {
        if ($_.Exception.Message -ne 'simulated test failure') { throw }
    } finally { Complete-TestWorkspace -Path $workspace }
    if (Test-Path -LiteralPath $workspace) { throw 'Failure-path cleanup left files' }

    # Invalid input must also clean workspaces before any runtime download.
    foreach ($test in @('application.ps1', 'jupyterlab.ps1')) {
        $failed = $false
        try { & (Join-Path $PSScriptRoot $test) -Zip (Join-Path $PSScriptRoot 'nonexistent-test-input.zip') } catch { $failed = $true }
        if (-not $failed) { throw 'Missing ZIP was accepted' }
        $profile = if ($test -eq 'application.ps1') { 'application' } else { 'jupyterlab' }
        if (@([IO.Directory]::EnumerateDirectories($TestWorkspaceBase, "$profile-*")).Count) {
            throw 'Early test failure leaked its workspace'
        }
    }
    Write-Host 'WORKSPACE CLEANUP ACCEPTANCE: SUCCESS'
} finally {
    if ($workspace -and (Test-Path -LiteralPath $workspace)) {
        Complete-TestWorkspace -Path $workspace
    }
}
