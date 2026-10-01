# The last thing a Windows build does: generalise, so every clone takes a new
# machine SID at first boot (ADR-0074 part 3).
#
# /quit, not /shutdown: the Proxmox builder shuts the guest down through the
# agent once this returns, then converts it. Nothing may boot this disk again
# before it is a template, or the generalisation is spent on the template
# itself.

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

$sysprep = Join-Path $env:WINDIR 'System32\Sysprep\sysprep.exe'
$answer = Join-Path $env:WINDIR 'Panther\unattend-oobe.xml'
$p = Start-Process -FilePath $sysprep -Wait -PassThru -ArgumentList `
  '/generalize', '/oobe', '/quit', '/quiet', "/unattend:$answer"
if ($p.ExitCode -ne 0) { throw "sysprep exited $($p.ExitCode); see C:\Windows\System32\Sysprep\Panther\setuperr.log" }

# sysprep.exe can return before its own work is flushed. The tag it writes is
# the signal that the image is sealed.
$tag = Join-Path $env:WINDIR 'System32\Sysprep\Sysprep_succeeded.tag'
for ($i = 0; $i -lt 60 -and -not (Test-Path $tag); $i++) { Start-Sleep -Seconds 5 }
if (-not (Test-Path $tag)) { throw 'sysprep did not write Sysprep_succeeded.tag' }
