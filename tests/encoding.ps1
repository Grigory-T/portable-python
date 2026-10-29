param(
    [Parameter(Mandatory=$true)][string]$Launcher,
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$TestRoot,
    [ValidateSet('Application','Jupyter')][string]$Profile
)
$ErrorActionPreference = 'Stop'
# Run the actual launcher in its own shell and capture its Information stream
# as strings, before a second byte-encoding step can disguise mojibake.
$driver = @'
param([string]$Launcher,[string]$Root,[string]$Profile)
$ErrorActionPreference = 'Stop'
$initialEncoding = [Console]::OutputEncoding
$inputCodePage = [Console]::InputEncoding.CodePage
$utf8 = New-Object Text.UTF8Encoding($false)
$text = ('"\u0424\u043e\u0440\u043c\u0438\u0440\u043e\u0432\u0430\u043d\u0438\u0435 | \u0401\u0451 | \u20ac | \u65e5\u672c\u8a9e | \ud83d\ude00"' | ConvertFrom-Json)
$projectPath = Join-Path $Root 'pyproject.toml'
$originalProject = [IO.File]::ReadAllBytes($projectPath)
$main = Join-Path $Root 'application\__main__.py'
$originalMain = if ($Profile -eq 'Application') { [IO.File]::ReadAllBytes($main) } else { $null }

function Invoke-Captured([int]$Expected,[int]$Page) {
    [Console]::OutputEncoding = [Text.Encoding]::GetEncoding($Page)
    $callArgs = @{NoPause=$true}
    if ($Profile -eq 'Jupyter') { $callArgs.SetupOnly = $true }
    $lines = @(& $Launcher @callArgs *>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    if ([Console]::OutputEncoding.CodePage -ne $Page) { throw 'Launcher did not restore console encoding' }
    if ([Console]::InputEncoding.CodePage -ne $inputCodePage) { throw 'Launcher changed console input encoding' }
    if ($code -ne $Expected) {
        $detail = (($lines | Select-Object -Last 15) -join "`n").Replace($Root, '<project>').Replace($env:USERNAME, '<account>')
        throw "Unexpected launcher exit: expected $Expected, got $code`n$detail"
    }
    return ($lines -join "`n")
}

try {
    if ($Profile -eq 'Application') {
        # No stream reconfiguration in the application or worker.
        $probe = @"
import subprocess
import sys
text = '\u0424\u043e\u0440\u043c\u0438\u0440\u043e\u0432\u0430\u043d\u0438\u0435 | \u0401\u0451 | \u20ac | \u65e5\u672c\u8a9e | \U0001f600'
assert sys.flags.utf8_mode == 1
assert sys.stdout.encoding.lower().replace('-', '') == 'utf8'
assert sys.stderr.encoding.lower().replace('-', '') == 'utf8'
print('UTF8_STDOUT|' + text, flush=True)
print('UTF8_STDERR|' + text, file=sys.stderr, flush=True)
print(text, flush=True)
sys.stderr.write(text + '\n\n')
sys.stderr.write('\rUTF8_PROGRESS|' + text + ': 0%| |0/112 [00:00<?, ?it/s]\r')
sys.stderr.write('UTF8_PROGRESS|' + text + ': 100%|#|112/112\n')
sys.stderr.flush()
code = 'import sys; assert sys.flags.utf8_mode == 1; print(' + repr(text) + ')'
child = subprocess.run([sys.executable, '-u', '-E', '-s', '-B', '-X', 'utf8', '-c', code], check=True, capture_output=True, text=True, encoding='utf-8')
assert child.stdout.strip() == text
print('UTF8_CHILD_SUCCESS')
"@
        [IO.File]::WriteAllText($main, $probe, $utf8)
        foreach ($page in @(437,866,1251,65001)) {
            $output = Invoke-Captured 0 $page
            foreach ($expected in @(('UTF8_STDOUT|' + $text), ('UTF8_STDERR|' + $text), ('UTF8_PROGRESS|' + $text), 'UTF8_CHILD_SUCCESS')) {
                if (-not $output.Contains($expected)) { throw "Unicode output mismatch at code page $page" }
            }
            if (@($output.Split("`n") | Where-Object { $_ -ceq $text }).Count -eq 0) { throw 'Cyrillic-only output line was lost' }
            if ($output.Contains('System.Management.Automation.RemoteException')) { throw 'Empty stderr was exposed as an exception type name' }
        }
        [IO.File]::WriteAllText($main, $probe + "`nraise SystemExit(7)`n", $utf8)
        $output = Invoke-Captured 20 866
        if (-not $output.Contains('UTF8_STDERR|' + $text)) { throw 'Unicode application error output was corrupted' }
        [IO.File]::WriteAllBytes($main, $originalMain)
        [IO.File]::AppendAllText($projectPath, "`n# changed configuration`n", $utf8)
        [void](Invoke-Captured 10 437)
    } else {
        [void](Invoke-Captured 0 437)
        # Policy rejects this direct URL before any package resolution/download.
        # Its Unicode validation message exercises real captured Python stderr.
        $badRequirement = 'encoding-probe @ https://invalid.invalid/' + $text
        $badList = 'dependencies = [' + (ConvertTo-Json -InputObject $badRequirement -Compress) + ']'
        $projectText = [Text.Encoding]::UTF8.GetString($originalProject)
        if (-not $projectText.Contains('dependencies = []')) { throw 'Unexpected default test project' }
        [IO.File]::WriteAllText($projectPath, $projectText.Replace('dependencies = []', $badList), $utf8)
        foreach ($page in @(437,866,1251,65001)) {
            $output = Invoke-Captured 10 $page
            if (-not $output.Contains('direct-URL dependencies are not allowed: ' + $badRequirement)) {
                throw "Unicode setup error mismatch at code page $page"
            }
        }
        [IO.File]::WriteAllBytes($projectPath, $originalProject)
        [void](Invoke-Captured 0 437)
    }
} finally {
    [IO.File]::WriteAllBytes($projectPath, $originalProject)
    if ($null -ne $originalMain) { [IO.File]::WriteAllBytes($main, $originalMain) }
    [Console]::OutputEncoding = $initialEncoding
}
Write-Output ('UTF8 LAUNCHER ACCEPTANCE: SUCCESS - ' + $Profile + ' - PowerShell ' + $PSVersionTable.PSVersion)
exit 0
'@
$driverPath = Join-Path $TestRoot 'encoding-driver.ps1'
[IO.File]::WriteAllText($driverPath, $driver, (New-Object Text.UTF8Encoding($false)))
$shells = @((Get-Command powershell.exe).Source)
$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($pwsh) { $shells += $pwsh.Source }
foreach ($shell in $shells) {
    & $shell -NoProfile -ExecutionPolicy Bypass -File $driverPath -Launcher $Launcher -Root $Root -Profile $Profile
    if ($LASTEXITCODE -ne 0) { throw "UTF-8 $Profile launcher regression failed" }
}
