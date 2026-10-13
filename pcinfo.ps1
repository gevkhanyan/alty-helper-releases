# The computer's facts for Alty, read-only: Windows, security, user, clock, network, proxy, the local
# connections (the register's, if the till program keeps one open), printers, devices, screens,
# programs and the Alty helper. It changes nothing and sends nothing: it writes one text file on the
# Desktop and opens it in Notepad. At a business it is pasted into a normal Windows PowerShell window
# (a .ps1 file does not run under Windows 10's default settings); the smoke test runs this file.
$o = Join-Path ([Environment]::GetFolderPath('Desktop')) ("alty-pc-info-{0:yyyyMMdd-HHmm}.txt" -f (Get-Date))
function S($t, [scriptblock]$b) { "`r`n== $t"; try { & $b 2>&1 | Format-List | Out-String -Width 300 } catch { "ERROR: $_" } }
& {
 S 'windows' { Get-ComputerInfo -Property WindowsProductName,WindowsEditionId,WindowsVersion,OsBuildNumber,OsArchitecture,OsLanguage,CsManufacturer,CsModel,CsProcessors,CsTotalPhysicalMemory,TimeZone }
 S 'security' { Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct | Select displayName,productState; Get-MpComputerStatus | Select AMRunningMode,RealTimeProtectionEnabled,SmartAppControlState }
 S 'user' { whoami; (whoami /groups) -match 'S-1-5-32-544'; Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' | Select AutoAdminLogon; Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' | Select HiberbootEnabled }
 S 'clock' { Get-Date -Format o; tzutil /g }
 S 'network' { Get-NetIPAddress -AddressFamily IPv4 | Select InterfaceAlias,IPAddress,PrefixLength,PrefixOrigin; Get-NetIPConfiguration | Select InterfaceAlias,IPv4DefaultGateway,DNSServer }
 S 'proxy' { netsh winhttp show proxy; Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select ProxyEnable,ProxyServer,AutoConfigURL }
 S 'lan links' { Get-NetTCPConnection -State Established | ? { $_.RemoteAddress -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' } | Select LocalAddress,RemoteAddress,RemotePort,@{n='Process';e={(Get-Process -Id $_.OwningProcess -EA 0).ProcessName}} }
 S 'printers' { Get-CimInstance Win32_Printer | Select Name,DriverName,PortName,Default,WorkOffline; Get-PrinterPort | Select Name,PrinterHostAddress,PortNumber }
 S 'devices' { Get-CimInstance Win32_SerialPort | Select DeviceID,Name; Get-PnpDevice -PresentOnly -Class Ports,Printer,HIDClass,Image | Select Class,FriendlyName,Status }
 S 'screens' { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Screen]::AllScreens | Select DeviceName,Primary,Bounds }
 S 'programs' { Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -EA 0 | ? DisplayName | Select DisplayName,DisplayVersion,Publisher | Sort DisplayName }
 S 'alty helper' { $e = "$env:LOCALAPPDATA\Programs\Alty Helper\alty-helper.exe"; Get-Process alty-helper -EA 0 | Select Id,StartTime,Path; Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -EA 0 | Select AltyHelper; if (Test-Path $e) { Get-AuthenticodeSignature $e | Select Status; Get-FileHash $e } }
} | Out-File -Encoding utf8 -Width 300 $o
if (-not $env:CI) { notepad $o }
