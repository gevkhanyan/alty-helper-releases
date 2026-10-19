#Requires -Version 7.2
<#
.SYNOPSIS
  The Alty helper's Windows smoke test, for a fresh computer that is thrown away afterwards (a GitHub runner).

.DESCRIPTION
  Installs the given installer silently, then checks in order:
    1. the silent install: per user, its manifest asking for no administrator rights, nothing for the whole
       computer; the program, the Run key, the Start menu shortcut (this runner's user is an administrator,
       so a standard user's install is not tried);
    2. the helper starts: one supervisor, its worker and, from 0.3.0, its print process; its page on
       127.0.0.1:47100, unpaired; the print process's own Windows PowerShell started and Windows' printers read;
    3. HTTPS to Alty's real server: the page's pairing with a deliberately wrong code reaches the server,
       which refuses it (nothing is paired and nothing changes there);
    4. from 0.3.0, Windows printing as the print process does it, through alty-helper.exe --print-check:
       its PowerShell starts and compiles the C# over winspool.drv, it lists the printers exactly as Windows
       lists them, a printer Windows does not have is refused with nothing sent, and a RAW print to a printer
       this test adds (Windows' own text driver on a port that is a file) leaves Windows' queue with its
       bytes unchanged in that file; the running print process lists that printer too;
    5. the worker, ended from outside, is started again by its supervisor, the print process untouched;
    6. from 0.3.0, the print process, ended from outside, is started again by its supervisor, the worker
       untouched, its PowerShell ending with it and the new one starting its own;
    7. two more starts, as from the Start menu shortcut, leave the same processes;
    8. a reinstall over the running helper stops it first (the print process on the supervisor's word),
       brings it back, keeps its data, still unpaired;
    9. its logs (helper.log, and print.log from 0.3.0): the start lines, no code and no secret, no warning
       or error the test did not cause;
   10. the silent uninstall leaves nothing behind.
  Checks 4 and 6 are for a release with a print process (0.3.0 and later, by the version the release's tag
  names, which check 1 holds the installer to): for an older one they say SKIP, and every other check then
  expects no print process at all. Each check prints PASS or FAIL with what it saw. After a FAIL the script
  goes on and collects the evidence, and it exits 1 if any check failed. The evidence (the helper's logs,
  its /api/status answers, the process lists, the print checks' output and bytes, the report) is written
  to -Evidence before the uninstall removes the helper's data folder. The page's token and the helper's
  quit secrets are never printed, and are masked in everything saved.

  References such as main.ts:134 point into apps/helper of the Alty repository at the tag helper-v0.3.0
  (api: and shared: into apps/api and packages/shared there).
#>
[CmdletBinding()]
param(
  # the installer under test: the release's AltyHelperSetup.exe
  [Parameter(Mandatory)] [string] $Installer,
  # the version the release's tag names, e.g. 0.1.0
  [Parameter(Mandatory)] [string] $ExpectedVersion,
  # the folder for the evidence and the report
  [Parameter(Mandatory)] [string] $Evidence
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 1.0
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$Installer = (Resolve-Path -LiteralPath $Installer).Path
New-Item -ItemType Directory -Force -Path $Evidence | Out-Null
$Evidence = (Resolve-Path -LiteralPath $Evidence).Path
$WorkDir = (Get-Location).Path

# ---------------------------------------------------------------------------------------------------------
# What the installer and the helper say (installer/alty-helper.nsi and src/ at helper-v0.3.0)
# ---------------------------------------------------------------------------------------------------------
$AppId           = 'AltyHelper'                                                           # .nsi:30
$ProgramDir      = Join-Path $env:LOCALAPPDATA 'Programs\Alty Helper'                     # .nsi:39
$Exe             = Join-Path $ProgramDir 'alty-helper.exe'                                # .nsi:31
$Uninstaller     = Join-Path $ProgramDir 'uninstall.exe'                                  # .nsi:88
$DataDir         = Join-Path $env:LOCALAPPDATA 'Alty Helper'                              # .nsi:35, paths.ts:51
$LogsDir         = Join-Path $DataDir 'logs'                                              # paths.ts:60
$LogFile         = Join-Path $LogsDir 'helper.log'                                        # log.ts:74
$PrintLogFile    = Join-Path $LogsDir 'print.log'                                         # log.ts:76, print/worker.ts:110-115
$RuntimeFile     = Join-Path $DataDir 'runtime.json'                                      # paths.ts:59
$PrintStatusFile = Join-Path $DataDir 'print-status.json'                                 # paths.ts:65
$Shortcut        = Join-Path ([Environment]::GetFolderPath('Programs')) 'Alty Helper.lnk' # .nsi:32, :80
$RunKey          = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'                  # .nsi:33, :91
$UninstallKey    = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppId"     # .nsi:34, :95-103
$AppKey          = "HKCU:\Software\$AppId"                                                # .nsi:40, :89
$Port            = 47100                                                                  # server.ts:10
$PageUrl         = "http://127.0.0.1:$Port/"                                              # server.ts:245, :253
$ApiUrl          = 'https://api.alty.am'                                                  # store.ts:6
# a code the server can never issue: its codes leave out O and 0 (api: lib/crypto.ts:120-121), so no device
# has this one's hash and the server answers 404 registration_invalid (api: device/service.ts:397-401).
# 9 characters, as the page and the server take a code (status/server.ts:168; shared: api/helper.ts:66-68)
$WrongCode       = 'OOOO-0000'
# the page's title in Armenian, 'Alty' and the word for helper (i18n/hy.ts:10), kept ASCII in this file
$HyTitle         = 'Alty ' + (-join ([char[]](0x0585, 0x0563, 0x0576, 0x0561, 0x056F, 0x0561, 0x0576)))

# The print process (--print-worker) came with 0.3.0: the supervisor starts it beside the worker (main.ts:168-191)
$PrintSince      = [version]'0.3.0'
# Windows PowerShell by its full path, as the print process starts it for Windows' spooler (fiscal/powershell.ts:40-49,
# print/windows.ts:553, :570-575)
$SpoolerExe      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# what check 4 prints on: a printer this test adds, with Windows' own text driver on a local port that is a file
# (apps/helper/README.md «Not proven on Windows yet»), and a name no printer has
$RawPrinter      = 'Alty Raw Check'
$RawDriver       = 'Generic / Text Only'
$RawPort         = Join-Path $env:ProgramData 'alty-print-check.prn'
$NoPrinter       = 'Alty No Such Printer'

# The version under test, as the release's tag names it (check 1 holds the installer's version resource to it,
# check 9 every start line): a release before 0.3.0 has no print process, and none may run
if ($ExpectedVersion -notmatch '^(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?$') { throw "not a release version: '$ExpectedVersion'" }
$VersionCore = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
$HasPrint    = $VersionCore -ge $PrintSince
$PrintCount  = if ($HasPrint) { 1 } else { 0 }
$WholeText   = if ($HasPrint) { 'one supervisor, one worker and one print process' } else { 'one supervisor and one worker' }

$CheckNames = [ordered]@{
  '1'  = 'Silent install: per user, asks for no administrator rights'
  '2'  = 'The helper starts: one supervisor, one worker, one print process (from 0.3.0), the page on 127.0.0.1:47100, unpaired'
  '3'  = 'HTTPS to the real server: the page pairs with a wrong code, the server refuses it'
  '4'  = 'Windows printing as the print process does it (--print-check): PowerShell, the C#, the printers, a RAW print'
  '5'  = 'The worker comes back after it is ended'
  '6'  = 'The print process comes back after it is ended'
  '7'  = 'One instance only: two more starts, as from the Start menu shortcut'
  '8'  = 'Reinstall over the running helper'
  '9'  = 'The logs: start lines, no code, no secret, nothing unexpected'
  '10' = 'Silent uninstall: nothing left behind'
}

# what one check hands the next (the page's address, the processes) and what must never be shown
$S = @{
  Url                    = $PageUrl
  Secrets                = [System.Collections.Generic.List[string]]::new()
  StatusSeq              = 0
  EvidenceSaved          = $false
  InstalledAt            = $null
  Link                   = $null
  Supervisor             = $null
  Worker                 = $null
  Print                  = $null
  SpoolerCommand         = $null
  FirstSupervisorPid     = $null
  ReinstallSupervisorPid = $null
}
$Results = [System.Collections.Generic.List[object]]::new()
$Current = $null
$Verdict = 'FAIL'

# ---------------------------------------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------------------------------------
function Add-Secret([string]$Value) {
  if ([string]::IsNullOrEmpty($Value) -or $S.Secrets.Contains($Value)) { return }
  $S.Secrets.Add($Value)
}

# every line printed or saved goes through this: a secret seen anywhere becomes ***
function Protect-Text([string]$Text) {
  foreach ($secret in $S.Secrets) { $Text = $Text.Replace($secret, '***') }
  return $Text
}

function Note([string]$Text) {
  $Text = Protect-Text $Text
  $script:Current.Evidence.Add($Text)
  Write-Host "    $Text"
}

function Expect($Condition, [string]$What) {
  $What = Protect-Text $What
  if ($Condition) {
    $script:Current.Evidence.Add("ok: $What")
    Write-Host "    ok    $What"
  } else {
    $script:Current.Failures.Add($What)
    $script:Current.Evidence.Add("FAILED: $What")
    Write-Host "    FAIL  $What"
  }
}

# the line the summary table shows for a check that passed
function Headline([string]$Text) { $script:Current.Headline = Protect-Text $Text }

# A check of what came with a release ($Since) is skipped for an older one, and says so: the rest hold an older
# release to its own rules (no print process at all before 0.3.0)
function Invoke-Check([string]$Id, [scriptblock]$Body, [version]$Since) {
  $script:Current = [pscustomobject]@{
    Id       = $Id
    Name     = $CheckNames[$Id]
    Status   = ''
    Seconds  = 0.0
    Headline = ''
    Evidence = [System.Collections.Generic.List[string]]::new()
    Failures = [System.Collections.Generic.List[string]]::new()
  }
  Write-Host ''
  Write-Host "=== $Id. $($CheckNames[$Id])"
  if ($null -ne $Since -and $VersionCore -lt $Since) {
    $script:Current.Status = 'SKIP'
    $script:Current.Headline = "not for $ExpectedVersion`: what it checks came with $Since"
    $script:Current.Evidence.Add($script:Current.Headline)
    Write-Host "--- SKIP  $Id. $($CheckNames[$Id]) ($($script:Current.Headline))"
    $Results.Add($script:Current)
    return
  }
  $checkClock = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $null = & $Body
  } catch {
    Expect $false "the check stopped on an error: $($_.Exception.Message) (smoke.ps1 line $($_.InvocationInfo.ScriptLineNumber))"
  }
  $script:Current.Seconds = [math]::Round($checkClock.Elapsed.TotalSeconds, 1)
  $script:Current.Status = if ($script:Current.Failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
  Write-Host "--- $($script:Current.Status)  $Id. $($CheckNames[$Id]) ($($script:Current.Seconds) s)"
  $Results.Add($script:Current)
}

function Save-Text([string]$Name, [string]$Text) {
  $path = Join-Path $Evidence $Name
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  Set-Content -LiteralPath $path -Value (Protect-Text $Text) -Encoding utf8 -NoNewline
}

function Save-Json([string]$Name, $Value) {
  Save-Text $Name (ConvertTo-Json -InputObject $Value -Depth 12)
}

function Format-Cell([string]$Text) {
  $cell = ($Text -replace "[`r`n]+", ' ') -replace '\|', '\|'
  if ($cell.Length -gt 600) { $cell = $cell.Substring(0, 600) + ' ...' }
  return $cell
}

# ---------------------------------------------------------------------------------------------------------
# Looking at the helper
# ---------------------------------------------------------------------------------------------------------

# Polls until the condition gives something (returned), or $null at the deadline: no fixed sleeps.
# (The condition runs in this function's scope: its own names here are unusual on purpose.)
function Wait-Until([scriptblock]$Condition, [double]$Seconds, [int]$EveryMs = 200) {
  $waitDeadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  while ($true) {
    $waitGot = $null
    try { $waitGot = & $Condition } catch { $waitGot = $null }
    if ($waitGot) { return $waitGot }
    if ([DateTime]::UtcNow -ge $waitDeadline) { return $null }
    Start-Sleep -Milliseconds $EveryMs
  }
}

# A process this script started or ended lets go of its handle here, once its exit code is read. A handle
# held to a process that has ended keeps that process's program file in use, so a reinstall could not
# replace alty-helper.exe and an uninstall could not delete it or uninstall.exe; Explorer, Settings and
# NSIS's own Exec close theirs at once, so a handle of the test's must not stay open either.
function Close-Process($Process) {
  if ($null -eq $Process) { return }
  try { $Process.Dispose() } catch { }
}

# Whatever this script no longer holds but has not closed (a process object of PowerShell's own), closed
# now rather than whenever .NET gets to it: before the reinstall and before the uninstall.
function Close-StrayHandles {
  [GC]::Collect()
  [GC]::WaitForPendingFinalizers()
  [GC]::Collect()
}

# what follows the program in a command line: '' for the supervisor the Run key starts, '--worker' ...
function Get-ArgumentsOf([string]$CommandLine) {
  return ($CommandLine -replace '^\s*("[^"]*"|\S+)\s*', '').Trim()
}

# A helper process's part, read from its command line in the order main.ts:45-57 reads it: --version, pair,
# --quit (the installer's short-lived ask), --print-check (a check of Windows' printing), --print-worker (the
# print process, since 0.3.0: main.ts:170-190), --worker (main.ts:154-167); any other alty-helper.exe is a
# supervisor (no arguments, or --open).
function Get-RoleOf([string]$CommandLine) {
  if ($CommandLine -match '(^|\s)--version(\s|$)') { return 'version' }
  if ((Get-ArgumentsOf $CommandLine) -match '^pair(\s|$)') { return 'pair' }
  if ($CommandLine -match '(^|\s)--quit(\s|$)') { return 'quit' }
  if ($CommandLine -match '(^|\s)--print-check(\s|$)') { return 'check' }
  if ($CommandLine -match '(^|\s)--print-worker(\s|$)') { return 'print' }
  if ($CommandLine -match '(^|\s)--worker(\s|$)') { return 'worker' }
  return 'supervisor'
}

function Get-HelperProcesses {
  foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'alty-helper.exe'")) {
    $cmd = [string]$p.CommandLine
    [pscustomobject]@{
      Pid         = [int]$p.ProcessId
      ParentPid   = [int]$p.ParentProcessId
      Role        = Get-RoleOf $cmd
      Path        = [string]$p.ExecutablePath
      CommandLine = $cmd
      Started     = $p.CreationDate
    }
  }
}

function Get-Helper {
  $all = @(Get-HelperProcesses)
  [pscustomobject]@{
    All         = $all
    Supervisors = @($all | Where-Object { $_.Role -eq 'supervisor' })
    Workers     = @($all | Where-Object { $_.Role -eq 'worker' })
    Prints      = @($all | Where-Object { $_.Role -eq 'print' })
    Others      = @($all | Where-Object { $_.Role -notin 'supervisor', 'worker', 'print' })
  }
}

# A running helper: one supervisor, one worker and, from 0.3.0, one print process (none before)
function Test-Running($Helper) {
  return ($Helper.Supervisors.Count -eq 1 -and $Helper.Workers.Count -eq 1 -and $Helper.Prints.Count -eq $PrintCount)
}

# ... and nothing else of the helper's beside it
function Test-Whole($Helper) {
  return ((Test-Running $Helper) -and $Helper.Others.Count -eq 0)
}

function Format-Helper($Helper) {
  if ($Helper.All.Count -eq 0) { return 'no alty-helper process' }
  return (($Helper.All | ForEach-Object { "$($_.Role) $($_.Pid) (parent $($_.ParentPid))" }) -join ', ')
}

# The Windows PowerShell a print process (or a --print-check) keeps for Windows' spooler: powershell.exe with the
# constant script that compiles the C# class AltySpooler and serves its input (print/windows.ts:386-400, :570-575)
function Get-SpoolerShells {
  foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'")) {
    $cmd = [string]$p.CommandLine
    if (-not $cmd.Contains('[AltySpooler]::Serve()')) { continue }
    [pscustomobject]@{
      Pid         = [int]$p.ProcessId
      ParentPid   = [int]$p.ParentProcessId
      Role        = 'spooler'
      Path        = [string]$p.ExecutablePath
      CommandLine = $cmd
      Started     = $p.CreationDate
    }
  }
}

function Format-Shells($Shells) {
  $list = @($Shells)
  if ($list.Count -eq 0) { return 'no spooler PowerShell' }
  return (($list | ForEach-Object { "PowerShell $($_.Pid) (parent $($_.ParentPid))" }) -join ', ')
}

# the helper's processes, and the spooler's PowerShell with its long constant command line cut short
function Save-Processes([string]$Label) {
  $shells = @(Get-SpoolerShells | ForEach-Object {
      [pscustomobject]@{
        Pid         = $_.Pid
        ParentPid   = $_.ParentPid
        Role        = $_.Role
        Path        = $_.Path
        CommandLine = "$($_.CommandLine.Substring(0, [Math]::Min(120, $_.CommandLine.Length))) ... ($($_.CommandLine.Length) characters)"
        Started     = $_.Started
      } })
  Save-Json "processes-$Label.json" (@(Get-HelperProcesses) + $shells)
}

# Samples the processes for a while: the same supervisor, worker and (from 0.3.0) print process throughout,
# and nothing else.
function Watch-Steady($Supervisor, $Worker, $Print, [double]$Seconds) {
  $count = if ($null -ne $Print) { 3 } else { 2 }
  $named = "supervisor $($Supervisor.Pid) and worker $($Worker.Pid)$(if ($null -ne $Print) { " and print process $($Print.Pid)" })"
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $looks = 0
  while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
    $h = Get-Helper
    $looks++
    $same = ($h.All.Count -eq $count -and $h.Supervisors.Count -eq 1 -and $h.Workers.Count -eq 1 -and
      $h.Supervisors[0].Pid -eq $Supervisor.Pid -and $h.Workers[0].Pid -eq $Worker.Pid -and
      ($null -eq $Print -or ($h.Prints.Count -eq 1 -and $h.Prints[0].Pid -eq $Print.Pid)))
    if (-not $same) {
      return [pscustomobject]@{ Ok = $false; Text = "after $([math]::Round($watch.Elapsed.TotalSeconds, 1)) s: $(Format-Helper $h) (expected only $named)" }
    }
    Start-Sleep -Milliseconds 250
  }
  return [pscustomobject]@{ Ok = $true; Text = "for $Seconds s ($looks looks) only $named run" }
}

# A file the helper may be writing, read as its own writes allow (an append, a rename over it): this read
# never makes it drop a log line (log.ts:134-146) or wait on runtime.json (files.ts:29-48).
function Read-SharedText([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    $share = [System.IO.FileShare]([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
      $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false))
      return $reader.ReadToEnd()
    } finally {
      $stream.Dispose()
    }
  } catch {
    return $null
  }
}

# The first bytes of a file (the PE header, the installer's manifest).
function Read-Head([string]$Path, [int]$Count) {
  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $buffer = [byte[]]::new([int][Math]::Min([long]$Count, $stream.Length))
    $read = 0
    while ($read -lt $buffer.Length) {
      $n = $stream.Read($buffer, $read, $buffer.Length - $read)
      if ($n -le 0) { break }
      $read += $n
    }
    return , $buffer
  } finally {
    $stream.Dispose()
  }
}

