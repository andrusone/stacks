<#
.SYNOPSIS
  Run every script's check mode on every Linux VM from this Windows machine and log the results here.

.DESCRIPTION
  The PowerShell counterpart of fleet-check.sh, for running from your Windows desktop. It reads the DNS
  zone file for the Linux VMs (A records named v<env><intent>x<n>, the same list git-access.ps1 uses),
  and for each one over ssh:
    1. sends a copy of this checkout's stacks\ to a temp directory on the VM,
    2. runs fleet-check-remote.sh there (the doctors, the golden-image validate stage, the baseline and
       mount-nas checks and, on a core node, build-core-node.sh --check and --only verify --check),
    3. removes the temp directory,
  and appends the drift records that came back to the LOCAL drift log. The remote half is the same
  bash code the Linux version runs; nothing on the VMs differs.

  DETECTS ONLY unless you pass -Apply. Each script runs in its read-only check mode, the host key must
  already be in your known_hosts (a new or changed one is never trusted), and the only thing written on
  a VM is the temp directory. A VM that cannot be reached is recorded as a failure.

  -Apply safe|all makes it fix what it found (FIXES.md next to this script lists every fix and why it
  is classed as it is). Each VM works out its own fixes. A fix is "safe" (less than a 50% chance of
  breaking the service the VM is for), "unsafe" (more than 50%) or "manual" (needs you; never applied):
    -Apply safe   apply the safe fixes, in order, then run every check again
    -Apply all    apply the safe and the unsafe fixes, then run every check again
  The fix summary then says, per machine, what was applied, whether the recheck passed and what still
  needs doing. Nothing is applied unless you pass -Apply, and it never reboots a VM.

  Results are measured against THIS checkout: git pull first.

  Access: it signs in with this machine's git-access key (~\.ssh\id_ed25519_github), which
  git-access.ps1 -Only vms installs on each VM. It does not use any other key. VMs are addressed by
  their full name (vpnx1.core.andrusonline.com), so this machine needs no DNS search suffix; if it
  cannot resolve that name at all, use -UseZoneIp.

  Exit code: 0 = every VM reached and nothing failed; 1 = a VM was unreachable or a check failed;
  2 = bad usage.

.PARAMETER Only
  Comma list of VM short names (vpnx1,vdcx2,...).
.PARAMETER Skip
  Comma list of VM short names to leave out.
.PARAMETER List
  Print the VMs found in the zone file and stop.
.PARAMETER GitRole
  personal|prod|ai: also run git-access.sh --check on each VM with this role (the role is per machine).
.PARAMETER AskSudo
  For VMs where the ssh user has no passwordless sudo: ask for the sudo password once and use it for
  the checks that read root-only state. It is held in memory only, sent to each VM as the first line of
  the ssh input (never in a command line, environment variable or file), and on the VM it lives in an
  unnamed temp file the run holds open. Nothing is installed and no sudoers rule changes. A wrong
  password is tried once per VM, then those checks are skipped. When input is redirected, the first
  line of it is used as the password.
.PARAMETER Apply
  none (default: detect only), safe (apply the safe fixes, then recheck) or all (safe and unsafe fixes,
  then recheck). Manual fixes are never applied; they are listed under "still to do".
.PARAMETER UseZoneIp
  Connect to the zone file's IP address instead of the name (host keys are still matched under the
  name), for when this machine cannot resolve core.andrusonline.com.
.PARAMETER PushAgent
  Explicitly install/update Vitals and the committed stacks tree. The host token must already exist.
  The designated speed-test host requires the manual paired-engine install instead.
.PARAMETER Binary
  Pinned Linux AMD64 binary on this controller; defaults to VITALS_BINARY. Its version is verified on the VM.
.PARAMETER Log
  Where results go. Default: ~\.local\state\drift-log\drift.jsonl, the same file fleet-check.sh uses.

.EXAMPLE
  .\fleet-check.ps1 -List
.EXAMPLE
  .\fleet-check.ps1 -Only vpnx1,vpnx2 -GitRole prod -AskSudo
.EXAMPLE
  .\fleet-check.ps1 -Only vdcx3 -AskSudo -Apply safe
