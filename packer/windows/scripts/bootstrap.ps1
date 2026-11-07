# Runs once, at the first autologon of a Windows BUILD, from the answer disc.
#
# Order matters. The guest agent goes in first, because the Proxmox builder
# learns the guest's address by asking the agent; WinRM is useless to Packer
# until that address is known. WinRM last, because the moment it answers,
# Packer starts provisioning.
#
# WinRM here is HTTPS, with a certificate this script makes, and Basic auth
# inside it, for the length of a build on VLAN 30. Its firewall rule admits
# phoenix alone. SetupComplete.cmd removes all of it from every clone
# (ADR-0074). It was HTTP Basic, unencrypted, open to the segment: the build
# password crossed VLAN 30 in clear for any guest there to read (#846).
#
# Read through templatefile() in windows.pkr.hcl, which fills in phoenix's
# address below. A dollar sign followed by a brace, or a percent sign followed
# by one, is template syntax here: write neither.

$ErrorActionPreference = 'Stop'

$phoenix = '${phoenix_address}'
if (-not $phoenix) { throw 'phoenix_address is empty' }

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

# Enable-PSRemoting brings more than the service: an HTTP listener on 5985,
# and Windows' own "Windows Remote Management" inbound rules, which on the
# Private profile set above admit every address. Neither is wanted, so both
# go. The rules are found by the port they open, not by a name: the display
# names are localised, and every rule for 5985 is one this build has no use
# for.
Enable-PSRemoting -SkipNetworkProfileCheck -Force
Get-ChildItem -Path WSMan:\localhost\Listener |
  Where-Object { $_.Keys -contains 'Transport=HTTP' } |
  Remove-Item -Recurse -Force
Get-NetFirewallPortFilter -Protocol TCP |
  Where-Object { $_.LocalPort -eq '5985' } |
  Get-NetFirewallRule |
  Where-Object { $_.Direction -eq 'Inbound' } |
  Disable-NetFirewallRule

# Packer authenticates with Basic, so Basic stays on; AllowUnencrypted stays
# at its default, off, so Basic is only ever accepted inside TLS. The
# certificate is self-signed and Packer does not check it (winrm_insecure), so
# this keeps the password from a passive listener on the segment, not from one
# that sits in the middle. The phoenix-only rule is what keeps the rest of the
# segment from reaching the port at all.
Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $true
$cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -FriendlyName 'packer-winrm' `
  -CertStoreLocation Cert:\LocalMachine\My
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * `
  -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null
New-NetFirewallRule -Name 'packer-winrm-https' -DisplayName 'Packer WinRM from phoenix (build only)' `
  -Direction Inbound -Protocol TCP -LocalPort 5986 -RemoteAddress $phoenix -Action Allow | Out-Null
Restart-Service -Name WinRM