# The execution level the installer's manifest asks for: RequestExecutionLevel user (.nsi:17) is
# asInvoker, which runs without a UAC prompt even though the file's name says Setup.
function Get-ManifestLevel([string]$Path) {
  $head = Read-Head $Path 2097152
  $text = [System.Text.Encoding]::ASCII.GetString($head)
  if ($text -match 'requestedExecutionLevel\s+level="(\w+)"') { return $Matches[1] }
  return '(none)'
}

# The PE header's Subsystem (pe.ts:8-9, :36-43): 2 is a windowed program, 3 a console one.
function Get-Subsystem([string]$Path) {
  $head = Read-Head $Path 4096
  $pe = [BitConverter]::ToInt32($head, 0x3C)
  if ($pe -lt 0 -or $pe + 24 + 70 -gt $head.Length -or [BitConverter]::ToUInt32($head, $pe) -ne 0x00004550) { return -1 }
  return [int][BitConverter]::ToUInt16($head, $pe + 24 + 68)
}

# runtime.json, the running instance (runtime.ts:11-21); its secrets are noted so nothing shows them.
function Read-Runtime {
  $text = Read-SharedText $RuntimeFile
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  try { $rt = $text | ConvertFrom-Json } catch { return $null }
  foreach ($name in 'quitSecret', 'lockSecret') {
    $prop = $rt.PSObject.Properties[$name]
    if ($null -ne $prop -and $null -ne $prop.Value) { Add-Secret ([string]$prop.Value) }
  }
  return $rt
}

# print-status.json, what the print process says of itself, written whole by it (print/status.ts:19-49,
# print/worker.ts:162-203); nothing secret in it
function Read-PrintStatus {
  $text = Read-SharedText $PrintStatusFile
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Get-RegValue([string]$Key, [string]$Name) {
  $item = Get-Item -LiteralPath $Key -ErrorAction SilentlyContinue
  if ($null -eq $item) { return $null }
  return $item.GetValue($Name, $null)
}

# The shortcut as Windows reads it; the COM objects are let go at once, so nothing of the test's holds the
# .lnk the uninstall deletes, and Close-StrayHandles has no COM object left to finalize.
function Get-Shortcut {
  if (-not (Test-Path -LiteralPath $Shortcut -PathType Leaf)) { return $null }
  $shell = New-Object -ComObject WScript.Shell
  $link = $null
  try {
    $link = $shell.CreateShortcut($Shortcut)
    return [pscustomobject]@{
      TargetPath       = [string]$link.TargetPath
      Arguments        = [string]$link.Arguments
      WorkingDirectory = [string]$link.WorkingDirectory
      IconLocation     = [string]$link.IconLocation
    }
  } finally {
    foreach ($com in @($link, $shell)) {
      if ($null -ne $com) { try { $null = [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) } catch { } }
    }
  }
}

# One request to the helper's page; $null when nothing answers (refused, timed out).
function Invoke-Page {
  param(
    [string]$Path = '',
    [string]$Method = 'GET',
    [hashtable]$Headers = @{},
    [string]$Body = '',
    [string]$Base = $S.Url,
    [int]$TimeoutSec = 10
  )
  $request = @{ Uri = "$Base$Path"; Method = $Method; Headers = $Headers; TimeoutSec = $TimeoutSec; SkipHttpErrorCheck = $true }
  if ($PSBoundParameters.ContainsKey('Body')) {
    # as bytes, so the Content-Type goes exactly as the page's script sends it (page.ts:366-368)
    $request.Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $request.ContentType = 'application/json'
  }
  try { return (Invoke-WebRequest @request) } catch { return $null }
}

# an answer's body as UTF-8, whatever charset the answer names
function Get-Body($Response) {
  if ($null -eq $Response) { return '' }
  $raw = $Response.RawContentStream
  if ($null -ne $raw) { return [System.Text.Encoding]::UTF8.GetString($raw.ToArray()) }
  return [string]$Response.Content
}

function Get-Header($Response, [string]$Name) {
  if ($null -eq $Response) { return '' }
  foreach ($key in @($Response.Headers.Keys)) {
    if ($key -ieq $Name) { return (@($Response.Headers[$key]) -join ', ') }
  }
  return ''
}

function Format-Answer($Response) {
  if ($null -eq $Response) { return 'no answer' }
  $text = Get-Body $Response
  if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + ' ...' }
  return "$($Response.StatusCode) $text"
}

function Test-Page([string]$Base = $S.Url) {
  $response = Invoke-Page -Path 'api/status' -Base $Base -TimeoutSec 3
  return ($null -ne $response -and $response.StatusCode -eq 200)
}

# GET /api/status (server.ts:133-136; its shape: status/types.ts:77-100), each answer kept as evidence.
function Get-Status([string]$Base = $S.Url) {
  $response = Invoke-Page -Path 'api/status' -Base $Base
  if ($null -eq $response -or $response.StatusCode -ne 200) { return $null }
  $text = Get-Body $response
  $S.StatusSeq++
  Save-Text ('status-{0:00}-check{1}.json' -f $S.StatusSeq, $script:Current.Id) $text
  try { return ($text | ConvertFrom-Json) } catch { return $null }
}

# The same answer, not kept: for the waits, which ask it again and again
function Read-Status([string]$Base = $S.Url) {
  $response = Invoke-Page -Path 'api/status' -Base $Base -TimeoutSec 3
  if ($null -eq $response -or $response.StatusCode -ne 200) { return $null }
  try { return ((Get-Body $response) | ConvertFrom-Json) } catch { return $null }
}

# A request under a Host of our choosing (Invoke-WebRequest always sends the real one); its status line.
function Send-RawRequest([string]$HostHeader) {
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $client.ReceiveTimeout = 5000
    $client.SendTimeout = 5000
    $client.Connect('127.0.0.1', ([Uri]$S.Url).Port)
    $stream = $client.GetStream()
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("GET /api/status HTTP/1.1`r`nHost: $HostHeader`r`nConnection: close`r`n`r`n")
    $stream.Write($bytes, 0, $bytes.Length)
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII)
    return [string]$reader.ReadLine()
  } catch {
    return "no answer: $($_.Exception.Message)"
  } finally {
    $client.Dispose()
  }
}

# a log line's time, as the helper writes it (ISO, UTC); $null when it is not one
function ConvertTo-LogTime([string]$At) {
  $time = [DateTime]::MinValue
  $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
  if ([DateTime]::TryParse($At, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$time)) { return $time }
  return $null
}

# A log's lines, parsed: "<ISO time> <LEVEL> <message> <JSON facts>" (log.ts:64-71); helper.log unless said,
# print.log being the print process's own (log.ts:73-76).
function Get-LogEntries([string]$Path = $LogFile) {
  $text = Read-SharedText $Path
  if ($null -eq $text) { return }
  foreach ($line in ($text -split "`r?`n")) {
    if ($line -eq '') { continue }
    if ($line -match '^(?<at>\S+) (?<level>INFO|WARN|ERROR) (?<message>.*?)(?: (?<data>\{.*\}))?$') {
      $at = $Matches['at']
      $level = $Matches['level']
      $message = $Matches['message']
      $dataText = if ($Matches.ContainsKey('data')) { $Matches['data'] } else { '' }
      $data = $null
      if ($dataText) { try { $data = $dataText | ConvertFrom-Json } catch { $data = $null } }
      [pscustomobject]@{ At = $at; Time = (ConvertTo-LogTime $at); Level = $level; Message = $message; Data = $data; Line = $line }
    } else {
      [pscustomobject]@{ At = ''; Time = $null; Level = '?'; Message = $line; Data = $null; Line = $line }
    }
  }
}