#>
[CmdletBinding()]
param(
    [string[]]$Only = @(),
    [string[]]$Skip = @(),
    [switch]$List,
    [ValidateSet("", "personal", "prod", "ai")][string]$GitRole = "",
    [switch]$AskSudo,
    [ValidateSet("none", "safe", "all")][string]$Apply = "none",
    [switch]$PushAgent,
    [string]$Binary = $env:VITALS_BINARY,
    [switch]$UseZoneIp,
    [string]$User = "dave",
    [string]$Domain = "core.andrusonline.com",
    [string]$Zone = "",
    [string]$Key = "",
    [string]$Log = (Join-Path $HOME ".local\state\drift-log\drift.jsonl")
)

$ErrorActionPreference = "Stop"
$ScriptVersion = "2.4.1"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StacksDir = (Resolve-Path (Join-Path $ScriptDir "..\..\..")).Path
$RepoRoot = (Resolve-Path (Join-Path $StacksDir "..")).Path

function Stop-Usage([string]$m) { [Console]::Error.WriteLine("fleet-check: $m"); exit 2 }

if (-not $Zone) { $Zone = Join-Path $RepoRoot "config\dns\bind\db.$Domain" }
if (-not (Test-Path $Zone)) { Stop-Usage "zone file not found: $Zone (use -Zone)" }

# Linux VMs: v<env><intent>x<n>, from the A records ("name IN A ip ; comment").
$vms = @{}
foreach ($line in (Get-Content $Zone)) {
    $text = ($line -split ";", 2)[0]
    if ($text -match '^(\S+)\s+IN\s+A\s+(\d+\.\d+\.\d+\.\d+)\s*$') {
        $n = $Matches[1]; $ip = $Matches[2]
        if ($n -match '^v[a-z]{2}x\d+$') { $vms[$n] = $ip }
    }
}
if (-not $vms.Count) { Stop-Usage "no Linux VMs found in $Zone" }
$names = @($vms.Keys | Sort-Object { $_ -replace '\d+$', '' }, { [int]($_ -replace '^\D+', '') })

$onlySet = @($Only | ForEach-Object { $_ -split "," } | Where-Object { $_ })
$skipSet = @($Skip | ForEach-Object { $_ -split "," } | Where-Object { $_ })
$names = @($names | Where-Object { (-not $onlySet.Count -or $onlySet -contains $_) -and ($skipSet -notcontains $_) })

if ($List) { foreach ($n in $names) { "$n.$Domain" }; exit 0 }
if (-not $names.Count) { Stop-Usage "no VMs selected" }

$ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
if (-not $ssh) { Stop-Usage "ssh.exe not found (install the OpenSSH client; git-access.ps1 -Only tools does)" }
# Windows' own bsdtar: Git for Windows' GNU tar reads "C:\..." as a remote host.
$tarPath = Join-Path $env:SystemRoot "System32\tar.exe"
if (-not (Test-Path $tarPath)) { $c = Get-Command tar.exe -ErrorAction SilentlyContinue; $tarPath = if ($c) { $c.Source } else { "" } }
if (-not $tarPath) { Stop-Usage "tar.exe not found" }

if (-not $Key) {
    $default = Join-Path $HOME ".ssh\id_ed25519_github"
    if (Test-Path $default) { $Key = $default }
}
if ($Key -and -not (Test-Path $Key)) { Stop-Usage "ssh key not found: $Key" }

# The remote half is bash; a CRLF checkout (autocrlf) would break it on the VM.
$crlf = @(Get-ChildItem -Path $StacksDir -Recurse -Filter *.sh -File | Where-Object {
        $b = [IO.File]::ReadAllBytes($_.FullName); [Array]::IndexOf($b, [byte]13) -ge 0 })
if ($crlf.Count) {
    Stop-Usage ("these scripts have CRLF line endings and would not run on the VMs: " + (($crlf | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ", ") + ". The repo's .gitattributes wants LF: git add --renormalize . ; git checkout -- stacks")
}

# ---------------------------------------------------------------- sudo password
$SudoPw = ""
if ($AskSudo) {
    if ([Console]::IsInputRedirected) {
        $SudoPw = [Console]::In.ReadLine()
    } else {
        $sec = Read-Host -AsSecureString "sudo password for $User on the VMs (not stored)"
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $SudoPw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); $sec.Dispose() }
    }
    if (-not $SudoPw) { Stop-Usage "-AskSudo: no password given" }
}

