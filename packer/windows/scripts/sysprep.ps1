# The last thing a Windows build does: generalise, so every clone takes a new
# machine SID at first boot (ADR-0074 part 3).
#
# NOT RUN OVER WINRM, AND /shutdown, NOT /quit. Generalising uninstalls every
# device, the network adapter included, so the WinRM session this script runs
# in dies partway through. Windows then tears that session down and kills
# everything it started. On 2026-10-02 that was sysprep itself, twice: its
# log stopped mid "Uninstalling all existing devices", with no error and no
# Sysprep_succeeded.tag. So sysprep runs as a one-off scheduled task as
# SYSTEM, outside WinRM's job, and this script returns once that task is
# running. The task waits 30 seconds first, so this session ends cleanly
# before the network goes. Sysprep then powers the VM off, and
# wait-for-sysprep.sh, the build's next step, waits on phoenix for that.
# Nothing may boot this disk again before it is a template, or the
# generalisation is spent on the template itself.

$ErrorActionPreference = 'Stop'

# Drop the build's autologon so nothing logs in on the generalised image.
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
  -Name AutoAdminLogon, DefaultPassword -ErrorAction SilentlyContinue

# The guest agent must not start on a clone until its first Setup has finished,
# or an address from the agent would say "ready" while OOBE is still running.
# Disabled, not stopped: the builder shuts THIS boot down through the agent.
# SetupComplete.cmd turns it back on as its last act, so on a clone the
# agent's first answer means Setup is done (scripts/packer-smoke.sh relies on
# exactly that).
Set-Service -Name QEMU-GA -StartupType Disabled

# sshd was never started in the build (openssh.ps1), so there should be no host
# keys. If there are, every clone would present the same ones; delete them so
# each clone's first sshd start generates its own.
Remove-Item -Path (Join-Path $env:ProgramData 'ssh\ssh_host_*') -Force -ErrorAction SilentlyContinue

$answer = Join-Path $env:WINDIR 'Panther\unattend-oobe.xml'
if (-not (Test-Path $answer)) { throw "no $answer; the file provisioner should have put it there" }

# Sysprep will not generalise a volume that is encrypting, and from here on
# nothing can see why: it fails quietly, never powers off, and the build waits
# 45 minutes for nothing (911, 2026-10-03). So check now, while WinRM can still
# say so. The answer file's specialize pass is what prevents it; this is the
# alarm if that ever stops working. Server has no BitLocker cmdlets unless the
# feature is installed, and then there is nothing to check.
if (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue) {
  $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive
  if ($bl.VolumeStatus -ne 'FullyDecrypted') {
    throw "$($env:SystemDrive) is BitLocker $($bl.VolumeStatus) ($($bl.EncryptionPercentage)%); sysprep would fail. Is PreventDeviceEncryption set in autounattend.xml's specialize pass?"
  }
}

# CLOSE THE BUILD'S WINRM BEFORE GENERALISING, so the template never holds it.
# bootstrap.ps1 made an HTTPS listener on a self-signed certificate. Removing
# them on each clone (SetupComplete.cmd) left the certificate's private key in
# the template, the same on every clone, and the removal itself failed there:
# Windows PowerShell 5.1 has no -DeleteKey on a certificate piped to
# Remove-Item (#846, a 911 clone on 2026-10-07). By the time the task below
# runs, Packer is finished with WinRM: wait-for-sysprep.sh watches the power
# state through the Proxmox API. So the task runs this first, while the key
# still exists, and deletes the key through the key storage provider that holds
# it. It logs what it did to packer-close-winrm.log, which SetupComplete.cmd
# keeps, so a smoke clone can show it. It never stops sysprep from running.
$close = Join-Path $env:WINDIR 'Temp\packer-close-winrm.ps1'
Set-Content -Path $close -Encoding ascii -Value @'
$ErrorActionPreference = 'Continue'
$log = Join-Path $env:WINDIR 'Temp\packer-close-winrm.log'
function Log($m) { Add-Content -Path $log -Value ('{0:HH:mm:ss} {1}' -f (Get-Date), $m) }
Log 'start'
try {
  Get-ChildItem -Path WSMan:\localhost\Listener |
    Where-Object { $_.Keys -contains 'Transport=HTTPS' } |
    Remove-Item -Recurse -Force -ErrorAction Stop
  Log 'HTTPS listener removed'
} catch { Log "HTTPS listener: $_" }
Remove-NetFirewallRule -Name 'packer-winrm-https' -ErrorAction SilentlyContinue
Log ('packer-winrm-https rules left: ' + @(Get-NetFirewallRule -Name 'packer-winrm-https' -ErrorAction SilentlyContinue).Count)
foreach ($c in @(Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'packer-winrm' })) {
  try {
    $k = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($c)
    if ($k -is [System.Security.Cryptography.RSACng]) {
      $n = $k.Key.UniqueName; $k.Key.Delete(); Log "CNG key $n deleted"
    } elseif ($k -is [System.Security.Cryptography.RSACryptoServiceProvider]) {
      $n = $k.CspKeyContainerInfo.UniqueKeyContainerName; $k.PersistKeyInCsp = $false; $k.Clear(); Log "CAPI key $n deleted"
    } else { Log "no private key found for $($c.Thumbprint)" }
  } catch { Log "private key of $($c.Thumbprint): $_" }
  Remove-Item -Path ('Cert:\LocalMachine\My\' + $c.Thumbprint) -Force
  Log "certificate $($c.Thumbprint) removed"
}
Log ('packer-winrm certificates left: ' + @(Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'packer-winrm' }).Count)
Log 'done'
'@

# The 30-second wait is ping, not timeout.exe, which fails without a console.
# SetupComplete.cmd deletes this file, the script above and the task on every
# clone.
$cmd = Join-Path $env:WINDIR 'Temp\packer-sysprep.cmd'
Set-Content -Path $cmd -Encoding ascii -Value @(
  '@echo off'
  'ping -n 31 127.0.0.1 >nul'
  ('powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $close + '"')
  ('"%WINDIR%\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /quiet /unattend:' + $answer)
)

$action = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\cmd.exe') -Argument "/c `"$cmd`""
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'packer-sysprep' -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName 'packer-sysprep'

# Return only once it is really running, so a task that cannot start fails
# the build here, while WinRM can still say so.
for ($i = 0; $i -lt 10; $i++) {
  if ((Get-ScheduledTask -TaskName 'packer-sysprep').State -eq 'Running') {
    Write-Output 'sysprep scheduled; the VM powers off when it has generalised'
    exit 0
  }
  Start-Sleep -Seconds 1
}
throw "the packer-sysprep task did not start: $((Get-ScheduledTaskInfo -TaskName 'packer-sysprep').LastTaskResult)"
