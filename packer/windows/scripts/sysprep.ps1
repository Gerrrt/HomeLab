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

# The 30-second wait is ping, not timeout.exe, which fails without a console.
# SetupComplete.cmd deletes this file and the task on every clone.
$cmd = Join-Path $env:WINDIR 'Temp\packer-sysprep.cmd'
Set-Content -Path $cmd -Encoding ascii -Value @(
  '@echo off'
  'ping -n 31 127.0.0.1 >nul'
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