# ---------------------------------------------------------------- helpers
$Utf8 = New-Object Text.UTF8Encoding($false)
$Via = "fleet-check@" + (($env:COMPUTERNAME.ToLower()) -replace '[^A-Za-z0-9._-]', '')
$HeadSha = ""
if (Get-Command git -ErrorAction SilentlyContinue) { $HeadSha = ((& git -C $RepoRoot rev-parse HEAD 2>$null) -join "") -replace "[^0-9a-f]", "" } # lets each VM tell whether its own checkout is behind
if ($PushAgent) {
    if ($Apply -ne "none") { Stop-Usage "-PushAgent cannot be combined with -Apply" }
    if ($HeadSha -notmatch '^[0-9a-f]{40}$') { Stop-Usage "push requires a committed checkout" }
    $manifest = & git -C $RepoRoot show "${HeadSha}:stacks/vitals/stack.env"
    if ($LASTEXITCODE -ne 0) { Stop-Usage "cannot read committed Vitals manifest" }
    $speedtestLine = @($manifest | Where-Object { $_ -match '^SPEEDTEST_HOST="?([a-z0-9-]+)"?$' })
    if ($speedtestLine.Count -gt 1) { Stop-Usage "invalid committed SPEEDTEST_HOST" }
    if ($speedtestLine.Count -eq 1) {
        $speedtestHost = [regex]::Match($speedtestLine[0], '^SPEEDTEST_HOST="?([a-z0-9-]+)"?$').Groups[1].Value
        if ($names -contains $speedtestHost) {
            Stop-Usage "-PushAgent cannot target $speedtestHost; use the manual Vitals converge with its locally supplied pinned speed-test engine"
        }
    }
    if (-not $Binary -or -not (Test-Path -LiteralPath $Binary -PathType Leaf)) { Stop-Usage "provide -Binary or VITALS_BINARY" }
    if ((Get-Item -LiteralPath $Binary).Attributes -band [IO.FileAttributes]::ReparsePoint) { Stop-Usage "binary must be a regular file" }
    $builder = & git -C $RepoRoot show "${HeadSha}:stacks/vitals/build-vitals-node.sh"
    if ($LASTEXITCODE -ne 0) { Stop-Usage "cannot read committed binary pin" }
    $pin = @($builder | Where-Object { $_ -match '^VITALS_SHA256=[0-9a-f]{64}$' })
    if ($pin.Count -ne 1) { Stop-Usage "invalid committed binary pin" }
    if ((Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash.ToLowerInvariant() -ne ($pin[0] -split '=', 2)[1]) {
        Stop-Usage "SHA256 mismatch for the local Vitals binary"
    }
}

function ConvertTo-JsonText([string]$s) {
    $s = $s -replace '[\x00-\x08\x0b-\x1f]', '' -replace '[\t\r\n]', ' '
    ($s -replace '\\', '\\' -replace '"', '\"')
}

# One drift-log line in the same shape drift-log.sh writes, plus "via".
function New-Record([string]$HostName, [string]$Script, [string]$Version, [int]$Passed, [int]$Failed, [string[]]$Failures) {
    $f = ($Failures | Where-Object { $_ } | Select-Object -First 20 | ForEach-Object { '"' + (ConvertTo-JsonText $_) + '"' }) -join ","
    '{"ts":"' + [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") + '","host":"' + (ConvertTo-JsonText $HostName) +
    '","script":"' + (ConvertTo-JsonText $Script) + '","version":"' + (ConvertTo-JsonText $Version) +
    '","mode":"fleet-check","passed":' + $Passed + ',"failed":' + $Failed + ',"warned":0,"fixed":0,"failures":[' + $f +
    '],"user":"' + (ConvertTo-JsonText $env:USERNAME) + '","via":"' + $Via + '"}'
}

function Add-LogLine([string]$Line) {
    [IO.File]::AppendAllText($Log, $Line + "`n", $Utf8)
}

function Invoke-DriftHistory([string]$HostName, [scriptblock]$Action) {
    if ($HostName -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { throw "invalid drift-history host id: $HostName" }
    $dir = Join-Path (Split-Path -Parent $Log) "hosts\$HostName"
    [void][IO.Directory]::CreateDirectory($dir)
    $lockPath = Join-Path $dir ".lock"
    $lock = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $lock) {
        try {
            $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            if ($watch.Elapsed.TotalSeconds -ge 30) { throw "timed out locking drift history for $HostName" }
            Start-Sleep -Milliseconds 100
        }
    }
    try { & $Action $dir }
    finally { $lock.Dispose() }
}

function Replace-DriftHistoryFile([string]$TempPath, [string]$TargetPath) {
    if ([IO.File]::Exists($TargetPath)) {
        [IO.File]::Replace($TempPath, $TargetPath, $null)
    } else {
        [IO.File]::Move($TempPath, $TargetPath)
    }
}

function Write-DriftRunSummary([string]$HostName, [string]$Line) {
    $summary = $Line | ConvertFrom-Json -ErrorAction Stop
    if ($summary.host -ne $HostName) { throw "summary host does not match $HostName" }
    Invoke-DriftHistory $HostName {
        param($dir)
        $target = Join-Path $dir "summary.jsonl"
        $temp = Join-Path $dir (".summary." + [Guid]::NewGuid().ToString("N"))
        try {
            $lines = @()
            if ([IO.File]::Exists($target)) { $lines = [IO.File]::ReadAllLines($target, $Utf8) }
            $lines = @($lines) + $Line
            if ($lines.Count -gt 60) { $lines = @($lines | Select-Object -Last 60) }
            [IO.File]::WriteAllLines($temp, [string[]]$lines, $Utf8)
            Replace-DriftHistoryFile $temp $target
        } finally {
            if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        }
    }
}

function Write-DriftRunDetail([string]$HostName, [string[]]$Lines) {
    Invoke-DriftHistory $HostName {
        param($dir)
        $target = Join-Path $dir "last-run.jsonl"
        $temp = Join-Path $dir (".last-run." + [Guid]::NewGuid().ToString("N"))
        try {
            [IO.File]::WriteAllLines($temp, $Lines, $Utf8)
            Replace-DriftHistoryFile $temp $target
        } finally {
            if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        }
    }
}

function Write-DownHistory([string]$HostName, [string]$DetailLine, [string]$Mode) {
    $line = [ordered]@{
        ts = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        host = $HostName
        verdict = "down"
        failed = 1
        warned = 0
        checks = 1
        stacks = [ordered]@{}
        behind = @()
        failed_in = @("fleet-check")
        mode = $Mode
    } | ConvertTo-Json -Compress
    Write-DriftRunSummary $HostName $line
    Write-DriftRunDetail $HostName @($DetailLine)
}

# Windows command-line quoting for one argument (CommandLineToArgvW rules).
function ConvertTo-WinArg([string]$s) {
    if ($s -ne "" -and $s -notmatch '[\s"]') { return $s }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($c in $s.ToCharArray()) {
        if ($c -eq [char]92) { $bs++ }
        elseif ($c -eq [char]34) { [void]$sb.Append([char]92, $bs * 2 + 1); [void]$sb.Append([char]34); $bs = 0 }
        else { if ($bs) { [void]$sb.Append([char]92, $bs); $bs = 0 }; [void]$sb.Append($c) }
    }
    if ($bs) { [void]$sb.Append([char]92, $bs * 2) }
    [void]$sb.Append('"')
    $sb.ToString()
}

# Run ssh with binary stdin; returns exit code, stdout, stderr.
function Invoke-SshStream([string[]]$SshArgs, [byte[]]$StdinBytes) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $ssh.Source
    $psi.Arguments = ($SshArgs | ForEach-Object { ConvertTo-WinArg $_ }) -join " "
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    try {
        $in = $p.StandardInput.BaseStream
        $in.Write($StdinBytes, 0, $StdinBytes.Length)
        $in.Close()
    } catch { } # ssh may exit before reading everything (refused, host key): its stderr says why
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
}

# What to do remotely, run under `bash -c` (the VMs' login shell is zsh): unpack to a temp dir, run,
# always clean up. With -AskSudo the first input line is the sudo password: read with builtins only,
# parked in an unlinked file on fd 9 (the runner's sudo stand-in reads it from there), variable cleared.
$RemoteBody = @'
d=$(mktemp -d) || exit 97; trap "rm -rf \"$d\"" EXIT
if [ -n "${FLEET_ASK_SUDO:-}" ]; then IFS= read -r pw; umask 077; pwf=$(mktemp -p "$d") && exec 9<>"$pwf" && rm -f "$pwf" && printf "%s\n" "$pw" >&9; pw=; fi
tar -xz -C "$d" || exit 98
if [ "${FLEET_PUSH_AGENT:-0}" = 1 ]; then
  chmod 755 "$d/.fleet/vitals" || exit 98
  bash "$d/stacks/os/common/drift/fleet-check-remote.sh" "$d/stacks" "$d/out.jsonl"
else
  bash "$d/os/common/drift/fleet-check-remote.sh" "$d" "$d/out.jsonl"
fi
'@ -replace "`r", ""
$RemoteBody = $RemoteBody.TrimEnd("`n")
$RemoteCmd = "bash -c 'export FLEET_GIT_ROLE=$GitRole FLEET_APPLY=$Apply FLEET_HEAD=$HeadSha FLEET_PUSH_AGENT=$([int]$PushAgent.IsPresent)" + $(if ($AskSudo) { " FLEET_ASK_SUDO=1" } else { "" }) + "; " + $RemoteBody + "'"

# ---------------------------------------------------------------- the archive, once
$tmpTar = Join-Path ([IO.Path]::GetTempPath()) ("fleet-check-" + [Guid]::NewGuid().ToString("N") + ".tgz")
$pushDir = ""
# The VM's stdout as data: the JSON records (first pass, and the recheck after -Apply, logged with
# "phase":"recheck") and the FIX / APPLIED / RECHECK / REMAIN protocol lines. None of it is trusted:
# only well-formed lines are kept and control characters are dropped.
function ConvertFrom-FleetOutput([string]$Out, [string]$ViaName, [string]$HostName = "") {
    $recordRe = '^\{"ts":"[0-9T:Z-]+","host":"[A-Za-z0-9._-]*","script":"[^"]*","version":"[^"]*",("stack":"[a-z0-9-]+",)?("mode":"[a-z-]*"),'
    $lines = @($Out -split "`r?`n" | ForEach-Object { $_ -replace '[\x00-\x08\x0b-\x1f]', '' })
    $fixes = @(); $applied = @(); $remain = @(); $log = @()
    $n = 0; $failed = 0; $rn = 0; $rfailed = 0; $summaryLine = ""
    foreach ($line in $lines) {
        if ($line -match '^FIX\t(\d{1,3})\t(safe|unsafe|manual)\t([^\t]*)\t([^\t]*)$') {
            $fixes += [pscustomobject]@{ Order = [int]$Matches[1]; Class = $Matches[2]; Why = $Matches[3]; Cmd = $Matches[4] }
        } elseif ($line -match '^APPLIED\t(\d{1,3})\t(safe|unsafe)\t(ok|failed|skipped|deferred)\t([0-9-]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)$') {
            $applied += [pscustomobject]@{ Order = [int]$Matches[1]; Class = $Matches[2]; Result = $Matches[3]; Rc = $Matches[4]; Why = $Matches[5]; Cmd = $Matches[6]; Note = $Matches[7] }
        } elseif ($line -match '^REMAIN\t(\d{1,3})\t(safe|unsafe|manual)\t([^\t]*)\t([^\t]*)$') {
            $remain += [pscustomobject]@{ Order = [int]$Matches[1]; Class = $Matches[2]; Why = $Matches[3]; Cmd = $Matches[4] }
        } elseif ($line -match '^SUMMARY\t(\{.*\})$') {
            $candidate = $Matches[1]
            $timestampText = [regex]::Match($candidate, '^\{"ts":"([^"]+)",').Groups[1].Value
            $parsedTimestamp = [DateTime]::MinValue
            $validTimestamp = [DateTime]::TryParseExact(
                $timestampText,
                "yyyy-MM-dd'T'HH:mm:ss'Z'",
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal,
                [ref]$parsedTimestamp
            )
            $sum = $candidate | ConvertFrom-Json -ErrorAction Stop
            $expectedProperties = @("ts", "host", "verdict", "failed", "warned", "checks", "stacks", "behind", "failed_in", "mode")
            $actualProperties = @($sum.PSObject.Properties.Name)
            if (($HostName -and $sum.host -ne $HostName) -or
                (Compare-Object $expectedProperties $actualProperties) -or
                $sum.host -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$' -or
                -not $validTimestamp -or
                $sum.verdict -notin @("ok", "drift") -or $sum.mode -notin @("check", "apply") -or
                ($sum.failed -isnot [int] -and $sum.failed -isnot [long]) -or
                ($sum.warned -isnot [int] -and $sum.warned -isnot [long]) -or
                ($sum.checks -isnot [int] -and $sum.checks -isnot [long]) -or
                $sum.failed -lt 0 -or $sum.warned -lt 0 -or $sum.checks -lt 0 -or
                (($sum.failed -eq 0) -and $sum.verdict -ne "ok") -or
                (($sum.failed -gt 0) -and $sum.verdict -ne "drift") -or
                $sum.stacks -isnot [System.Management.Automation.PSCustomObject] -or
                $sum.behind -isnot [array] -or $sum.failed_in -isnot [array]) {
                throw "invalid fleet summary received from $HostName"
            }
            foreach ($property in $sum.stacks.PSObject.Properties) {
                if ($property.Name -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$' -or $property.Value -notmatch '^[A-Za-z0-9._-]*$') {
                    throw "invalid stack data in fleet summary from $HostName"
                }
            }
            foreach ($id in $sum.behind) {
                if ($id -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { throw "invalid behind stack in fleet summary from $HostName" }
            }
            foreach ($scriptName in $sum.failed_in) {
                if ($scriptName -notmatch '^[A-Za-z0-9._/-]+$') { throw "invalid failed script in fleet summary from $HostName" }
            }
            $summaryLine = $candidate
        } else {
            $isRecheck = $line.StartsWith("RECHECK`t")
            $rec = if ($isRecheck) { $line.Substring(8) } else { $line }
            if ($rec -notmatch $recordRe -or -not $rec.EndsWith("}")) { continue }
            # The VM's temp directory name changes every run; keep it out of the failure text.
            $rec = $rec -replace '/tmp/tmp\.[A-Za-z0-9]{10}', '<fleet-tmp>'
            $f = if ($rec -match '"failed":(\d+),') { [int]$Matches[1] } else { 0 }
            if ($isRecheck) {
                $log += ($rec.Substring(0, $rec.Length - 1) + ',"phase":"recheck","via":"' + $ViaName + '"}')
                $rn++; $rfailed += $f
            } else {
                $log += ($rec.Substring(0, $rec.Length - 1) + ',"via":"' + $ViaName + '"}')
                $n++; $failed += $f
            }
        }
    }
    [pscustomobject]@{ Fixes = $fixes; Applied = $applied; Remain = $remain; Log = $log; Summary = $summaryLine; N = $n; Failed = $failed; Rn = $rn; Rfailed = $rfailed }
}

try {
    if ($PushAgent) {
        $pushDir = Join-Path ([IO.Path]::GetTempPath()) ("fleet-push-" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path (Join-Path $pushDir ".fleet") | Out-Null
        & git -C $RepoRoot archive --format=tar "--output=$tmpTar" $HeadSha stacks
        if ($LASTEXITCODE -ne 0) { throw "cannot archive committed stacks" }
        & $tarPath -xf $tmpTar -C $pushDir
        if ($LASTEXITCODE -ne 0) { throw "cannot extract committed stacks" }
        Copy-Item -LiteralPath $Binary -Destination (Join-Path $pushDir ".fleet\vitals")
        [IO.File]::WriteAllText((Join-Path $pushDir ".fleet\VERSION"), $HeadSha + "`n", $Utf8)
        $tarOut = & $tarPath -czf $tmpTar -C $pushDir . 2>&1
    } else {
        $tarOut = & $tarPath -czf $tmpTar -C $StacksDir --exclude=.git . 2>&1
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmpTar)) { Stop-Usage "could not archive ${StacksDir}: $tarOut" }
    $tarBytes = [IO.File]::ReadAllBytes($tmpTar)
} finally {
    Remove-Item $tmpTar -Force -ErrorAction SilentlyContinue
    if ($pushDir) { Remove-Item -LiteralPath $pushDir -Recurse -Force }
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Log) | Out-Null
Write-Host "fleet-check $ScriptVersion (PowerShell): $($vms.Count) Linux VM(s) in the zone, results to $Log"

$sshBase = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=30", "-o", "StrictHostKeyChecking=yes")
if ($Key) { $sshBase += @("-i", $Key, "-o", "IdentitiesOnly=yes") }

$summary = @()
$ran = @()
$down = @{}
$fixes = @{}     # vm -> planned fixes (class safe|unsafe|manual)
$applied = @{}   # vm -> what --apply did, one entry per fix
$remain = @{}    # vm -> what is still to do after the recheck
$initial = @{}   # vm -> failed checks before any fix
$final = @{}     # vm -> failed checks after the recheck
$rechecked = @{}
$recheckN = @{}
$totalFailed = 0
$finalFailed = 0
$unreachable = 0

try {
    foreach ($vm in $names) {
        $fqdn = "$vm.$Domain"
        Write-Host ""
        Write-Host "== $vm ($fqdn)"

        $target = "$User@$fqdn"
        $sshArgs = $sshBase
        if ($UseZoneIp) { $target = "$User@$($vms[$vm])"; $sshArgs = $sshBase + @("-o", "HostKeyAlias=$fqdn") }

        $payload = $tarBytes
        if ($AskSudo) {
            $pwBytes = $Utf8.GetBytes($SudoPw + "`n")
            $payload = New-Object byte[] ($pwBytes.Length + $tarBytes.Length)
            [Array]::Copy($pwBytes, 0, $payload, 0, $pwBytes.Length)
            [Array]::Copy($tarBytes, 0, $payload, $pwBytes.Length, $tarBytes.Length)
            [Array]::Clear($pwBytes, 0, $pwBytes.Length)
        }
        $r = Invoke-SshStream ($sshArgs + @($target, $RemoteCmd)) $payload
        if ($AskSudo) { [Array]::Clear($payload, 0, [Math]::Min(512, $payload.Length)) }

        foreach ($l in ($r.Err -split "`r?`n")) { if ($l) { Write-Host "   $l" } }
        $ran += $vm

        if ($r.Code -ne 0) {
            # 255 is ssh itself (down, refused, host key unknown or changed, key not accepted).
            if ($r.Code -eq 255) {
                $last = ($r.Err -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^Warning:' } | Select-Object -Last 1)
                $reason = "ssh failed: $last"
            } else { $reason = "remote step failed (exit $($r.Code))" }
            $downRecord = New-Record $vm "fleet-check" $ScriptVersion 0 1 @($reason)
            Add-LogLine $downRecord
            Write-DownHistory $vm $downRecord $(if ($Apply -eq "none") { "check" } else { "apply" })
            Write-Host "   UNREACHABLE: $reason" -ForegroundColor Red
            $summary += ("{0,-8}  UNREACHABLE" -f $vm)
            $unreachable++
            $down[$vm] = $true
            continue
        }

        $p = ConvertFrom-FleetOutput $r.Out $Via $vm
        if (-not $p.Summary) { throw "remote summary missing for $vm" }
        $fixes[$vm] = @($p.Fixes)
        $applied[$vm] = @($p.Applied)
        $remain[$vm] = @($p.Remain)
        foreach ($l in $p.Log) { Add-LogLine $l }
        Write-DriftRunSummary $vm $p.Summary
        Write-DriftRunDetail $vm ([string[]]$p.Log)
        $n = $p.N; $failed = $p.Failed; $rn = $p.Rn; $rfailed = $p.Rfailed
        $totalFailed += $failed
        $initial[$vm] = $failed
        $final[$vm] = $failed
        if ($rn -gt 0) { $rechecked[$vm] = $true; $recheckN[$vm] = $rn; $final[$vm] = $rfailed }
        $finalFailed += $final[$vm]

        $color = if ($failed) { "Yellow" } else { "Green" }
        Write-Host "   recorded $n check(s), $failed failed" -ForegroundColor $color
        if ($rn -gt 0) {
            Write-Host "   recheck after fixes: $rn check(s), $rfailed failed" -ForegroundColor $(if ($rfailed) { "Yellow" } else { "Green" })
            $summary += ("{0,-8}  {1,3} recorded  {2,3} failed  ->  {3,3} failed after fixes" -f $vm, $n, $failed, $rfailed)
        } else {
            $summary += ("{0,-8}  {1,3} recorded  {2,3} failed" -f $vm, $n, $failed)
        }
    }
} finally {
    $SudoPw = $null
}

function Write-FixList($Items, [string]$Indent) {
    $i = 0
    foreach ($f in ($Items | Sort-Object Order, Cmd -Unique)) {
        $i++
        $color = switch ($f.Class) { "safe" { "Gray" } "unsafe" { "Yellow" } default { "Magenta" } }
        Write-Host "$Indent$i. [$($f.Class)] $($f.Cmd)" -ForegroundColor $color
        Write-Host "$Indent   # $($f.Why)" -ForegroundColor DarkGray
    }
}

Write-Host ""
if ($Apply -eq "none") {
    Write-Host "== Fix summary (per machine, in the order to run them; nothing here has been run)"
    Write-Host "   Each fix is [safe] (unlikely to break the VM's service), [unsafe] (likely to) or [manual] (needs you)."
    Write-Host "   Run on the machine itself, or let fleet-check do it: -Apply safe | -Apply all. Read them first."
} else {
    Write-Host "== Fix summary (-Apply $Apply): what was applied, whether the recheck passed, what is still to do"
    Write-Host "   Fixes ran from the copy of stacks\ shipped with this run: the same version the checks used."
}
foreach ($vm in $ran) {
    Write-Host ""
    if ($down.ContainsKey($vm)) {
        Write-Host "   ${vm}: unreachable; fix access first (git-access.ps1 -Only vms, then run this again)" -ForegroundColor Red
        continue
    }
    $planned = @($fixes[$vm])
    if (-not $planned.Count) { Write-Host "   ${vm}: nothing to fix" -ForegroundColor Green; continue }
    Write-Host "   $vm   (ssh $User@$vm.$Domain)" -ForegroundColor Cyan
    if ($Apply -eq "none") { Write-FixList $planned "     "; continue }

    $did = @($applied[$vm])
    if ($did.Count) {
        Write-Host "     applied:"
        foreach ($a in ($did | Sort-Object Order)) {
            $tag = switch ($a.Result) { "ok" { "ok" } "failed" { "FAILED, exit $($a.Rc)" } default { $a.Result } }
            $color = switch ($a.Result) { "ok" { "Green" } "failed" { "Red" } default { "Yellow" } }
            Write-Host "       [$tag] [$($a.Class)] $($a.Cmd)" -ForegroundColor $color
            Write-Host "          # $($a.Why)" -ForegroundColor DarkGray
            if ($a.Result -ne "ok" -and $a.Note) { Write-Host "          > $($a.Note)" -ForegroundColor DarkGray }
        }
    } else {
        Write-Host "     applied: nothing (only manual items)"
    }
    if ($rechecked.ContainsKey($vm)) {
        if ($final[$vm] -eq 0) {
            Write-Host "     recheck: PASSED ($($recheckN[$vm]) checks, 0 failed)" -ForegroundColor Green
        } else {
            $more = if (@($remain[$vm] | Where-Object { $_.Class -ne "manual" }).Count) { "" } else { "; nothing left can be automated, the rest needs you" }
            Write-Host "     recheck: NOT PASSED ($($recheckN[$vm]) checks, $($final[$vm]) failed; was $($initial[$vm]))$more" -ForegroundColor Yellow
        }
    } else {
        Write-Host "     recheck: not run (nothing was applied)"
    }
    $left = if ($rechecked.ContainsKey($vm)) { @($remain[$vm]) } else { $planned }
    if ($left.Count) {
        Write-Host "     still to do:"
        Write-FixList $left "       "
    } else {
        Write-Host "     still to do: nothing" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "== Summary"
$summary | ForEach-Object { Write-Host "   $_" }
if ($Apply -eq "none") {
    Write-Host "   unreachable: $unreachable   failed checks: $totalFailed   log: $Log"
} else {
    Write-Host "   unreachable: $unreachable   failed checks: $totalFailed before, $finalFailed after   log: $Log"
}
if ($unreachable -eq 0 -and $finalFailed -eq 0) { exit 0 } else { exit 1 }