function Get-LogCount([string]$Message, [string]$Path = $LogFile) {
  return @(Get-LogEntries $Path | Where-Object { $_.Message -eq $Message }).Count
}

function Get-LogTail([int]$Count = 20, [string]$Path = $LogFile) {
  return @(Get-LogEntries $Path | Select-Object -Last $Count | ForEach-Object { $_.Line })
}

# the index of the first entry the test accepts, or -1
function Find-Index($Items, [scriptblock]$Test) {
  $list = @($Items)
  for ($i = 0; $i -lt $list.Count; $i++) {
    $item = $list[$i]
    if (& $Test $item) { return $i }
  }
  return -1
}

# Whatever of the helper is still on this computer, one line each (nothing: the uninstall's end).
function Get-Leftovers {
  $helper = @(Get-HelperProcesses)
  if ($helper.Count -gt 0) { 'processes: ' + (($helper | ForEach-Object { "$($_.Role) $($_.Pid)" }) -join ', ') }
  $shells = @(Get-SpoolerShells)
  if ($shells.Count -gt 0) { "the print process's PowerShell still runs: $(Format-Shells $shells)" }
  # NSIS's uninstaller runs from its own copy in %TEMP%\~nsu*.tmp while it works
  $copies = @(Get-CimInstance -ClassName Win32_Process | Where-Object { [string]$_.ExecutablePath -like '*\~nsu*.tmp\*' })
  if ($copies.Count -gt 0) { 'the uninstaller still runs: ' + (($copies | ForEach-Object { "$($_.Name) $($_.ProcessId)" }) -join ', ') }
  if (Test-Path -LiteralPath $ProgramDir) {
    'the program folder, holding: ' + ((@(Get-ChildItem -LiteralPath $ProgramDir -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })) -join ', ')
  }
  if (Test-Path -LiteralPath $DataDir) {
    'the data folder, holding: ' + ((@(Get-ChildItem -LiteralPath $DataDir -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })) -join ', ')
  }
  if ($null -ne (Get-RegValue $RunKey $AppId)) { "the Run key's $AppId value" }
  if (Test-Path -LiteralPath $UninstallKey) { "the Settings > Apps entry ($UninstallKey)" }
  if (Test-Path -LiteralPath $AppKey) { "the key $AppKey" }
  if (Test-Path -LiteralPath $Shortcut) { "the Start menu shortcut ($Shortcut)" }
}

# the helper's logs: helper.log and, from 0.3.0, print.log, with the files moved aside past 1 MB (log.ts:113-132)
function Get-HelperLogFiles {
  @(Get-ChildItem -LiteralPath $LogsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'helper.log*' -or $_.Name -like 'print.log*' })
}

# the helper's logs into the evidence, read as the helper's writes allow; the names copied
function Save-Logs {
  foreach ($file in @(Get-HelperLogFiles)) {
    Save-Text (Join-Path 'logs' $file.Name) (Read-SharedText $file.FullName)
    $file.Name
  }
}

# Everything the uninstall will take, kept first: logs, runtime.json (secrets masked), print-status.json,
# processes, keys, folders.
function Save-Evidence([string]$Label) {
  try {
    $null = @(Save-Logs)
    Save-Json "runtime-$Label.json" (Read-Runtime)
    $printStatus = Read-SharedText $PrintStatusFile
    if ($null -ne $printStatus) { Save-Text "print-status-$Label.json" $printStatus }
    Save-Processes $Label
    $apps = $null
    if (Test-Path -LiteralPath $UninstallKey) {
      $key = Get-Item -LiteralPath $UninstallKey
      $apps = [ordered]@{}
      foreach ($valueName in $key.GetValueNames()) { $apps[$valueName] = $key.GetValue($valueName) }
    }
    Save-Json "registry-$Label.json" ([ordered]@{
        run        = Get-RegValue $RunKey $AppId
        installDir = Get-RegValue $AppKey 'InstallDir'
        uninstall  = $apps
      })
    $program = @(Get-ChildItem -LiteralPath $ProgramDir -Force -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { [ordered]@{ path = $_.FullName; bytes = $(if ($_.PSIsContainer) { $null } else { $_.Length }); written = $_.LastWriteTimeUtc.ToString('o') } })
    $data = @(Get-ChildItem -LiteralPath $DataDir -Force -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { [ordered]@{ path = $_.FullName; bytes = $(if ($_.PSIsContainer) { $null } else { $_.Length }); written = $_.LastWriteTimeUtc.ToString('o') } })
    Save-Json "folders-$Label.json" ([ordered]@{ program = $program; data = $data })
    $S.EvidenceSaved = $true
  } catch {
    Write-Host "    (saving the evidence: $($_.Exception.Message))"
  }
}

# ---------------------------------------------------------------------------------------------------------
# Windows' printing, as the print process does it (check 4)
# ---------------------------------------------------------------------------------------------------------

# alty-helper.exe --print-check [PRINTER] (main.ts:51-52, :279-293; print/check.ts:40-102), run as a person at a PC
# runs it, from this folder and beside the running helper: its JSON lines on its standard output, which a windowed
# program has only when it is read (print/check.ts:14-16), and its exit code; and the Windows PowerShell it starts
# for the spooler (print/windows.ts:570-575), looked at while it runs, so its command line can be read.
function Invoke-PrintCheck([string]$Label, [string]$Printer = '', [double]$Seconds = 150) {
  $info = [System.Diagnostics.ProcessStartInfo]::new($Exe)
  $info.ArgumentList.Add('--print-check')
  if ($Printer -ne '') { $info.ArgumentList.Add($Printer) }
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.WorkingDirectory = $WorkDir
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $info.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
  $clock = [System.Diagnostics.Stopwatch]::StartNew()
  $shells = [ordered]@{}
  $ended = $false
  $exitCode = $null
  $stdout = ''
  $stderr = ''
  $process = [System.Diagnostics.Process]::Start($info)
  $checkPid = $process.Id
  try {
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    while (-not $ended) {
      foreach ($sh in @(Get-SpoolerShells | Where-Object { $_.ParentPid -eq $checkPid })) { $shells["$($sh.Pid)"] = $sh }
      $ended = $process.WaitForExit(150)
      if (-not $ended -and $clock.Elapsed.TotalSeconds -ge $Seconds) { break }
    }
    if ($ended) {
      $process.WaitForExit()
      $exitCode = $process.ExitCode
    } else {
      try { $process.Kill($true) } catch { }
      $null = $process.WaitForExit(10000)
    }
    if ($out.Wait(10000)) { $stdout = [string]$out.Result }
    if ($err.Wait(10000)) { $stderr = [string]$err.Result }
  } finally {
    Close-Process $process
  }
  $took = [math]::Round($clock.Elapsed.TotalSeconds, 1)
  $lines = @(foreach ($line in ($stdout -split "`r?`n")) {
      if ($line.Trim() -eq '') { continue }
      try { $line | ConvertFrom-Json } catch { [pscustomobject]@{ check = '?'; text = $line } }
    })
  $command = "`"$Exe`" --print-check$(if ($Printer -ne '') { " `"$Printer`"" })"
  Save-Text "print-check-$Label.txt" "$command`nprocess $checkPid, exit code $(if ($ended) { $exitCode } else { "none: ended after $Seconds s" }), after $took s`n--- its standard output`n$stdout`n--- its standard error`n$stderr`n"
  # its PowerShell ends with it: the check closes it (print/check.ts:99-101, print/windows.ts:766-781)
  $gone = Wait-Until { if (@(Get-SpoolerShells | Where-Object { $_.ParentPid -eq $checkPid }).Count -eq 0) { $true } } -Seconds 10
  [pscustomobject]@{
    Command    = $command
    Pid        = $checkPid
    Ended      = $ended
    ExitCode   = $exitCode
    Seconds    = $took
    Lines      = $lines
    Stdout     = $stdout
    Stderr     = $stderr
    Shells     = @($shells.Values)
    ShellsGone = ($gone -eq $true)
  }
}

# what a --print-check said on its standard output, on one line
function Format-Said($Run) {
  $text = (($Run.Stdout -split "`r?`n") | Where-Object { $_.Trim() -ne '' }) -join ' / '
  if ($text.Length -gt 500) { $text = $text.Substring(0, 500) + ' ...' }
  if ($text -eq '') { return '(nothing on its standard output)' }
  return $text
}

# the helper's printers (HelperPrinterDto: shared api/print.ts), one line
function Format-Printers($Printers) {
  $list = @($Printers)
  if ($list.Count -eq 0) { return 'none' }
  return (($list | ForEach-Object { "'$($_.name)' ($(if ($_.isDefault) { 'default, ' })$($_.state), driver '$($_.driver)', port '$($_.port)', $($_.jobs) queued)" }) -join ', ')
}

# Windows' printers as Windows itself lists them (WMI), for the helper's list to be held to
function Get-WindowsPrinters {
  foreach ($w in @(Get-CimInstance -ClassName Win32_Printer)) {
    [pscustomobject]@{ Name = [string]$w.Name; Driver = [string]$w.DriverName; Port = [string]$w.PortName; Default = [bool]$w.Default }
  }
}

function Format-WindowsPrinters($Windows) {
  $list = @($Windows)
  if ($list.Count -eq 0) { return 'none' }
  return (($list | ForEach-Object { "'$($_.Name)' ($(if ($_.Default) { 'default, ' })driver '$($_.Driver)', port '$($_.Port)')" }) -join ', ')
}

# How the helper's list differs from Windows' own: one line for each difference (none: the same printers, each
# with Windows' driver, port and default; print/windows.ts:177-215, print/spooler.ts:274-287)
function Compare-Printers($Listed, $Windows) {
  $listed = @($Listed)
  foreach ($w in @($Windows)) {
    $same = @($listed | Where-Object { [string]$_.name -ceq $w.Name })
    if ($same.Count -ne 1) { "'$($w.Name)' is listed $($same.Count) times"; continue }
    $x = $same[0]
    if ([string]$x.driver -cne $w.Driver) { "'$($w.Name)' has driver '$($x.driver)', Windows says '$($w.Driver)'" }
    if ([string]$x.port -cne $w.Port) { "'$($w.Name)' has port '$($x.port)', Windows says '$($w.Port)'" }
    if ([bool]$x.isDefault -ne $w.Default) { "'$($w.Name)' is default: $($x.isDefault), Windows says $($w.Default)" }
  }
  foreach ($x in $listed) {
    if (@($Windows | Where-Object { $_.Name -ceq [string]$x.name }).Count -eq 0) { "'$($x.name)' is not one of Windows' printers" }
  }
}

# Each --print-check's own PowerShell: Windows PowerShell by its full path, with exactly the print process's
# command line (the constant script, print/windows.ts:386-400), so a printer's name never travels in it but on
# its input only (:15-26); and ended once the check ended
function Test-CheckShells($Run, [string]$LaneCommand, [string]$Printer = '') {
  $shells = @($Run.Shells)
  Expect ($shells.Count -ge 1 -and @($shells | Where-Object { $_.Path -ine $SpoolerExe }).Count -eq 0) "it ran its own Windows PowerShell: $(Format-Shells $shells), $SpoolerExe"
  $same = @($shells | Where-Object { $_.CommandLine -ceq $LaneCommand })
  Expect ($shells.Count -ge 1 -and $same.Count -eq $shells.Count) "with exactly the print process's command line ($(if ($LaneCommand) { "$($LaneCommand.Length) characters" } else { 'none known' }))"
  if ($Printer -ne '') {
    $named = @($shells | Where-Object { $_.CommandLine.Contains($Printer) })
    Expect ($shells.Count -ge 1 -and $named.Count -eq 0) "'$Printer' is not in its command line: the name went on its input"
  }
  Expect $Run.ShellsGone 'its PowerShell ended with it (print/check.ts:99-101, print/windows.ts:766-781)'
}

