# Runs once, at the first autologon of a Windows BUILD, from the answer disc.
#
# Order matters. The guest agent goes in first, because the Proxmox builder
# learns the guest's address by asking the agent; WinRM is useless to Packer
# until that address is known. WinRM last, because the moment it answers,
# Packer starts provisioning.
#
# WinRM here is HTTP with Basic auth, for the length of a build on VLAN 30.
# SetupComplete.cmd removes it from every clone (ADR-0074).

$ErrorActionPreference = 'Stop'

# The Store updating an app for Administrator mid-build is the classic cause of
# "sysprep was not able to validate your Windows installation": the app ends up
# installed for a user and not provisioned for the image. Stop it fetching.
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name AutoDownload -Value 2 -Type DWord

# A network Windows calls Public blocks WinRM's firewall exception.
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# virtio-win-guest-tools: the remaining VirtIO drivers and qemu-guest-agent.
$tools = Get-PSDrive -PSProvider FileSystem |
  ForEach-Object { Join-Path $_.Root 'virtio-win-guest-tools.exe' } |
  Where-Object { Test-Path $_ } |
  Select-Object -First 1
if (-not $tools) { throw 'virtio-win-guest-tools.exe not found on any drive' }
Start-Process -FilePath $tools -ArgumentList '/install', '/passive', '/norestart' -Wait
Start-Service -Name QEMU-GA

Enable-PSRemoting -SkipNetworkProfileCheck -Force
Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $true
Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true
New-NetFirewallRule -Name 'packer-winrm-http' -DisplayName 'Packer WinRM (build only)' `
  -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow | Out-Null
Restart-Service -Name WinRM
