#Requires -Version 7.2
<#
.SYNOPSIS
  The Alty helper's Windows smoke test, for a fresh computer that is thrown away afterwards (a GitHub runner).

.DESCRIPTION
  Installs the given installer silently, then checks in order:
    1. the silent install: per user, its manifest asking for no administrator rights, nothing for the whole
       computer; the program, the Run key, the Start menu shortcut (this runner's user is an administrator,
       so a standard user's install is not tried);
    2. the helper starts: one supervisor, one worker, its page on 127.0.0.1:47100, unpaired;
    3. HTTPS to Alty's real server: the page's pairing with a deliberately wrong code reaches the server,
       which refuses it (nothing is paired and nothing changes there);
    4. the worker, ended from outside, is started again by its supervisor;
    5. two more starts, as from the Start menu shortcut, leave one supervisor and one worker;
    6. a reinstall over the running helper stops it first, brings it back, keeps its data, still unpaired;
    7. its log: the start lines, no code and no secret, no warning or error the test did not cause;
    8. the silent uninstall leaves nothing behind.
  Each check prints PASS or FAIL with what it saw. After a FAIL the script goes on and collects the evidence,
  and it exits 1 if any check failed. The evidence (the helper's logs, its /api/status answers, the process
  lists, the report) is written to -Evidence before the uninstall removes the helper's data folder. The
  page's token and the helper's quit secrets are never printed, and are masked in everything saved.

  References such as main.ts:112 point into apps/helper of the Alty repository at the release's tag.
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
# What the installer and the helper say (installer/alty-helper.nsi and src/ at the release's tag)
# ---------------------------------------------------------------------------------------------------------
$AppId        = 'AltyHelper'                                                              # .nsi:30
$ProgramDir   = Join-Path $env:LOCALAPPDATA 'Programs\Alty Helper'                        # .nsi:39
$Exe          = Join-Path $ProgramDir 'alty-helper.exe'                                   # .nsi:31
$Uninstaller  = Join-Path $ProgramDir 'uninstall.exe'                                     # .nsi:88
$DataDir      = Join-Path $env:LOCALAPPDATA 'Alty Helper'                                 # .nsi:35, paths.ts:36
$LogsDir      = Join-Path $DataDir 'logs'                                                 # paths.ts:45
$LogFile      = Join-Path $LogsDir 'helper.log'                                           # log.ts:83
$RuntimeFile  = Join-Path $DataDir 'runtime.json'                                         # paths.ts:44
$Shortcut     = Join-Path ([Environment]::GetFolderPath('Programs')) 'Alty Helper.lnk'    # .nsi:32, :80
$RunKey       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'                     # .nsi:33, :91
$UninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppId"        # .nsi:34, :95-103
$AppKey       = "HKCU:\Software\$AppId"                                                   # .nsi:40, :89
$Port         = 47100                                                                     # server.ts:10
$PageUrl      = "http://127.0.0.1:$Port/"                                                 # server.ts:186, :194
$ApiUrl       = 'https://api.alty.am'                                                     # store.ts:6
# a code the server can never issue: its codes leave out O and 0 (api: lib/crypto.ts:120-121), so no device
# has this one's hash and the server answers 404 registration_invalid (api: device/service.ts:381-385).
# 9 characters, as the page and the server take a code (status/server.ts:146; shared: api/helper.ts:62-64)
$WrongCode    = 'OOOO-0000'
# the page's title in Armenian, 'Alty' and the word for helper (i18n/hy.ts:8), kept ASCII in this file
$HyTitle      = 'Alty ' + (-join ([char[]](0x0585, 0x0563, 0x0576, 0x0561, 0x056F, 0x0561, 0x0576)))

$CheckNames = [ordered]@{
  '1' = 'Silent install: per user, asks for no administrator rights'
  '2' = 'The helper starts: one supervisor, one worker, the page on 127.0.0.1:47100, unpaired'
  '3' = 'HTTPS to the real server: the page pairs with a wrong code, the server refuses it'
  '4' = 'The worker comes back after it is ended'
  '5' = 'One instance only: two more starts, as from the Start menu shortcut'
  '6' = 'Reinstall over the running helper'
  '7' = 'The log: start lines, no code, no secret, nothing unexpected'
  '8' = 'Silent uninstall: nothing left behind'
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

function Invoke-Check([string]$Id, [scriptblock]$Body) {
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

# The helper's processes and their part: the worker has --worker in its command line (main.ts:41, :120-122),
# --quit is the installer's short-lived ask (main.ts:39), any other alty-helper.exe is a supervisor (main.ts:43).
function Get-HelperProcesses {
  foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'alty-helper.exe'")) {
    $cmd = [string]$p.CommandLine
    $role = if ($cmd -match '(^|\s)--worker(\s|$)') { 'worker' } elseif ($cmd -match '(^|\s)--quit(\s|$)') { 'quit' } else { 'supervisor' }
    [pscustomobject]@{
      Pid         = [int]$p.ProcessId
      ParentPid   = [int]$p.ParentProcessId
      Role        = $role
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
    Others      = @($all | Where-Object { $_.Role -eq 'quit' })
  }
}

function Format-Helper($Helper) {
  if ($Helper.All.Count -eq 0) { return 'no alty-helper process' }
  return (($Helper.All | ForEach-Object { "$($_.Role) $($_.Pid) (parent $($_.ParentPid))" }) -join ', ')
}

function Save-Processes([string]$Label) {
  Save-Json "processes-$Label.json" @(Get-HelperProcesses)
}

# what follows the program in a command line: '' for the supervisor the Run key starts, '--worker' ...
function Get-ArgumentsOf([string]$CommandLine) {
  return ($CommandLine -replace '^\s*("[^"]*"|\S+)\s*', '').Trim()
}

# Samples the processes for a while: the same one supervisor and one worker throughout, and nothing else.
function Watch-Steady($Supervisor, $Worker, [double]$Seconds) {
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $looks = 0
  while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
    $h = Get-Helper
    $looks++
    $same = ($h.All.Count -eq 2 -and $h.Supervisors.Count -eq 1 -and $h.Workers.Count -eq 1 -and
      $h.Supervisors[0].Pid -eq $Supervisor.Pid -and $h.Workers[0].Pid -eq $Worker.Pid)
    if (-not $same) {
      return [pscustomobject]@{ Ok = $false; Text = "after $([math]::Round($watch.Elapsed.TotalSeconds, 1)) s: $(Format-Helper $h) (expected only supervisor $($Supervisor.Pid) and worker $($Worker.Pid))" }
    }
    Start-Sleep -Milliseconds 250
  }
  return [pscustomobject]@{ Ok = $true; Text = "for $Seconds s ($looks looks) only supervisor $($Supervisor.Pid) and worker $($Worker.Pid) run" }
}

# A file the helper may be writing, read as its own writes allow (an append, a rename over it): this read
# never makes it drop a log line (log.ts:118-124) or wait on runtime.json (files.ts:29-48).
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
    # as bytes, so the Content-Type goes exactly as the page's script sends it (page.ts:209)
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

# GET /api/status (server.ts:111-114; its shape: status/types.ts:14-33), each answer kept as evidence.
function Get-Status([string]$Base = $S.Url) {
  $response = Invoke-Page -Path 'api/status' -Base $Base
  if ($null -eq $response -or $response.StatusCode -ne 200) { return $null }
  $text = Get-Body $response
  $S.StatusSeq++
  Save-Text ('status-{0:00}-check{1}.json' -f $S.StatusSeq, $script:Current.Id) $text
  try { return ($text | ConvertFrom-Json) } catch { return $null }
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

# helper.log's lines, parsed: "<ISO time> <LEVEL> <message> <JSON facts>" (log.ts:51-58).
function Get-LogEntries {
  $text = Read-SharedText $LogFile
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
      [pscustomobject]@{ At = $at; Level = $level; Message = $message; Data = $data; Line = $line }
    } else {
      [pscustomobject]@{ At = ''; Level = '?'; Message = $line; Data = $null; Line = $line }
    }
  }
}

function Get-LogCount([string]$Message) {
  return @(Get-LogEntries | Where-Object { $_.Message -eq $Message }).Count
}

function Get-LogTail([int]$Count = 20) {
  return @(Get-LogEntries | Select-Object -Last $Count | ForEach-Object { $_.Line })
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

# the helper's logs into the evidence, read as the helper's writes allow; the names copied
function Save-Logs {
  foreach ($file in @(Get-ChildItem -LiteralPath $LogsDir -File -Filter 'helper.log*' -ErrorAction SilentlyContinue)) {
    Save-Text (Join-Path 'logs' $file.Name) (Read-SharedText $file.FullName)
    $file.Name
  }
}

# Everything the uninstall will take, kept first: logs, runtime.json (secrets masked), processes, keys, folders.
function Save-Evidence([string]$Label) {
  try {
    $null = @(Save-Logs)
    Save-Json "runtime-$Label.json" (Read-Runtime)
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
  $script:Verdict = if ($passed -eq $rows.Count) { 'PASS' } else { 'FAIL' }

  $table = [System.Collections.Generic.List[string]]::new()
  $table.Add("### $($script:Verdict): Alty helper $ExpectedVersion on $($Environment.os)")
  $table.Add('')
  $table.Add("$passed of $($rows.Count) checks passed. The run's artifact keeps the evidence: the helper's logs, its /api/status answers, the process lists and report.md.")
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
  Write-Host "=== $($script:Verdict): $passed of $($rows.Count) checks passed"
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
    # the page on 47100 unless ALTY_HELPER_PORT says otherwise (worker.ts:243-256), within 20 s of the install
    $window = [Math]::Max(1, ($S.InstalledAt.AddSeconds(20) - [DateTime]::UtcNow).TotalSeconds)
    $up = Wait-Until { Test-Page -Base $PageUrl } -Seconds $window
    $after = [math]::Round(([DateTime]::UtcNow - $S.InstalledAt).TotalSeconds, 1)
    Expect ($up -eq $true) "the page answered at $PageUrl $after s after the install"

    # its start is complete once runtime.json names the worker (worker.ts:257-265) and the log has its line (:267)
    $ready = Wait-Until {
      $h = Get-Helper
      $rt = Read-Runtime
      if ($h.Supervisors.Count -eq 1 -and $h.Workers.Count -eq 1 -and $null -ne $rt -and $rt.workerPid -eq $h.Workers[0].Pid -and
        (Get-LogCount 'helper: started') -ge 1) { $true }
    } -Seconds 10
    if (-not $ready) { Note 'its start did not complete within 10 s more' }

    # exactly one supervisor and one worker, the worker its child (main.ts:84-142)
    $h = Get-Helper
    Save-Processes 'check2'
    Expect ($h.Supervisors.Count -eq 1 -and $h.Workers.Count -eq 1 -and $h.Others.Count -eq 0) "exactly one supervisor and one worker: $(Format-Helper $h)"
    if ($h.Supervisors.Count -eq 1 -and $h.Workers.Count -eq 1) {
      $sup = $h.Supervisors[0]
      $wk = $h.Workers[0]
      $S.Supervisor = $sup
      $S.Worker = $wk
      $S.FirstSupervisorPid = $sup.Pid
      Expect ($wk.ParentPid -eq $sup.Pid) "the worker $($wk.Pid) is the supervisor's ($($sup.Pid)) child (main.ts:119-126)"
      Expect ($sup.Path -eq $Exe -and $wk.Path -eq $Exe) "both run $Exe"
      Expect ((Get-ArgumentsOf $sup.CommandLine) -eq '') "the supervisor has no arguments, as the Run key starts it: $($sup.CommandLine)"
      Expect ((Get-ArgumentsOf $wk.CommandLine) -eq '--worker') "the worker's arguments: $(Get-ArgumentsOf $wk.CommandLine)"
    }

    # runtime.json: the instance, for a second start's --open and the installer's --quit (main.ts:103-111)
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

    # what the page says (worker.ts:211-225)
    $status = Get-Status -Base $PageUrl
    Expect ($null -ne $status) 'GET /api/status answers 200'
    if ($null -ne $status) {
      Expect ($status.app -eq 'alty-helper' -and $status.version -eq $ExpectedVersion) "it is $($status.app) $($status.version)"
      Expect ($status.link.kind -eq 'unpaired' -and $null -eq $status.pairing) "it says unpaired (link $($status.link.kind), pairing $(if ($null -eq $status.pairing) { 'none' } else { 'set' }); worker.ts:103-104)"
      Expect ($status.apiUrl -eq $ApiUrl) "its server is $($status.apiUrl) (store.ts:6, :63)"
      Expect ($status.update.status -eq 'current') "its update status is '$($status.update.status)': a release key is compiled in ('off' would mean none; update.ts:58)"
      Expect ($status.language -eq 'hy' -and $status.logs -eq $LogsDir) "its page speaks $($status.language) (worker.ts:214) and names its logs $($status.logs)"
      Expect ($null -eq $status.lastError.link -and $null -eq $status.lastError.pairing) 'no error since its start'
    }

    # the page itself: in Armenian, with its CSP, carrying the token a change needs (server.ts:97-110)
    $page = Invoke-Page -Base $PageUrl
    $html = Get-Body $page
    if ($html -match 'const CSRF = "([A-Za-z0-9_-]+)";') { Add-Secret $Matches[1] }
    Expect ($null -ne $page -and $page.StatusCode -eq 200) "GET / answers $(if ($null -ne $page) { $page.StatusCode } else { 'nothing' })"
    $csp = Get-Header $page 'Content-Security-Policy'
    Expect ($csp.StartsWith("default-src 'none'")) "its Content-Security-Policy: $csp"
    Expect ($html.Contains("<title>$HyTitle</title>")) "it is in Armenian: <title>$HyTitle</title> (page.ts:130, i18n/hy.ts:8)"
    Save-Text 'page.html' $html
    Headline "page at $PageUrl after $after s; supervisor $(if ($S.Supervisor) { $S.Supervisor.Pid }) and worker $(if ($S.Worker) { $S.Worker.Pid }); unpaired; server $ApiUrl; release key compiled in"
  }

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '3' {
    $page = Invoke-Page
    $html = Get-Body $page
    if (-not ($html -match 'const CSRF = "([A-Za-z0-9_-]+)";')) { throw "the page carries no token (page.ts:191): $(Format-Answer $page)" }
    $csrf = $Matches[1]
    Add-Secret $csrf
    $origin = $S.Url.TrimEnd('/')   # the page's own origin, which a browser sends with its POST
    $refusedBefore = Get-LogCount 'helper: pairing refused'

    # the page's guards (server.ts:92-95, :128-135), each tried with an empty body, which could not reach the
    # server even if a guard let it through (server.ts:145-148)
    $noToken = Invoke-Page -Path 'api/pair' -Method 'POST' -Headers @{ Origin = $origin } -Body '{}'
    Expect ($null -ne $noToken -and $noToken.StatusCode -eq 403) "a change without the page's token is refused: $(Format-Answer $noToken)"
    $otherSite = Invoke-Page -Path 'api/pair' -Method 'POST' -Headers @{ 'x-helper-csrf' = $csrf; Origin = 'https://example.com' } -Body '{}'
    Expect ($null -ne $otherSite -and $otherSite.StatusCode -eq 403) "a change from another site's origin is refused: $(Format-Answer $otherSite)"
    $otherHost = Send-RawRequest "example.com:$(([Uri]$S.Url).Port)"
    Expect ($otherHost -match '^HTTP/1\.1 421 ') "a request under another Host (DNS rebinding) is refused: $otherHost"

    # the pairing as the page's script sends it (page.ts:207-209, :275-281): POST /api/pair, {"code": ...},
    # its token and its origin. The helper claims it at the server (worker.ts:181-207, api.ts:189-191)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $answer = Invoke-Page -Path 'api/pair' -Method 'POST' -Headers @{ 'x-helper-csrf' = $csrf; Origin = $origin } -Body (ConvertTo-Json -InputObject @{ code = $WrongCode } -Compress) -TimeoutSec 60
    $took = [math]::Round($clock.Elapsed.TotalSeconds, 1)
    $json = $null
    try { $json = (Get-Body $answer) | ConvertFrom-Json } catch { $json = $null }
    # the server's 404 registration_invalid comes back as the page's 400 {ok:false, error:'registration_invalid'}
    # (api.ts:163-171, worker.ts:202-206, server.ts:150-151); a network or TLS failure would say 'network'
    Expect ($null -ne $answer -and $answer.StatusCode -eq 400 -and $null -ne $json -and $json.ok -eq $false -and $json.error -eq 'registration_invalid') "the page answered $(Format-Answer $answer) after $took s"

    # why, as the page's details say it (worker.ts:204; log.ts:24-42): the server's own words and code
    $status = Get-Status
    $note = $null
    if ($null -ne $status -and $null -ne $status.lastError) { $note = $status.lastError.pairing }
    $reason = if ($null -ne $note) { [string]$note.text } else { '(none)' }
    Expect ($reason.StartsWith('HelperApiError: ') -and $reason.EndsWith('[registration_invalid]')) "the reason is the server's answer, not a network or TLS error: $reason"
    $refused = @(Get-LogEntries | Where-Object { $_.Message -eq 'helper: pairing refused' })
    $last = if ($refused.Count -gt 0) { $refused[-1].Line } else { '(no line)' }
    Expect ($refused.Count -eq $refusedBefore + 1 -and $last.Contains('[registration_invalid]')) "the log says it (worker.ts:203): $last"
    Expect ($null -ne $status -and $status.link.kind -eq 'unpaired' -and $null -eq $status.pairing) 'still unpaired'
    if ($script:Current.Failures.Count -gt 0) {
      Note "the log's last lines:"
      foreach ($line in (Get-LogTail 20)) { Note "  $line" }
    }
    Headline "$WrongCode refused by $ApiUrl after $took s over HTTPS: $reason; the page's token, origin and Host rules hold"
  }

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '4' {
    $h = Get-Helper
    if ($h.Supervisors.Count -ne 1 -or $h.Workers.Count -ne 1) { throw "expected one supervisor and one worker, found: $(Format-Helper $h)" }
    $sup = $h.Supervisors[0]
    $old = $h.Workers[0]
    $restartsBefore = Get-LogCount 'supervisor: the helper stopped by itself; starting it again'
    $startsBefore = Get-LogCount 'helper: started'

    # ended from outside, as Task Manager would: the supervisor starts it again after 0.5 to 1 s
    # (supervisor.ts:61-80, backoff.ts:20-21). The same TerminateProcess as Stop-Process -Force, through a
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

    # its page again, where runtime.json says (worker.ts:246-265: 47100, else any free port)
    $rt = Wait-Until { $x = Read-Runtime; if ($null -ne $x -and $x.workerPid -eq $new.Pid -and $x.url) { $x } } -Seconds 15
    Expect ($null -ne $rt) 'runtime.json names the new worker'
    if ($null -ne $rt) { $S.Url = [string]$rt.url }
    $answers = Wait-Until { Test-Page } -Seconds 15
    Expect ($answers -eq $true) "the page answers again at $($S.Url), $([math]::Round($clock.Elapsed.TotalSeconds, 1)) s after the end"
    if ($S.Url -ne $PageUrl) { Note "the page moved from $PageUrl to $($S.Url): its port was taken (the log says why)" }
    $logged = Wait-Until { if ((Get-LogCount 'helper: started') -ge $startsBefore + 1) { $true } } -Seconds 5

    $after = Get-Helper
    Save-Processes 'check4'
    Expect ($after.Supervisors.Count -eq 1 -and $after.Supervisors[0].Pid -eq $sup.Pid -and $after.Workers.Count -eq 1 -and $after.Others.Count -eq 0) "the same supervisor and one worker: $(Format-Helper $after)"
    Expect ((Get-LogCount 'supervisor: the helper stopped by itself; starting it again') -eq $restartsBefore + 1) "the supervisor logged the restart (supervisor.ts:76)"
    Expect ($logged -eq $true) "the new worker logged its start (worker.ts:267)"
    $status = Get-Status
    Expect ($null -ne $status -and $status.link.kind -eq 'unpaired') 'it is still unpaired'
    $S.Supervisor = $sup
    $S.Worker = $new
    Headline "worker $($old.Pid) ended; worker $($new.Pid) after $took s under the same supervisor $($sup.Pid); the page answers again"
  }

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '5' {
    $h = Get-Helper
    if ($h.Supervisors.Count -ne 1 -or $h.Workers.Count -ne 1) { throw "expected one supervisor and one worker, found: $(Format-Helper $h)" }
    $sup = $h.Supervisors[0]
    $wk = $h.Workers[0]
    $leftBefore = Get-LogCount 'supervisor: already running here'

    # The shortcut's own command, the program with --open (.nsi:93), twice in a row. Started from this
    # folder, not the shortcut's (the program folder): the browser --open starts would keep that one as
    # its working folder, and so stop check 8's uninstall from removing the program folder.
    $target = $Exe
    $arguments = '--open'
    if ($null -ne $S.Link -and $S.Link.TargetPath) { $target = $S.Link.TargetPath; $arguments = $S.Link.Arguments }
    # Each start's handle is closed once its exit code is read (Close-Process): alty-helper.exe stays
    # replaceable for check 6's reinstall.
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
      # each finds the supervisor's pipe held (lock.ts:106-132), opens the page and leaves with 0 (main.ts:97-101)
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
    Expect ($left -eq $leftBefore + 2) "the log says 'supervisor: already running here' twice more (main.ts:100)"

    # and for 5 s after, still the same one supervisor and one worker
    $steady = Watch-Steady -Supervisor $sup -Worker $wk -Seconds 5
    Save-Processes 'check5'
    Expect $steady.Ok $steady.Text
    Expect (Test-Page) "the page still answers at $($S.Url)"
    Headline "two starts left at once with 0; $($steady.Text)"
  }

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '6' {
    $h = Get-Helper
    if ($h.Supervisors.Count -ne 1 -or $h.Workers.Count -ne 1) { throw "expected one supervisor and one worker, found: $(Format-Helper $h)" }
    $oldSup = $h.Supervisors[0]
    $oldWk = $h.Workers[0]
    $before = @(Get-LogEntries)
    $firstLine = if ($before.Count -gt 0) { $before[0].Line } else { '' }

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
          ($_.Pid -eq $oldSup.Pid -and $_.Started -eq $oldSup.Started) -or ($_.Pid -eq $oldWk.Pid -and $_.Started -eq $oldWk.Started) })
      if ($alive.Count -eq 0) { $true }
    } -Seconds 10
    Expect ($gone -eq $true) "the old supervisor $($oldSup.Pid) and worker $($oldWk.Pid) ended"

    # silent, it starts the helper again at its end (.nsi:124-127)
    $back = Wait-Until {
      $x = Get-Helper
      $rt = Read-Runtime
      if ($x.Supervisors.Count -eq 1 -and $x.Workers.Count -eq 1 -and $x.Others.Count -eq 0 -and $x.Supervisors[0].Pid -ne $oldSup.Pid -and
        $x.Workers[0].ParentPid -eq $x.Supervisors[0].Pid -and $null -ne $rt -and $rt.workerPid -eq $x.Workers[0].Pid -and $rt.url) {
        [pscustomobject]@{ Helper = $x; Runtime = $rt }
      }
    } -Seconds 20
    Save-Processes 'check6'
    Expect ($null -ne $back) "it is back: $(if ($null -ne $back) { Format-Helper $back.Helper } else { Format-Helper (Get-Helper) })"
    if ($null -ne $back) {
      $S.Url = [string]$back.Runtime.url
      $S.Supervisor = $back.Helper.Supervisors[0]
      $S.Worker = $back.Helper.Workers[0]
      $S.ReinstallSupervisorPid = $S.Supervisor.Pid
    }
    Expect ((Wait-Until { Test-Page } -Seconds 15) -eq $true) "the page answers at $($S.Url)"

    # How it was stopped, read once the new supervisor has written its start: gracefully, by the page's quit
    # (main.ts:199-212, server.ts:119-126), so the worker's 'helper: stopped' with 0 (worker.ts:240, :283),
    # then its supervisor's line (supervisor.ts:64-66), then the new start; not the supervisor's pipe
    # (main.ts:213-215) nor taskkill (.nsi:112-116)
    $new = @(Get-LogEntries | Select-Object -Skip $before.Count)
    $stopped = Find-Index $new { param($e) $e.Message -eq 'helper: stopped' -and $null -ne $e.Data -and $e.Data.exitCode -eq 0 }
    $asked = Find-Index $new { param($e) $e.Message -eq 'supervisor: the helper was asked to stop' }
    $restarted = Find-Index $new { param($e) $e.Message -eq 'supervisor: started' }
    Expect ($stopped -ge 0 -and $asked -gt $stopped -and $restarted -gt $asked) "the installer's --quit stopped it before copying: 'helper: stopped' with 0, then 'supervisor: the helper was asked to stop', then a new 'supervisor: started' (new log lines $stopped, $asked, $restarted of $($new.Count))"
    if ($stopped -lt 0) {
      $byPipe = Find-Index $new { param($e) $e.Message -eq 'supervisor: asked to stop' }
      Note $(if ($byPipe -ge 0) { "it stopped through the supervisor's pipe instead: the page's quit did not end it" } else { 'neither quit is in the log: the installer ended the processes itself (taskkill)' })
    }

    # its data stays: an install never touches %LOCALAPPDATA%\Alty Helper (.nsi:78-104; only the uninstall does, :141)
    $entries = @(Get-LogEntries)
    Expect (Test-Path -LiteralPath $DataDir) "the data folder is kept: $DataDir"
    Expect ($entries.Count -gt $before.Count -and $firstLine -ne '' -and $entries[0].Line -eq $firstLine) "the log goes on from the first install's first line ($($before.Count) lines before, $($entries.Count) now)"
    $status = Get-Status
    Expect ($null -ne $status -and $status.link.kind -eq 'unpaired' -and $null -eq $status.pairing -and $status.version -eq $ExpectedVersion) "still unpaired, version $(if ($null -ne $status) { $status.version })"
    Expect (-not (Test-Path -LiteralPath (Join-Path $DataDir 'config.json'))) 'no config.json: nothing was ever paired or saved (worker.ts:121-124)'
    Expect ((Get-RegValue $RunKey $AppId) -eq "`"$Exe`"" -and (Test-Path -LiteralPath $Shortcut)) 'the Run key and the shortcut are still there'
    Headline "reinstalled in $took s: stopped by its own --quit, back as supervisor $(if ($S.Supervisor) { $S.Supervisor.Pid }), data kept, unpaired"
  }

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '7' {
    Expect (Test-Path -LiteralPath $LogFile) "the log is there: $LogFile"
    $entries = @(Get-LogEntries)
    Note "$($entries.Count) lines"

    # the supervisor's start line, with where it runs (main.ts:112, platform.ts:18-27): install and reinstall
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

    # the worker's start lines (worker.ts:267-272): the install, check 4's restart, the reinstall
    $wkStarts = @($entries | Where-Object { $_.Message -eq 'helper: started' })
    Expect ($wkStarts.Count -eq 3) "three 'helper: started' lines (install, restart, reinstall): $($wkStarts.Count)"
    foreach ($e in $wkStarts) {
      $d = $e.Data
      Expect ($null -ne $d -and $d.version -eq $ExpectedVersion -and $d.port -eq $Port -and $d.paired -eq $false -and $d.apiUrl -eq $ApiUrl) "worker start: $($e.Line)"
    }

    # no code and no secret in it (log.ts:16, :44-49; worker.ts:203 logs only the error)
    $text = ''
    foreach ($file in @(Get-ChildItem -LiteralPath $LogsDir -File -Filter 'helper.log*' -ErrorAction SilentlyContinue)) {
      $text += [string](Read-SharedText $file.FullName)
    }
    $codeFound = ($text.IndexOf($WrongCode, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
      $text.IndexOf($WrongCode.Replace('-', ''), [StringComparison]::OrdinalIgnoreCase) -ge 0)
    Expect (-not $codeFound) "the code $WrongCode is not in the log"
    $leaked = @($S.Secrets | Where-Object { $text.Contains($_) })
    Expect ($S.Secrets.Count -gt 0 -and $leaked.Count -eq 0) "none of the $($S.Secrets.Count) page tokens and quit secrets this test saw is in the log"

    # nothing unexpected: the warnings and errors are exactly the two this test caused
    $expected = @{
      'WARN|helper: pairing refused'                                     = 1   # check 3 (worker.ts:203)
      'ERROR|supervisor: the helper stopped by itself; starting it again' = 1   # check 4 (supervisor.ts:76)
    }
    $seen = @{}
    foreach ($e in @($entries | Where-Object { $_.Level -ne 'INFO' })) {
      $key = "$($e.Level)|$($e.Message)"
      $seen[$key] = 1 + [int]$seen[$key]
    }
    foreach ($key in $expected.Keys) {
      Expect ([int]$seen[$key] -eq $expected[$key]) "$($key.Replace('|', ' ')): $([int]$seen[$key]) (expected $($expected[$key]))"
    }
    $unexpected = @($entries | Where-Object { $_.Level -ne 'INFO' -and -not $expected.ContainsKey("$($_.Level)|$($_.Message)") })
    Expect ($unexpected.Count -eq 0) "no other warning or error$(if ($unexpected.Count) { ': ' + (($unexpected | ForEach-Object { $_.Line }) -join ' / ') })"
    $fatal = @($entries | Where-Object { $_.Message -eq 'helper: stopped by an error' })
    Expect ($fatal.Count -eq 0) "no 'helper: stopped by an error' (log.ts:141-152)"
    $tls = @($entries | Where-Object { $_.Message -like 'tls:*' })
    Expect ($tls.Count -eq 0) "Windows' certificate store was read: no 'tls:' warning (api.ts:22-34)"

    # into the evidence, before the uninstall takes the data folder
    $copied = @(Save-Logs)
    Expect ($copied.Count -ge 1) "copied to the evidence: $($copied -join ', ')"
    Headline "$($entries.Count) lines; start facts $(if ($supStarts.Count) { "node $($supStarts[0].Data.node), $($supStarts[0].Data.osVersion) $($supStarts[0].Data.osRelease)" }); no code, no secret; only the two expected warnings"
  }

  # everything the uninstall will take, kept first
  Save-Evidence 'before-uninstall'

  # -------------------------------------------------------------------------------------------------------
  Invoke-Check '8' {
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
    Expect ($left.Count -eq 0) "after $took s nothing is left$(if ($left.Count) { ': ' + ($left -join '; ') } else { ': no process, no program folder, no data folder, no Run key, no Apps entry, no shortcut' })"
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