# The check's print exactly as print/check.ts:20-35 makes it: ESC @, 'Alty: Windows printing works' and the time
# it was made (ISO), each ended by LF, then ESC d 4 and GS V 66 0: 63 bytes
function Test-CheckBytes([byte[]]$Bytes, [DateTime]$Since) {
  $hex = (@($Bytes | Select-Object -First 80 | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
  if ($Bytes.Length -ne 63) { return [pscustomobject]@{ Ok = $false; Text = "$($Bytes.Length) bytes, not the 63 the check writes: $hex" } }
  $tail = [byte[]](0x1B, 0x64, 0x04, 0x1D, 0x56, 0x42, 0x00)
  $tailOk = $true
  for ($i = 0; $i -lt $tail.Length; $i++) { if ($Bytes[56 + $i] -ne $tail[$i]) { $tailOk = $false } }
  $headOk = $Bytes[0] -eq 0x1B -and $Bytes[1] -eq 0x40
  $text = [System.Text.Encoding]::ASCII.GetString($Bytes, 2, 54)
  $when = $null
  if ($text -cmatch '^Alty: Windows printing works\n(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z)\n$') { $when = ConvertTo-LogTime $Matches[1] }
  $timely = $null -ne $when -and $when -ge $Since.AddSeconds(-5) -and $when -le [DateTime]::UtcNow.AddSeconds(5)
  $shown = $text.Replace("`n", '\n')
  return [pscustomobject]@{
    Ok   = ($headOk -and $tailOk -and $timely)
    Text = "ESC @ $(if ($headOk) { 'first' } else { 'missing' }), '$shown'$(if (-not $timely) { ' (not the text and time of this check)' }), ESC d 4 GS V 66 0 $(if ($tailOk) { 'last' } else { 'missing' })"
  }
}

# Check 4's printer: Windows' own text driver (from Windows' driver store, as the Add Printer wizard takes it), a
# local port that is a file, and a printer on both. Its driver's name, or a throw when Windows has no such driver.
function Add-RawPrinter {
  Remove-RawPrinter -Quiet
  Remove-Item -LiteralPath $RawPort -Force -ErrorAction SilentlyContinue
  if ($null -eq (Get-PrinterDriver -Name $RawDriver -ErrorAction SilentlyContinue)) {
    try {
      Add-PrinterDriver -Name $RawDriver
    } catch {
      $drivers = @(Get-PrinterDriver -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
      throw "Windows would not add its driver '$RawDriver' ($($_.Exception.Message)); it has: $($drivers -join ', ')"
    }
  }
  Add-PrinterPort -Name $RawPort
  Add-Printer -Name $RawPrinter -DriverName $RawDriver -PortName $RawPort
  return $RawDriver
}

function Remove-RawPrinter([switch]$Quiet) {
  $left = [System.Collections.Generic.List[string]]::new()
  try {
    if ($null -ne (Get-Printer -Name $RawPrinter -ErrorAction SilentlyContinue)) { Remove-Printer -Name $RawPrinter }
  } catch {
    $left.Add("the printer ($($_.Exception.Message))")
  }
  # the spooler may hold the port a moment after the printer goes
  $portGone = Wait-Until {
    if ($null -ne (Get-PrinterPort -Name $RawPort -ErrorAction SilentlyContinue)) { Remove-PrinterPort -Name $RawPort }
    if ($null -eq (Get-PrinterPort -Name $RawPort -ErrorAction SilentlyContinue)) { $true }
  } -Seconds 10 -EveryMs 500
  if (-not $portGone) { $left.Add('its port') }
  Remove-Item -LiteralPath $RawPort -Force -ErrorAction SilentlyContinue
  if (-not $Quiet) { Note "'$RawPrinter' and its port removed$(if ($left.Count) { ', but not ' + ($left -join ', ') })" }
}

function Write-Report {
  $rows = @(foreach ($id in $CheckNames.Keys) {
      $r = $Results | Where-Object { $_.Id -eq $id } | Select-Object -First 1
      if ($null -eq $r) {
        [pscustomobject]@{ Id = $id; Name = $CheckNames[$id]; Status = 'NOT RUN'; Seconds = ''; Saw = 'the script stopped before this check'; Evidence = @(); Failures = @() }
      } else {
        $saw = if ($r.Failures.Count -gt 0) { 'FAILED: ' + ($r.Failures -join '; ') } elseif ($r.Headline) { $r.Headline } else { [string]($r.Evidence | Select-Object -Last 1) }
        [pscustomobject]@{ Id = $r.Id; Name = $r.Name; Status = $r.Status; Seconds = $r.Seconds; Saw = $saw; Evidence = @($r.Evidence); Failures = @($r.Failures) }
      }
    })
  $passed = @($rows | Where-Object { $_.Status -eq 'PASS' }).Count
  $skipped = @($rows | Where-Object { $_.Status -eq 'SKIP' }).Count
  $script:Verdict = if ($passed + $skipped -eq $rows.Count) { 'PASS' } else { 'FAIL' }
  $counted = "$passed of $($rows.Count) checks passed$(if ($skipped) { ", $skipped skipped (what they check came after $ExpectedVersion)" })"

  $table = [System.Collections.Generic.List[string]]::new()
  $table.Add("### $($script:Verdict): Alty helper $ExpectedVersion on $($Environment.os)")
  $table.Add('')
  $table.Add("$counted. The run's artifact keeps the evidence: the helper's logs, its /api/status answers, the process lists, the print checks' output and report.md.")
  $table.Add('')
  $table.Add('| # | Check | Result | Seconds | What it saw |')
  $table.Add('|---|---|---|---|---|')
  foreach ($row in $rows) {
    $table.Add("| $($row.Id) | $(Format-Cell $row.Name) | **$($row.Status)** | $($row.Seconds) | $(Format-Cell $row.Saw) |")
  }
  $summary = $table -join "`n"

  $details = [System.Collections.Generic.List[string]]::new()
  $details.Add('## Where it ran')
  foreach ($key in $Environment.Keys) { $details.Add("- ${key}: $($Environment[$key])") }
  foreach ($row in $rows) {
    $details.Add('')
    $details.Add("## $($row.Id). $($row.Name): $($row.Status)$(if ($row.Seconds -ne '') { " ($($row.Seconds) s)" })")
    foreach ($line in $row.Evidence) { $details.Add("- $line") }
  }
  Save-Text 'report.md' ($summary + "`n`n" + ($details -join "`n") + "`n")
  Save-Json 'report.json' ([ordered]@{
      verdict     = $script:Verdict
      environment = $Environment
      checks      = @($rows | ForEach-Object { [ordered]@{ id = $_.Id; name = $_.Name; status = $_.Status; seconds = $_.Seconds; saw = $_.Saw; failures = @($_.Failures); evidence = @($_.Evidence) } })
    })
  $stepSummary = [Environment]::GetEnvironmentVariable('GITHUB_STEP_SUMMARY')
  if ($stepSummary) { Add-Content -LiteralPath $stepSummary -Value (Protect-Text ($summary + "`n")) -Encoding utf8 }

  Write-Host ''
  Write-Host "=== $($script:Verdict): $counted"
  foreach ($row in $rows) { Write-Host ("    {0,-7} {1}. {2}" -f $row.Status, $row.Id, $row.Name) }
}

# ---------------------------------------------------------------------------------------------------------
# Where it runs
# ---------------------------------------------------------------------------------------------------------
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$Environment = [ordered]@{
  image           = "$([Environment]::GetEnvironmentVariable('ImageOS')) $([Environment]::GetEnvironmentVariable('ImageVersion'))".Trim()
  os              = "$($os.Caption) $($os.Version)"
  uiLanguage      = (Get-UICulture).Name
  powershell      = $PSVersionTable.PSVersion.ToString()
  user            = "$([Environment]::UserDomainName)\$([Environment]::UserName)"
  localAppData    = $env:LOCALAPPDATA
  installer       = $Installer
  installerSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Installer).Hash.ToLowerInvariant()
  expectedVersion = $ExpectedVersion
  printProcess    = $(if ($HasPrint) { "expected (since $PrintSince)" } else { "none: it came with $PrintSince" })
  startedUtc      = [DateTime]::UtcNow.ToString('o')
}
Write-Host '=== Where it runs'
foreach ($key in $Environment.Keys) { Write-Host "    ${key}: $($Environment[$key])" }
# the helper reads ALTY_API_URL, ALTY_HELPER_HOME, ALTY_HELPER_PORT ... (README): this test wants its defaults
foreach ($name in @(Get-ChildItem -Path Env: | Where-Object { $_.Name -like 'ALTY_*' } | ForEach-Object { $_.Name })) {
  Write-Host "    unset $name for the test"
  Remove-Item -LiteralPath "Env:$name"
}
Save-Json 'environment.json' $Environment
$total = [System.Diagnostics.Stopwatch]::StartNew()

try {
  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '1' {
    # a fresh computer first: nothing of the helper's, and its port free
    $before = @(Get-Leftovers)
    Expect ($before.Count -eq 0) "nothing of the helper's before the install$(if ($before.Count) { ': ' + ($before -join '; ') })"
    $listening = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq $Port })
    Expect ($listening.Count -eq 0) "nothing listens on port $Port before the install"

    # no UAC prompt: the runner's user is an administrator, so none could show here; the manifest decides it
    $level = Get-ManifestLevel $Installer
    Expect ($level -eq 'asInvoker') "the installer's manifest asks for level `"$level`" (asInvoker: no administrator prompt, .nsi:17)"
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Note "this runner's user is an administrator: $admin"
    $version = (Get-Item -LiteralPath $Installer).VersionInfo.ProductVersion
    Expect ($version -eq $ExpectedVersion) "the installer's version resource says $version (.nsi:45-49)"

    # /S shows no page; at its end .onInstSuccess starts the helper in place of the finish page's
    # checkbox (.nsi:124-127)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $setup = Start-Process -FilePath $Installer -ArgumentList '/S' -PassThru
    try {
      $null = $setup.Handle   # held, so the exit code is there once it ends
      $ended = $setup.WaitForExit(180000)
      $setupCode = if ($ended) { $setup.ExitCode } else { $null }
    } finally {
      Close-Process $setup
    }
    $S.InstalledAt = [DateTime]::UtcNow
    $took = [math]::Round($clock.Elapsed.TotalSeconds, 1)
    Expect ($ended -and $setupCode -eq 0) "the installer ended after $took s with exit code $(if ($ended) { $setupCode } else { 'none: still running after 180 s' })"

    # the program, for this user only (.nsi:39, :84-88)
    $files = @(Get-ChildItem -LiteralPath $ProgramDir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $want = @('alty-helper.exe', 'alty.ico', 'uninstall.exe')
    $exact = $files.Count -eq $want.Count -and @($want | Where-Object { $files -notcontains $_ }).Count -eq 0
    Expect $exact "$ProgramDir holds: $($files -join ', ')"
    $installDir = Get-RegValue $AppKey 'InstallDir'
    Expect ($installDir -eq $ProgramDir) "HKCU\Software\$AppId InstallDir = $installDir (.nsi:89)"

    # starts at this user's sign-in (.nsi:91)
    $run = Get-RegValue $RunKey $AppId
    Expect ($run -eq "`"$Exe`"") "HKCU ...\Run $AppId = $run"

    # the Start menu's Alty Helper opens the helper's page (.nsi:32, :93)
    $link = Get-Shortcut
    $S.Link = $link
    Expect ($null -ne $link) "the Start menu shortcut is there: $Shortcut"
    if ($null -ne $link) {
      Expect ($link.TargetPath -eq $Exe -and $link.Arguments -eq '--open') "it runs `"$($link.TargetPath)`" $($link.Arguments)"
      Note "it starts in $($link.WorkingDirectory), icon $($link.IconLocation)"
    }

    # Settings > Apps (.nsi:95-103)
    $display = Get-RegValue $UninstallKey 'DisplayName'
    $displayVersion = Get-RegValue $UninstallKey 'DisplayVersion'
    Expect ($display -eq 'Alty Helper' -and $displayVersion -eq $ExpectedVersion) "Settings > Apps lists '$display' $displayVersion"
    $quiet = Get-RegValue $UninstallKey 'QuietUninstallString'
    Expect ($quiet -eq "`"$Uninstaller`" /S") "its quiet uninstall: $quiet"

    # nothing for the whole computer: no HKLM entry, nothing in Program Files
    $machineRuns = @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' |
        Where-Object { $null -ne (Get-RegValue $_ $AppId) } | ForEach-Object { "$_ $AppId" })
    $machinePlaces = @(
      "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppId",
      "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$AppId",
      "HKLM:\Software\$AppId",
      "HKLM:\Software\WOW6432Node\$AppId",
      (Join-Path $env:ProgramFiles 'Alty Helper'),
      (Join-Path ${env:ProgramFiles(x86)} 'Alty Helper')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $machine = @($machineRuns) + @($machinePlaces)
    Expect ($machine.Count -eq 0) "nothing written for the whole computer (HKLM, Program Files)$(if ($machine.Count) { ': ' + ($machine -join ', ') })"

    # windowed, so no console window opens at sign-in (pe.ts:8; package-win.ts:130-132)
    if (Test-Path -LiteralPath $Exe) {
      $subsystem = Get-Subsystem $Exe
      Expect ($subsystem -eq 2) "alty-helper.exe is a windowed program (PE subsystem $subsystem)"
      Note "alty-helper.exe's signature: $((Get-AuthenticodeSignature -LiteralPath $Exe).Status) (not code-signed yet)"
    }
    Headline "installed in $took s for this user (manifest $level); program, Run key, shortcut and Apps entry as the .nsi writes them"
  }

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '2' {
    if ($null -eq $S.InstalledAt) { throw 'the install did not run' }
    # the page on 47100 unless ALTY_HELPER_PORT says otherwise (worker.ts:474-487), within 20 s of the install
    $window = [Math]::Max(1, ($S.InstalledAt.AddSeconds(20) - [DateTime]::UtcNow).TotalSeconds)
    $up = Wait-Until { Test-Page -Base $PageUrl } -Seconds $window
    $after = [math]::Round(([DateTime]::UtcNow - $S.InstalledAt).TotalSeconds, 1)
    Expect ($up -eq $true) "the page answered at $PageUrl $after s after the install"

    # its start is complete once runtime.json names the worker (worker.ts:488-496) and the log has its line (:498-503)
    $ready = Wait-Until {
      $h = Get-Helper
      $rt = Read-Runtime
      if ((Test-Running $h) -and $null -ne $rt -and $rt.workerPid -eq $h.Workers[0].Pid -and
        (Get-LogCount 'helper: started') -ge 1) { $true }
    } -Seconds 10
    if (-not $ready) { Note 'its start did not complete within 10 s more' }

    # exactly one supervisor and its worker, and from 0.3.0 its print process (main.ts:106-192)
    $h = Get-Helper
    Save-Processes 'check2'
    Expect (Test-Whole $h) "exactly $WholeText`: $(Format-Helper $h)"
    if ($h.Supervisors.Count -eq 1 -and $h.Workers.Count -eq 1) {
      $sup = $h.Supervisors[0]
      $wk = $h.Workers[0]
      $S.Supervisor = $sup
      $S.Worker = $wk
      $S.FirstSupervisorPid = $sup.Pid
      Expect ($wk.ParentPid -eq $sup.Pid) "the worker $($wk.Pid) is the supervisor's ($($sup.Pid)) child (main.ts:154-167)"
      Expect ($sup.Path -eq $Exe -and $wk.Path -eq $Exe) "both run $Exe"
      Expect ((Get-ArgumentsOf $sup.CommandLine) -eq '') "the supervisor has no arguments, as the Run key starts it: $($sup.CommandLine)"
      Expect ((Get-ArgumentsOf $wk.CommandLine) -eq '--worker') "the worker's arguments: $(Get-ArgumentsOf $wk.CommandLine)"
      if ($HasPrint -and $h.Prints.Count -eq 1) {
        $pr = $h.Prints[0]
        $S.Print = $pr
        Expect ($pr.ParentPid -eq $sup.Pid) "the print process $($pr.Pid) is the supervisor's child too (main.ts:170-190)"
        Expect ($pr.Path -eq $Exe) "it runs $Exe as well"
        Expect ((Get-ArgumentsOf $pr.CommandLine) -eq '--print-worker') "the print process's arguments: $(Get-ArgumentsOf $pr.CommandLine)"
      }
    }
    if (-not $HasPrint) { Note "no print process expected: $ExpectedVersion is older than $PrintSince" }

    # runtime.json: the instance, for a second start's --open and the installer's --quit (main.ts:125-133)
    $rt = Read-Runtime
    Expect ($null -ne $rt) "runtime.json is there: $RuntimeFile"
    if ($null -ne $rt) {
      if ($rt.url) { $S.Url = [string]$rt.url }
      if ($null -ne $S.Supervisor) {
        Expect ($rt.supervisorPid -eq $S.Supervisor.Pid -and $rt.workerPid -eq $S.Worker.Pid) "runtime.json names supervisor $($rt.supervisorPid) and worker $($rt.workerPid)"
      }
      Expect ($rt.url -eq $PageUrl -and $rt.version -eq $ExpectedVersion) "runtime.json: page $($rt.url), version $($rt.version)"
      Expect (-not [string]::IsNullOrEmpty([string]$rt.quitSecret) -and -not [string]::IsNullOrEmpty([string]$rt.lockSecret)) 'runtime.json holds the quit secrets of the page and of the supervisor (not shown)'
    }

    # what the page says (worker.ts:370-387)
    $status = Get-Status -Base $PageUrl
    Expect ($null -ne $status) 'GET /api/status answers 200'
    if ($null -ne $status) {
      Expect ($status.app -eq 'alty-helper' -and $status.version -eq $ExpectedVersion) "it is $($status.app) $($status.version)"
      Expect ($status.link.kind -eq 'unpaired' -and $null -eq $status.pairing) "it says unpaired (link $($status.link.kind), pairing $(if ($null -eq $status.pairing) { 'none' } else { 'set' }); worker.ts:130-131)"
      Expect ($status.apiUrl -eq $ApiUrl) "its server is $($status.apiUrl) (store.ts:6, :63)"
      Expect ($status.update.status -eq 'current') "its update status is '$($status.update.status)': a release key is compiled in ('off' would mean none; update.ts:58)"
      Expect ($status.language -eq 'hy' -and $status.logs -eq $LogsDir) "its page speaks $($status.language) (worker.ts:374) and names its logs $($status.logs)"
      Expect ($null -eq $status.lastError.link -and $null -eq $status.lastError.pairing) 'no error since its start'
    }

    # the page itself: in Armenian, with its CSP, carrying the token a change needs (server.ts:119-132)
    $page = Invoke-Page -Base $PageUrl
    $html = Get-Body $page
    if ($html -match 'const CSRF = "([A-Za-z0-9_-]+)";') { Add-Secret $Matches[1] }
    Expect ($null -ne $page -and $page.StatusCode -eq 200) "GET / answers $(if ($null -ne $page) { $page.StatusCode } else { 'nothing' })"
    $csp = Get-Header $page 'Content-Security-Policy'
    Expect ($csp.StartsWith("default-src 'none'")) "its Content-Security-Policy: $csp"
    Expect ($html.Contains("<title>$HyTitle</title>")) "it is in Armenian: <title>$HyTitle</title> (page.ts:246, i18n/hy.ts:10)"
    Save-Text 'page.html' $html

    $printSaid = ''
    if ($HasPrint) {
      # The print process, unpaired, reads Windows' printers at once, for the page (print/worker.ts:508-509),
      # through its own Windows PowerShell, which first compiles the C# over winspool.drv and is given a minute for
      # it (print/windows.ts:403, :570-616); the page shows what it says of itself (worker.ts:224-246)
      $read = Wait-Until {
        $x = Read-Status
        if ($null -ne $x -and $null -ne $x.print -and ($null -ne $x.print.printers -or $null -ne $x.print.printersProblem)) { $true }
      } -Seconds 75 -EveryMs 500
      $readAfter = [math]::Round(([DateTime]::UtcNow - $S.InstalledAt).TotalSeconds, 1)
      if (-not $read) { Note "the print process said nothing of Windows' printers within 75 s" }
      $status = Get-Status
      $p = if ($null -ne $status) { $status.print } else { $null }
      Expect ($null -ne $p) "GET /api/status has the print process's part (status/types.ts:52-74)"
      if ($null -ne $p) {
        Expect ($p.lane -eq $true -and $p.installed -eq $ExpectedVersion) "the installed program starts a print process (lane $($p.lane), installed $($p.installed))"
        Expect ($p.running -eq $true -and $p.version -eq $ExpectedVersion -and $p.link -eq 'unpaired') "the print process runs $($p.version), its link $($p.link) (print/status.ts:120-121)"
        Expect ($null -ne $p.printers -and $null -eq $p.printersProblem) "it read Windows' printers through its PowerShell, $readAfter s after the install: $(Format-Printers $p.printers)$(if ($null -ne $p.printersProblem) { "; problem: $($p.printersProblem)" })"
        Expect ($p.route.known -eq $false -and $null -eq $p.last) 'unpaired, it asked the server nothing and printed nothing (print/worker.ts:427-454: no hello without a pairing)'
        $printSaid = Format-Printers $p.printers
      }
      $ps = Read-PrintStatus
      Expect ($null -ne $ps -and $null -ne $S.Print -and $ps.pid -eq $S.Print.Pid -and $null -eq $ps.deviceId) "print-status.json is the print process's own: pid $(if ($null -ne $ps) { $ps.pid } else { 'none' }), no pairing (print/worker.ts:162-179)"

      # its Windows PowerShell: one, its child, by its full path, with the constant script (print/windows.ts:386-400)
      $shells = @(Get-SpoolerShells)
      Expect ($shells.Count -eq 1 -and $null -ne $S.Print -and $shells[0].ParentPid -eq $S.Print.Pid) "one Windows PowerShell for the spooler, the print process's child: $(Format-Shells $shells)"
      if ($shells.Count -ge 1) {
        $sh = $shells[0]
        $S.SpoolerCommand = $sh.CommandLine
        $shellArgs = Get-ArgumentsOf $sh.CommandLine
        Expect ($sh.Path -ieq $SpoolerExe) "it is Windows PowerShell by its full path: $($sh.Path) (fiscal/powershell.ts:40-49)"
        Expect ($shellArgs.StartsWith('-NoLogo -NoProfile -NonInteractive -Command ')) "with the constant script: $($shellArgs.Substring(0, [Math]::Min(56, $shellArgs.Length))) ... ($($sh.CommandLine.Length) characters)"
      }

      # what its log says (print/worker.ts:524-529; print/windows.ts:614)
      $printEntries = @(Get-LogEntries $PrintLogFile)
      $prStarted = @($printEntries | Where-Object { $_.Message -eq 'print: started' })
      $shellStarted = @($printEntries | Where-Object { $_.Message -eq 'print: Windows PowerShell started for the spooler' })
      Expect ($prStarted.Count -eq 1) "print.log has the print process's start: $(if ($prStarted.Count) { $prStarted[0].Line } else { 'no such line' })"
      Expect ($shellStarted.Count -eq 1) "and its PowerShell's, compiled and ready: $(if ($shellStarted.Count) { $shellStarted[0].Line } else { 'no such line' })"
    }
    Headline "page at $PageUrl after $after s; supervisor $(if ($S.Supervisor) { $S.Supervisor.Pid }), worker $(if ($S.Worker) { $S.Worker.Pid })$(if ($HasPrint) { " and print process $(if ($S.Print) { $S.Print.Pid }), its PowerShell up and Windows' printers read: $printSaid" }); unpaired; server $ApiUrl; release key compiled in"
  }

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '3' {
    $page = Invoke-Page
    $html = Get-Body $page
    if (-not ($html -match 'const CSRF = "([A-Za-z0-9_-]+)";')) { throw "the page carries no token (page.ts:348): $(Format-Answer $page)" }
    $csrf = $Matches[1]
    Add-Secret $csrf
    $origin = $S.Url.TrimEnd('/')   # the page's own origin, which a browser sends with its POST
    $refusedBefore = Get-LogCount 'helper: pairing refused'

    # the page's guards (server.ts:114-117, :150-157), each tried with an empty body, which could not reach the
    # server even if a guard let it through (server.ts:167-171)
    $noToken = Invoke-Page -Path 'api/pair' -Method 'POST' -Headers @{ Origin = $origin } -Body '{}'
    Expect ($null -ne $noToken -and $noToken.StatusCode -eq 403) "a change without the page's token is refused: $(Format-Answer $noToken)"
    $otherSite = Invoke-Page -Path 'api/pair' -Method 'POST' -Headers @{ 'x-helper-csrf' = $csrf; Origin = 'https://example.com' } -Body '{}'
    Expect ($null -ne $otherSite -and $otherSite.StatusCode -eq 403) "a change from another site's origin is refused: $(Format-Answer $otherSite)"
    $otherHost = Send-RawRequest "example.com:$(([Uri]$S.Url).Port)"
    Expect ($otherHost -match '^HTTP/1\.1 421 ') "a request under another Host (DNS rebinding) is refused: $otherHost"

    # the pairing as the page's script sends it (page.ts:366-368, :583-589): POST /api/pair, {"code": ...},
    # its token and its origin. The helper claims it at the server (worker.ts:339-368, api.ts:249-252)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $answer = Invoke-Page -Path 'api/pair' -Method 'POST' -Headers @{ 'x-helper-csrf' = $csrf; Origin = $origin } -Body (ConvertTo-Json -InputObject @{ code = $WrongCode } -Compress) -TimeoutSec 60
    $took = [math]::Round($clock.Elapsed.TotalSeconds, 1)
    $json = $null
    try { $json = (Get-Body $answer) | ConvertFrom-Json } catch { $json = $null }
    # the server's 404 registration_invalid comes back as the page's 400 {ok:false, error:'registration_invalid'}
    # (api.ts:223-231, worker.ts:362-366, server.ts:172-173); a network or TLS failure would say 'network'
    Expect ($null -ne $answer -and $answer.StatusCode -eq 400 -and $null -ne $json -and $json.ok -eq $false -and $json.error -eq 'registration_invalid') "the page answered $(Format-Answer $answer) after $took s"

    # why, as the page's details say it (worker.ts:364; log.ts:31-55): the server's own words and code
    $status = Get-Status
    $note = $null
    if ($null -ne $status -and $null -ne $status.lastError) { $note = $status.lastError.pairing }
    $reason = if ($null -ne $note) { [string]$note.text } else { '(none)' }
    Expect ($reason.StartsWith('HelperApiError: ') -and $reason.EndsWith('[registration_invalid]')) "the reason is the server's answer, not a network or TLS error: $reason"
    $refused = @(Get-LogEntries | Where-Object { $_.Message -eq 'helper: pairing refused' })
    $last = if ($refused.Count -gt 0) { $refused[-1].Line } else { '(no line)' }
    Expect ($refused.Count -eq $refusedBefore + 1 -and $last.Contains('[registration_invalid]')) "the log says it (worker.ts:363): $last"
    Expect ($null -ne $status -and $status.link.kind -eq 'unpaired' -and $null -eq $status.pairing) 'still unpaired'
    if ($script:Current.Failures.Count -gt 0) {
      Note "the log's last lines:"
      foreach ($line in (Get-LogTail 20)) { Note "  $line" }
    }
    Headline "$WrongCode refused by $ApiUrl after $took s over HTTPS: $reason; the page's token, origin and Host rules hold"
  }

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '4' -Since $PrintSince {
    $h = Get-Helper
    if (-not (Test-Running $h)) { throw "expected $WholeText, found: $(Format-Helper $h)" }
    $laneShells = @(Get-SpoolerShells | Where-Object { $_.ParentPid -eq $h.Prints[0].Pid })
    $laneCommand = if ($laneShells.Count -ge 1) { $laneShells[0].CommandLine } else { [string]$S.SpoolerCommand }
    if ($laneShells.Count -eq 0) { Note "the print process has no PowerShell now: its command line is check 2's" }

    # a) Windows' printers, from a process of its own beside the running helper (main.ts:279-293, print/check.ts:53-61):
    #    its PowerShell starts and compiles the C#, EnumPrinters and GetDefaultPrinter answer (print/windows.ts:167-215)
    $list = Invoke-PrintCheck -Label 'list'
    $listed = @($list.Lines | Where-Object { $_.check -eq 'printers' })
    Expect ($list.Ended -and $list.ExitCode -eq 0) "$($list.Command) ended after $($list.Seconds) s with exit code $(if ($list.Ended) { $list.ExitCode } else { 'none: still running' }) (0: it listed them)"
    Expect ($list.Lines.Count -eq 1 -and $listed.Count -eq 1 -and $listed[0].ok -eq $true) "its one line on its standard output: $(Format-Said $list)"
    if ($list.Stderr.Trim() -ne '') { Note "its standard error: $($list.Stderr.Trim())" }
    $windows = @(Get-WindowsPrinters)
    Note "Windows' own list (Win32_Printer): $(Format-WindowsPrinters $windows)"
    if ($listed.Count -eq 1) {
      $differ = @(Compare-Printers $listed[0].printers $windows)
      Expect ($differ.Count -eq 0) "it lists the printers Windows lists, each with Windows' driver, port and default$(if ($differ.Count) { ': ' + ($differ -join '; ') })"
    }
    Test-CheckShells $list $laneCommand

    # b) a printer Windows does not have: OpenPrinter refuses it, and nothing is sent (print/windows.ts:217-237,
    #    :721-734; jobs/print.ts:431-450)
    $missing = Invoke-PrintCheck -Label 'missing-printer' -Printer $NoPrinter
    $refused = @($missing.Lines | Where-Object { $_.check -eq 'print' })
    Expect ($missing.Ended -and $missing.ExitCode -eq 1) "$($missing.Command) ended after $($missing.Seconds) s with exit code $(if ($missing.Ended) { $missing.ExitCode } else { 'none: still running' }) (1: not printed)"
    Expect ($refused.Count -eq 1 -and $refused[0].ok -eq $false -and $refused[0].sent -eq $false -and $refused[0].problem -eq 'printer_missing') "Windows has no such printer, and nothing was sent: $(Format-Said $missing)"
    Test-CheckShells $missing $laneCommand $NoPrinter

    # c) a printer this test adds, Windows' own text driver on a port that is a file: the print through the very
    #    code a ticket takes (print/check.ts:62-98): the printer's state (GetPrinter), the bytes as one RAW job
    #    (StartDocPrinter, WritePrinter, EndDocPrinter), a look every quarter second until it leaves Windows' queue
    #    (GetJob) (print/windows.ts:239-309; jobs/print.ts:411-494)
    $driver = Add-RawPrinter
    Note "added the printer '$RawPrinter': Windows' driver '$driver' on the port $RawPort"
    $printed = @()
    $raw = $null
    try {
      $since = [DateTime]::UtcNow
      $raw = Invoke-PrintCheck -Label 'print' -Printer $RawPrinter
      $listedRaw = @($raw.Lines | Where-Object { $_.check -eq 'printers' } | ForEach-Object { @($_.printers) } | Where-Object { [string]$_.name -ceq $RawPrinter })
      Expect ($listedRaw.Count -eq 1 -and $listedRaw[0].driver -eq $driver -and $listedRaw[0].port -eq $RawPort -and $listedRaw[0].state -eq 'ready' -and $listedRaw[0].jobs -eq 0) "it lists the printer just added: $(Format-Printers $listedRaw)"
      $printed = @($raw.Lines | Where-Object { $_.check -eq 'print' })
      Expect ($raw.Ended -and $raw.ExitCode -eq 0) "$($raw.Command) ended after $($raw.Seconds) s with exit code $(if ($raw.Ended) { $raw.ExitCode } else { 'none: still running' }) (0: printed)"
      Expect ($printed.Count -eq 1 -and $printed[0].ok -eq $true -and $printed[0].sent -eq $true -and $printed[0].outcome -eq 'printed' -and [long]$printed[0].spoolJobId -gt 0 -and $printed[0].bytes -eq 63) "Windows took the RAW print and it left the queue: $(Format-Said $raw)"
      if ($raw.Stderr.Trim() -ne '') { Note "its standard error: $($raw.Stderr.Trim())" }

      # the bytes that reached the port, exactly the check's
      $null = Wait-Until { if ((Test-Path -LiteralPath $RawPort) -and (Get-Item -LiteralPath $RawPort).Length -ge 63) { $true } } -Seconds 10
      [byte[]]$bytes = [byte[]]::new(0)
      if (Test-Path -LiteralPath $RawPort) { $bytes = [System.IO.File]::ReadAllBytes($RawPort) }
      if ($bytes.Length -gt 0) { [System.IO.File]::WriteAllBytes((Join-Path $Evidence 'print-check.prn'), $bytes) }
      $landed = Test-CheckBytes $bytes $since
      Expect $landed.Ok "the port's file holds exactly the check's bytes, as written RAW: $($landed.Text)"
      $queued = @(Get-PrintJob -PrinterName $RawPrinter -ErrorAction SilentlyContinue)
      Expect ($queued.Count -eq 0) "nothing is left in Windows' queue for '$RawPrinter': $($queued.Count) prints"
      Test-CheckShells $raw $laneCommand $RawPrinter

      # d) the running print process reads Windows' printers again every 15 s (print/worker.ts:491-497): it lists the
      #    new printer too, for the page
      $seen = Wait-Until {
        $x = Read-Status
        if ($null -ne $x -and $null -ne $x.print -and @($x.print.printers | Where-Object { [string]$_.name -ceq $RawPrinter }).Count -eq 1) { $true }
      } -Seconds 40 -EveryMs 1000
      $status = Get-Status
      $byLane = @(if ($null -ne $status -and $null -ne $status.print) { $status.print.printers | Where-Object { [string]$_.name -ceq $RawPrinter } })
      Expect ($seen -eq $true -and $byLane.Count -eq 1) "the running print process lists it too, within 40 s: $(Format-Printers $byLane)"
    } finally {
      Remove-RawPrinter
    }

    # beside the running helper, which goes on as it was
    $after = Get-Helper
    Save-Processes 'check4'
    Expect ((Test-Whole $after) -and $after.Supervisors[0].Pid -eq $h.Supervisors[0].Pid -and $after.Workers[0].Pid -eq $h.Workers[0].Pid -and $after.Prints[0].Pid -eq $h.Prints[0].Pid) "the running helper was not touched: $(Format-Helper $after)"
    $checkLines = Get-LogCount 'print: check' $PrintLogFile
    Note "print.log has the checks' $checkLines 'print: check' lines (print/check.ts:49-52)"
    $job = if ($printed.Count -eq 1) { "job $($printed[0].spoolJobId), out of the queue in $($printed[0].ms) ms" } else { 'no print' }
    Headline "--print-check listed $(if ($listed.Count -eq 1) { @($listed[0].printers).Count } else { 'no' }) printers as Windows does ($($list.Seconds) s with PowerShell's start), refused '$NoPrinter' with nothing sent, and printed 63 bytes RAW to '$RawPrinter' ($job), unchanged in the file; the print process lists it too"
  }

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '5' {
    $h = Get-Helper
    if (-not (Test-Running $h)) { throw "expected $WholeText, found: $(Format-Helper $h)" }
    $sup = $h.Supervisors[0]
    $old = $h.Workers[0]
    $pr = if ($HasPrint) { $h.Prints[0] } else { $null }
    $restartsBefore = Get-LogCount 'supervisor: the helper stopped by itself; starting it again'
    $startsBefore = Get-LogCount 'helper: started'

    # ended from outside, as Task Manager would: the supervisor starts it again after 0.5 to 1 s
    # (supervisor.ts:74-108, backoff.ts:20-21). The same TerminateProcess as Stop-Process -Force, through a
    # process object closed as soon as the worker has gone (Close-Process)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $victim = [System.Diagnostics.Process]::GetProcessById($old.Pid)
    try {
      $victim.Kill()
      $null = $victim.WaitForExit(5000)
    } finally {
      Close-Process $victim
    }
    $new = Wait-Until {
      $fresh = @((Get-Helper).Workers | Where-Object { $_.Pid -ne $old.Pid -or $_.Started -ne $old.Started })
      if ($fresh.Count -ge 1) { $fresh[0] }
    } -Seconds 5 -EveryMs 100
    $took = [math]::Round($clock.Elapsed.TotalSeconds, 1)
    Expect ($null -ne $new) "a new worker within 5 s of ending worker $($old.Pid): $(if ($null -ne $new) { "$($new.Pid), after $took s" } else { 'none' })"
    if ($null -eq $new) { return }
    Expect ($new.ParentPid -eq $sup.Pid) "it is the same supervisor's ($($sup.Pid)) child"

    # its page again, where runtime.json says (worker.ts:474-496: 47100, else any free port)
    $rt = Wait-Until { $x = Read-Runtime; if ($null -ne $x -and $x.workerPid -eq $new.Pid -and $x.url) { $x } } -Seconds 15
    Expect ($null -ne $rt) 'runtime.json names the new worker'
    if ($null -ne $rt) { $S.Url = [string]$rt.url }
    $answers = Wait-Until { Test-Page } -Seconds 15
    Expect ($answers -eq $true) "the page answers again at $($S.Url), $([math]::Round($clock.Elapsed.TotalSeconds, 1)) s after the end"
    if ($S.Url -ne $PageUrl) { Note "the page moved from $PageUrl to $($S.Url): its port was taken (the log says why)" }
    $logged = Wait-Until { if ((Get-LogCount 'helper: started') -ge $startsBefore + 1) { $true } } -Seconds 5

    $after = Get-Helper
    Save-Processes 'check5'
    Expect ($after.Supervisors.Count -eq 1 -and $after.Supervisors[0].Pid -eq $sup.Pid -and $after.Workers.Count -eq 1 -and $after.Prints.Count -eq $PrintCount -and $after.Others.Count -eq 0) "the same supervisor and one worker$(if ($HasPrint) { ' and one print process' }): $(Format-Helper $after)"
    if ($HasPrint) {
      # each child is kept on its own: the worker's end never restarts the print process (supervisor.ts:59-66)
      Expect ($after.Prints.Count -eq 1 -and $after.Prints[0].Pid -eq $pr.Pid -and $after.Prints[0].Started -eq $pr.Started) "the print process $($pr.Pid) was not touched"
    }
    $restarts = @(Get-LogEntries | Where-Object { $_.Message -eq 'supervisor: the helper stopped by itself; starting it again' })
    Expect ($restarts.Count -eq $restartsBefore + 1) "the supervisor logged the restart (supervisor.ts:102-106)"
    if ($HasPrint -and $restarts.Count -ge 1) {
      Expect ($null -ne $restarts[-1].Data -and $restarts[-1].Data.process -eq 'worker') "for the worker: $($restarts[-1].Line)"
    }
    Expect ($logged -eq $true) "the new worker logged its start (worker.ts:498-503)"
    $status = Get-Status
    Expect ($null -ne $status -and $status.link.kind -eq 'unpaired') 'it is still unpaired'
    $S.Supervisor = $sup
    $S.Worker = $new
    Headline "worker $($old.Pid) ended; worker $($new.Pid) after $took s under the same supervisor $($sup.Pid)$(if ($HasPrint) { ", print process $($pr.Pid) untouched" }); the page answers again"
  }

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '6' -Since $PrintSince {
    $h = Get-Helper
    if (-not (Test-Running $h)) { throw "expected $WholeText, found: $(Format-Helper $h)" }
    $sup = $h.Supervisors[0]
    $wk = $h.Workers[0]
    $old = $h.Prints[0]
    $oldShells = @(Get-SpoolerShells | Where-Object { $_.ParentPid -eq $old.Pid })
    $restartsBefore = Get-LogCount 'supervisor: the helper stopped by itself; starting it again'
    $startsBefore = Get-LogCount 'print: started' $PrintLogFile
    $shellsBefore = Get-LogCount 'print: Windows PowerShell started for the spooler' $PrintLogFile

    # ended from outside, as Task Manager's End task would: the supervisor keeps each child on its own and starts
    # this one again too, after 0.5 to 1 s (supervisor.ts:59-108, backoff.ts:20-21; main.ts:170-190)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $victim = [System.Diagnostics.Process]::GetProcessById($old.Pid)
    try {
      $victim.Kill()
      $null = $victim.WaitForExit(5000)
    } finally {
      Close-Process $victim
    }
    $new = Wait-Until {
      $fresh = @((Get-Helper).Prints | Where-Object { $_.Pid -ne $old.Pid -or $_.Started -ne $old.Started })
      if ($fresh.Count -ge 1) { $fresh[0] }
    } -Seconds 5 -EveryMs 100
    $took = [math]::Round($clock.Elapsed.TotalSeconds, 1)
    Expect ($null -ne $new) "a new print process within 5 s of ending print process $($old.Pid): $(if ($null -ne $new) { "$($new.Pid), after $took s" } else { 'none' })"
    if ($null -eq $new) { return }
    Expect ($new.ParentPid -eq $sup.Pid -and (Get-ArgumentsOf $new.CommandLine) -eq '--print-worker') "it is the same supervisor's ($($sup.Pid)) child, $(Get-ArgumentsOf $new.CommandLine)"
    $S.Print = $new

    # the ended one's PowerShell ends with it: its input closed (print/windows.ts:351-373); the new one starts its own
    $oldGone = Wait-Until { if (@(Get-SpoolerShells | Where-Object { $_.ParentPid -eq $old.Pid }).Count -eq 0) { $true } } -Seconds 10
    Expect ($oldGone -eq $true -and $oldShells.Count -eq 1) "the ended print process's PowerShell ($(Format-Shells $oldShells)) ended too: nothing kept it"
    $shell = Wait-Until {
      $x = @(Get-SpoolerShells)
      if ($x.Count -eq 1 -and $x[0].ParentPid -eq $new.Pid -and (Get-LogCount 'print: Windows PowerShell started for the spooler' $PrintLogFile) -ge $shellsBefore + 1) { $x[0] }
    } -Seconds 75 -EveryMs 500
    Expect ($null -ne $shell) "the new print process started its own PowerShell, and only it runs: $(Format-Shells (Get-SpoolerShells))"
    if ($null -ne $shell) { $S.SpoolerCommand = $shell.CommandLine }
    $logged = Wait-Until { if ((Get-LogCount 'print: started' $PrintLogFile) -ge $startsBefore + 1) { $true } } -Seconds 5
    Expect ($logged -eq $true) "the new print process logged its start (print/worker.ts:524-529)"
    $ps = Wait-Until { $x = Read-PrintStatus; if ($null -ne $x -and $x.pid -eq $new.Pid -and $null -ne $x.printers) { $x } } -Seconds 20
    Expect ($null -ne $ps) "print-status.json is the new print process's ($($new.Pid)), Windows' printers read"
    $status = Get-Status
    Expect ($null -ne $status -and $null -ne $status.print -and $status.print.running -eq $true -and $status.link.kind -eq 'unpaired') "the page says the print process runs (running: $(if ($null -ne $status -and $null -ne $status.print) { $status.print.running })); still unpaired"

    $restarts = @(Get-LogEntries | Where-Object { $_.Message -eq 'supervisor: the helper stopped by itself; starting it again' })
    $added = @($restarts | Select-Object -Skip $restartsBefore)
    Expect ($added.Count -eq 1 -and $null -ne $added[0].Data -and $added[0].Data.process -eq 'print') "the supervisor logged the restart, for the print process (supervisor.ts:102-106): $(if ($added.Count) { ($added | ForEach-Object { $_.Line }) -join ' / ' } else { 'no line' })"
    $after = Get-Helper
    Save-Processes 'check6'
    Expect ($after.Supervisors.Count -eq 1 -and $after.Supervisors[0].Pid -eq $sup.Pid -and $after.Workers.Count -eq 1 -and $after.Workers[0].Pid -eq $wk.Pid -and $after.Workers[0].Started -eq $wk.Started -and
      $after.Prints.Count -eq 1 -and $after.Prints[0].Pid -eq $new.Pid -and $after.Others.Count -eq 0) "the same supervisor and worker (untouched), and the new print process: $(Format-Helper $after)"
    Expect (Test-Page) "the page still answers at $($S.Url)"
    Headline "print process $($old.Pid) ended; print process $($new.Pid) after $took s under the same supervisor $($sup.Pid), with a PowerShell of its own; the old PowerShell ended; worker $($wk.Pid) untouched"
  }

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '7' {
    $h = Get-Helper
    if (-not (Test-Running $h)) { throw "expected $WholeText, found: $(Format-Helper $h)" }
    $sup = $h.Supervisors[0]
    $wk = $h.Workers[0]
    $pr = if ($HasPrint) { $h.Prints[0] } else { $null }
    $leftBefore = Get-LogCount 'supervisor: already running here'

    # The shortcut's own command, the program with --open (.nsi:93), twice in a row. Started from this
    # folder, not the shortcut's (the program folder): the browser --open starts would keep that one as
    # its working folder, and so stop check 10's uninstall from removing the program folder.
    $target = $Exe
    $arguments = '--open'
    if ($null -ne $S.Link -and $S.Link.TargetPath) { $target = $S.Link.TargetPath; $arguments = $S.Link.Arguments }
    # Each start's handle is closed once its exit code is read (Close-Process): alty-helper.exe stays
    # replaceable for check 8's reinstall.
    $starts = [System.Collections.Generic.List[object]]::new()
    try {
      foreach ($n in 1, 2) {
        if ($arguments) {
          $p = Start-Process -FilePath $target -ArgumentList $arguments -WorkingDirectory $WorkDir -PassThru
        } else {
          $p = Start-Process -FilePath $target -WorkingDirectory $WorkDir -PassThru
        }
        $starts.Add($p)
        $null = $p.Handle
      }
      # each finds the supervisor's pipe held (lock.ts:107-133), opens the page and leaves with 0 (main.ts:119-124)
      foreach ($p in $starts) {
        $startId = $p.Id
        $ended = $p.WaitForExit(20000)
        $startCode = if ($ended) { $p.ExitCode } else { $null }
        Close-Process $p
        Expect ($ended -and $startCode -eq 0) "start $startId (`"$target`" $arguments) left by itself with exit code $(if ($ended) { $startCode } else { 'none: still running after 20 s' })"
      }
    } finally {
      foreach ($p in $starts) { Close-Process $p }
    }
    $left = Wait-Until { $c = Get-LogCount 'supervisor: already running here'; if ($c -ge $leftBefore + 2) { $c } } -Seconds 10
    Expect ($left -eq $leftBefore + 2) "the log says 'supervisor: already running here' twice more (main.ts:122)"

    # and for 5 s after, still the same processes and nothing else
    $steady = Watch-Steady -Supervisor $sup -Worker $wk -Print $pr -Seconds 5
    Save-Processes 'check7'
    Expect $steady.Ok $steady.Text
    Expect (Test-Page) "the page still answers at $($S.Url)"
    Headline "two starts left at once with 0; $($steady.Text)"
  }

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '8' {
    $h = Get-Helper
    if (-not (Test-Running $h)) { throw "expected $WholeText, found: $(Format-Helper $h)" }
    $oldSup = $h.Supervisors[0]
    $oldWk = $h.Workers[0]
    $oldPr = if ($HasPrint) { $h.Prints[0] } else { $null }
    $oldShells = @(Get-SpoolerShells)
    $before = @(Get-LogEntries)
    $firstLine = if ($before.Count -gt 0) { $before[0].Line } else { '' }
    $printBefore = @(Get-LogEntries $PrintLogFile)
    $printFirstLine = if ($printBefore.Count -gt 0) { $printBefore[0].Line } else { '' }
    $shellsBefore = @($printBefore | Where-Object { $_.Message -eq 'print: Windows PowerShell started for the spooler' }).Count

    # the installer finds the program and asks it to stop (--quit) before it copies (.nsi:82-83, :109-119);
    # nothing of the test's may still hold an ended alty-helper.exe process then (Close-Process)
    Close-StrayHandles
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $setup = Start-Process -FilePath $Installer -ArgumentList '/S' -PassThru
    try {
      $null = $setup.Handle
      $ended = $setup.WaitForExit(180000)
      $setupCode = if ($ended) { $setup.ExitCode } else { $null }
    } finally {
      Close-Process $setup
    }
    $took = [math]::Round($clock.Elapsed.TotalSeconds, 1)
    Expect ($ended -and $setupCode -eq 0) "the installer ended after $took s with exit code $(if ($ended) { $setupCode } else { 'none: still running after 180 s' })"

    $gone = Wait-Until {
      $alive = @(Get-HelperProcesses | Where-Object {
          ($_.Pid -eq $oldSup.Pid -and $_.Started -eq $oldSup.Started) -or ($_.Pid -eq $oldWk.Pid -and $_.Started -eq $oldWk.Started) -or
          ($null -ne $oldPr -and $_.Pid -eq $oldPr.Pid -and $_.Started -eq $oldPr.Started) })
      if ($alive.Count -eq 0) { $true }
    } -Seconds 10
    Expect ($gone -eq $true) "the old supervisor $($oldSup.Pid) and worker $($oldWk.Pid)$(if ($null -ne $oldPr) { " and print process $($oldPr.Pid)" }) ended"
    if ($HasPrint) {
      $shellGone = Wait-Until {
        $now = @(Get-SpoolerShells)
        if (@($oldShells | Where-Object { $o = $_; @($now | Where-Object { $_.Pid -eq $o.Pid -and $_.Started -eq $o.Started }).Count -gt 0 }).Count -eq 0) { $true }
      } -Seconds 10
      Expect ($shellGone -eq $true) "and the print process's PowerShell ($(Format-Shells $oldShells))"
    }

    # silent, it starts the helper again at its end (.nsi:124-127)
    $back = Wait-Until {
      $x = Get-Helper
      $rt = Read-Runtime
      if ((Test-Whole $x) -and $x.Supervisors[0].Pid -ne $oldSup.Pid -and
        $x.Workers[0].ParentPid -eq $x.Supervisors[0].Pid -and @($x.Prints | Where-Object { $_.ParentPid -ne $x.Supervisors[0].Pid }).Count -eq 0 -and
        $null -ne $rt -and $rt.workerPid -eq $x.Workers[0].Pid -and $rt.url) {
        [pscustomobject]@{ Helper = $x; Runtime = $rt }
      }
    } -Seconds 20
    Save-Processes 'check8'
    Expect ($null -ne $back) "it is back: $(if ($null -ne $back) { Format-Helper $back.Helper } else { Format-Helper (Get-Helper) })"
    if ($null -ne $back) {
      $S.Url = [string]$back.Runtime.url
      $S.Supervisor = $back.Helper.Supervisors[0]
      $S.Worker = $back.Helper.Workers[0]
      $S.ReinstallSupervisorPid = $S.Supervisor.Pid
      if ($HasPrint) { $S.Print = $back.Helper.Prints[0] }
    }
    Expect ((Wait-Until { Test-Page } -Seconds 15) -eq $true) "the page answers at $($S.Url)"
    if ($HasPrint -and $null -ne $back) {
      # the new print process's PowerShell, compiled and ready (print/worker.ts:508-509; print/windows.ts:614)
      $newPr = $back.Helper.Prints[0]
      $shell = Wait-Until {
        $x = @(Get-SpoolerShells)
        if ($x.Count -eq 1 -and $x[0].ParentPid -eq $newPr.Pid -and (Get-LogCount 'print: Windows PowerShell started for the spooler' $PrintLogFile) -ge $shellsBefore + 1) { $x[0] }
      } -Seconds 75 -EveryMs 500
      Expect ($null -ne $shell) "the new print process $($newPr.Pid) started its PowerShell, the only one: $(Format-Shells (Get-SpoolerShells))"
    }

    # How it was stopped, read once the new supervisor has written its start: gracefully, by the page's quit
    # (main.ts:314-327, server.ts:141-149), so the worker's 'helper: stopped' with 0 (worker.ts:403, :514),
    # then its supervisor's line (supervisor.ts:87-91), then the new start; not the supervisor's pipe
    # (main.ts:328-330) nor taskkill (.nsi:112-116)
    $new = @(Get-LogEntries | Select-Object -Skip $before.Count)
    $stopped = Find-Index $new { param($e) $e.Message -eq 'helper: stopped' -and $null -ne $e.Data -and $e.Data.exitCode -eq 0 }
    $asked = Find-Index $new { param($e) $e.Message -eq 'supervisor: the helper was asked to stop' }
    $restarted = Find-Index $new { param($e) $e.Message -eq 'supervisor: started' }
    Expect ($stopped -ge 0 -and $asked -gt $stopped -and $restarted -gt $asked) "the installer's --quit stopped it before copying: 'helper: stopped' with 0, then 'supervisor: the helper was asked to stop', then a new 'supervisor: started' (new log lines $stopped, $asked, $restarted of $($new.Count))"
    if ($stopped -lt 0) {
      $byPipe = Find-Index $new { param($e) $e.Message -eq 'supervisor: asked to stop' }
      Note $(if ($byPipe -ge 0) { "it stopped through the supervisor's pipe instead: the page's quit did not end it" } else { 'neither quit is in the log: the installer ended the processes itself (taskkill)' })
    }
    if ($HasPrint) {
      # the print process stopped on the supervisor's word, the end of its input (main.ts:185-189; print/worker.ts:516-523,
      # :551), and --quit waited for its lock too (main.ts:296-306), before the copy and the new supervisor's start
      $newPrint = @(Get-LogEntries $PrintLogFile | Select-Object -Skip $printBefore.Count)
      $prStopped = Find-Index $newPrint { param($e) $e.Message -eq 'print: stopped' -and $null -ne $e.Data -and $e.Data.exitCode -eq 0 }
      $prStarted = Find-Index $newPrint { param($e) $e.Message -eq 'print: started' }
      $stopAt = if ($prStopped -ge 0) { $newPrint[$prStopped].Time } else { $null }
      $supAt = if ($restarted -ge 0) { $new[$restarted].Time } else { $null }
      Expect ($prStopped -ge 0 -and $prStarted -gt $prStopped -and $null -ne $stopAt -and $null -ne $supAt -and $stopAt -le $supAt) "the print process stopped on the supervisor's word: 'print: stopped' with 0 at $(if ($stopAt) { $stopAt.ToString('HH:mm:ss.fff') } else { '-' }), before the new 'supervisor: started' at $(if ($supAt) { $supAt.ToString('HH:mm:ss.fff') } else { '-' }), then a new 'print: started' (print.log's new lines $prStopped, $prStarted of $($newPrint.Count))"
    }

    # its data stays: an install never touches %LOCALAPPDATA%\Alty Helper (.nsi:78-104; only the uninstall does, :141)
    $entries = @(Get-LogEntries)
    Expect (Test-Path -LiteralPath $DataDir) "the data folder is kept: $DataDir"
    Expect ($entries.Count -gt $before.Count -and $firstLine -ne '' -and $entries[0].Line -eq $firstLine) "the log goes on from the first install's first line ($($before.Count) lines before, $($entries.Count) now)"
    if ($HasPrint) {
      $printEntries = @(Get-LogEntries $PrintLogFile)
      Expect ($printEntries.Count -gt $printBefore.Count -and $printFirstLine -ne '' -and $printEntries[0].Line -eq $printFirstLine) "print.log goes on too ($($printBefore.Count) lines before, $($printEntries.Count) now)"
    }
    $status = Get-Status
    Expect ($null -ne $status -and $status.link.kind -eq 'unpaired' -and $null -eq $status.pairing -and $status.version -eq $ExpectedVersion) "still unpaired, version $(if ($null -ne $status) { $status.version })"
    Expect (-not (Test-Path -LiteralPath (Join-Path $DataDir 'config.json'))) 'no config.json: nothing was ever paired or saved (worker.ts:148-151)'
    Expect ((Get-RegValue $RunKey $AppId) -eq "`"$Exe`"" -and (Test-Path -LiteralPath $Shortcut)) 'the Run key and the shortcut are still there'
    Headline "reinstalled in $took s: stopped by its own --quit$(if ($HasPrint) { ', the print process on the supervisor''s word' }), back as supervisor $(if ($S.Supervisor) { $S.Supervisor.Pid }), data kept, unpaired"
  }

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '9' {
    Expect (Test-Path -LiteralPath $LogFile) "the log is there: $LogFile"
    $entries = @(Get-LogEntries)
    Note "helper.log: $($entries.Count) lines"

    # the supervisor's start line, with where it runs (main.ts:134, platform.ts:18-27): install and reinstall
    $supStarts = @($entries | Where-Object { $_.Message -eq 'supervisor: started' })
    Expect ($supStarts.Count -eq 2) "two 'supervisor: started' lines, the install's and the reinstall's: $($supStarts.Count)"
    foreach ($e in $supStarts) {
      $d = $e.Data
      $node = if ($null -ne $d) { [string]$d.node } else { '' }
      # built with Node 22.19 or later, which reads Windows' certificate store (packaging.ts:30-36)
      $nodeOk = $node -match '^v22\.(\d+)\.' -and [int]$Matches[1] -ge 19
      $ok = ($null -ne $d -and $d.version -eq $ExpectedVersion -and $null -ne $d.pid -and $d.singleExecutable -eq $true -and
        $d.execPath -eq $Exe -and $nodeOk -and $d.arch -eq 'x64' -and
        -not [string]::IsNullOrWhiteSpace([string]$d.osVersion) -and -not [string]::IsNullOrWhiteSpace([string]$d.osRelease))
      Expect $ok "start line with the start facts: $($e.Line)"
    }
    if ($supStarts.Count -ge 1 -and $null -ne $S.FirstSupervisorPid) {
      Expect ($supStarts[0].Data.pid -eq $S.FirstSupervisorPid) "the first names the first supervisor, $($S.FirstSupervisorPid)"
    }
    if ($supStarts.Count -ge 2 -and $null -ne $S.ReinstallSupervisorPid) {
      Expect ($supStarts[1].Data.pid -eq $S.ReinstallSupervisorPid) "the second names the reinstall's, $($S.ReinstallSupervisorPid)"
    }

    # the worker's start lines (worker.ts:498-503): the install, check 5's restart, the reinstall
    $wkStarts = @($entries | Where-Object { $_.Message -eq 'helper: started' })
    Expect ($wkStarts.Count -eq 3) "three 'helper: started' lines (install, restart, reinstall): $($wkStarts.Count)"
    foreach ($e in $wkStarts) {
      $d = $e.Data
      Expect ($null -ne $d -and $d.version -eq $ExpectedVersion -and $d.port -eq $Port -and $d.paired -eq $false -and $d.apiUrl -eq $ApiUrl) "worker start: $($e.Line)"
    }

    # the print process's own log (log.ts:73-76; print/worker.ts:110-115)
    $prints = @()
    if ($HasPrint) {
      Expect (Test-Path -LiteralPath $PrintLogFile) "the print process's log is there: $PrintLogFile"
      $prints = @(Get-LogEntries $PrintLogFile)
      Note "print.log: $($prints.Count) lines"
      # its start lines (print/worker.ts:524-529): the install, check 6's restart, the reinstall
      $prStarts = @($prints | Where-Object { $_.Message -eq 'print: started' })
      Expect ($prStarts.Count -eq 3) "three 'print: started' lines (install, restart, reinstall): $($prStarts.Count)"
      foreach ($e in $prStarts) {
        $d = $e.Data
        Expect ($null -ne $d -and $d.version -eq $ExpectedVersion -and $d.installed -eq $ExpectedVersion -and $d.paired -eq $false -and $d.apiUrl -eq $ApiUrl) "print start: $($e.Line)"
      }
      # a PowerShell compiled and ready for each print process and each of check 4's three runs (print/windows.ts:614)
      $shellStarts = @($prints | Where-Object { $_.Message -eq 'print: Windows PowerShell started for the spooler' })
      $shellMs = @($shellStarts | ForEach-Object { if ($null -ne $_.Data) { [string]$_.Data.ms } else { '?' } })
      Expect ($shellStarts.Count -eq 6) "six 'print: Windows PowerShell started for the spooler' lines, three print processes' and three checks': $($shellStarts.Count), after $($shellMs -join ', ') ms"
      # one stop, the reinstall's, on the supervisor's word (print/worker.ts:551); the ended one wrote none
      $prStops = @($prints | Where-Object { $_.Message -eq 'print: stopped' })
      Expect ($prStops.Count -eq 1 -and $null -ne $prStops[0].Data -and $prStops[0].Data.exitCode -eq 0) "one 'print: stopped' with 0, the reinstall's: $(if ($prStops.Count) { ($prStops | ForEach-Object { $_.Line }) -join ' / ' } else { 'none' })"
      # check 4's own lines (print/check.ts:49-52; jobs/print.ts:216-224, :452-459)
      $checkLines = @($prints | Where-Object { $_.Message -eq 'print: check' })
      Expect ($checkLines.Count -eq 5) "five 'print: check' lines from check 4's three runs (one, two, two): $($checkLines.Count)"
      $ready = @($prints | Where-Object { $_.Message -eq 'print: ready to send' })
      $done = @($prints | Where-Object { $_.Message -eq 'print: printed' })
      Expect ($ready.Count -eq 1 -and $done.Count -eq 1) "the print to the file, logged once ready and once printed: $(($ready + $done | ForEach-Object { $_.Line }) -join ' / ')"
    } else {
      Expect (-not (Test-Path -LiteralPath $PrintLogFile)) "no print.log: $ExpectedVersion has no print process"
    }

    # no code and no secret in either (log.ts:15-29, :57-62; worker.ts:363 logs only the error)
    $text = ''
    foreach ($file in @(Get-HelperLogFiles)) {
      $text += [string](Read-SharedText $file.FullName)
    }
    $codeFound = ($text.IndexOf($WrongCode, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
      $text.IndexOf($WrongCode.Replace('-', ''), [StringComparison]::OrdinalIgnoreCase) -ge 0)
    Expect (-not $codeFound) "the code $WrongCode is not in the logs"
    $leaked = @($S.Secrets | Where-Object { $text.Contains($_) })
    Expect ($S.Secrets.Count -gt 0 -and $leaked.Count -eq 0) "none of the $($S.Secrets.Count) page tokens and quit secrets this test saw is in the logs"

    # nothing unexpected: the warnings and errors are exactly those this test caused
    $expected = [ordered]@{
      'helper.log|WARN|helper: pairing refused'                                     = 1   # check 3 (worker.ts:363)
      'helper.log|ERROR|supervisor: the helper stopped by itself; starting it again' = $(if ($HasPrint) { 2 } else { 1 })   # checks 5 and 6 (supervisor.ts:102-106)
    }
    if ($HasPrint) {
      $expected['print.log|WARN|print: the printer would only keep it in its queue; nothing sent'] = 1   # check 4's missing printer (jobs/print.ts:441-450)
    }
    $all = @($entries | ForEach-Object { [pscustomobject]@{ File = 'helper.log'; Entry = $_ } }) + @($prints | ForEach-Object { [pscustomobject]@{ File = 'print.log'; Entry = $_ } })
    $seen = @{}
    foreach ($x in @($all | Where-Object { $_.Entry.Level -ne 'INFO' })) {
      $key = "$($x.File)|$($x.Entry.Level)|$($x.Entry.Message)"
      $seen[$key] = 1 + [int]$seen[$key]
    }
    foreach ($key in $expected.Keys) {
      Expect ([int]$seen[$key] -eq $expected[$key]) "$($key.Replace('|', ' ')): $([int]$seen[$key]) (expected $($expected[$key]))"
    }
    $unexpected = @($all | Where-Object { $_.Entry.Level -ne 'INFO' -and -not $expected.Contains("$($_.File)|$($_.Entry.Level)|$($_.Entry.Message)") })
    Expect ($unexpected.Count -eq 0) "no other warning or error$(if ($unexpected.Count) { ': ' + (($unexpected | ForEach-Object { "$($_.File): $($_.Entry.Line)" }) -join ' / ') })"
    if ($HasPrint) {
      $restartLines = @($entries | Where-Object { $_.Message -eq 'supervisor: the helper stopped by itself; starting it again' })
      $byProcess = @($restartLines | ForEach-Object { if ($null -ne $_.Data) { [string]$_.Data.process } else { '?' } })
      Expect (@($byProcess | Where-Object { $_ -eq 'worker' }).Count -eq 1 -and @($byProcess | Where-Object { $_ -eq 'print' }).Count -eq 1) "the two restarts are the worker's and the print process's: $($byProcess -join ', ')"
    }
    $fatal = @($all | Where-Object { $_.Entry.Message -eq 'helper: stopped by an error' })
    Expect ($fatal.Count -eq 0) "no 'helper: stopped by an error' in either log (log.ts:163-179, main.ts:386-399)"
    $tls = @($all | Where-Object { $_.Entry.Message -like 'tls:*' })
    Expect ($tls.Count -eq 0) "Windows' certificate store was read: no 'tls:' warning (api.ts:32-44)"

    # into the evidence, before the uninstall takes the data folder
    $copied = @(Save-Logs)
    Expect ($copied.Count -ge $(if ($HasPrint) { 2 } else { 1 })) "copied to the evidence: $($copied -join ', ')"
    Headline "$($entries.Count) + $($prints.Count) lines; start facts $(if ($supStarts.Count) { "node $($supStarts[0].Data.node), $($supStarts[0].Data.osVersion) $($supStarts[0].Data.osRelease)" }); no code, no secret; only the warnings and errors the test caused"
  }

  # everything the uninstall will take, kept first
  Save-Evidence 'before-uninstall'

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '10' {
    # what Settings > Apps runs for a quiet uninstall (.nsi:88, :101)
    $quiet = Get-RegValue $UninstallKey 'QuietUninstallString'
    Expect ($quiet -eq "`"$Uninstaller`" /S") "the quiet uninstall command: $quiet"
    if (-not (Test-Path -LiteralPath $Uninstaller -PathType Leaf)) { throw "no uninstaller at $Uninstaller" }
    # NSIS's uninstaller copies itself to %TEMP%, runs the copy and returns at once: its end is awaited by
    # what it leaves (it stops the helper with --quit, then removes all, .nsi:129-142)
    Close-StrayHandles
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $un = Start-Process -FilePath $Uninstaller -ArgumentList '/S' -PassThru
    try {
      $null = $un.Handle
      $firstEnded = $un.WaitForExit(60000)
      $firstCode = if ($firstEnded) { $un.ExitCode } else { $null }
    } finally {
      # closed before the copy deletes uninstall.exe (.nsi:138): a handle held to this ended process would
      # keep that file in use, NSIS's Delete tries only once, and RMDir would then leave the program folder
      Close-Process $un
    }
    Note "the uninstaller's first process ended: $firstEnded, exit code $(if ($firstEnded) { $firstCode } else { 'none' })"
    # While the copy works, only the two folders are watched: listing processes (WMI, Get-Leftovers) opens a
    # handle to each for a moment, and one held to an ended alty-helper.exe just as the copy deletes that
    # file could keep it in use. Once both folders are gone (the data folder goes last, .nsi:141), the rest
    # is looked at, the copy's own end included.
    $null = Wait-Until { if (-not (Test-Path -LiteralPath $ProgramDir) -and -not (Test-Path -LiteralPath $DataDir)) { $true } } -Seconds 90 -EveryMs 250
    $null = Wait-Until { if (@(Get-Leftovers).Count -eq 0) { $true } } -Seconds 30 -EveryMs 500
    $took = [math]::Round($clock.Elapsed.TotalSeconds, 1)
    $left = @(Get-Leftovers)
    Expect ($left.Count -eq 0) "after $took s nothing is left$(if ($left.Count) { ': ' + ($left -join '; ') } else { ': no process, no PowerShell of its own, no program folder, no data folder, no Run key, no Apps entry, no shortcut' })"
    $copies = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter '~nsu*.tmp' -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    Note "NSIS's own uninstaller copy in %TEMP%: $(if ($copies.Count) { $copies -join ', ' } else { 'none' })"
    Headline "uninstalled in $took s; $(if ($left.Count) { 'left: ' + ($left -join '; ') } else { 'nothing left' })"
  }
  Save-Json 'leftovers-after-uninstall.json' @(Get-Leftovers)
  Save-Processes 'after-uninstall'
} finally {
  if (-not $S.EvidenceSaved) { Save-Evidence 'at-exit' }
  Write-Host ''
  Write-Host "    all checks took $([math]::Round($total.Elapsed.TotalSeconds, 1)) s"
  Write-Report
}

exit $(if ($script:Verdict -eq 'PASS') { 0 } else { 1 })
