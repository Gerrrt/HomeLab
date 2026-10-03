# The way back in. Runs during a Windows BUILD, over the build's WinRM, before
# sysprep. A clone has no WinRM (SetupComplete.cmd closes it), so this is what
# phoenix's Ansible reaches every guest through (ADR-0077 decision 2).
#
# What it leaves in the template: the OpenSSH server installed but DISABLED and
# never started, password logins off, phoenix's public key as the only
# administrators' key, a firewall rule admitting phoenix alone, and PowerShell
# as the login shell.
# SetupComplete.cmd starts sshd on each clone, so each clone generates its own
# host keys at that first start rather than every guest sharing the template's.
#
# PHOENIX_PUBKEY and PHOENIX_ADDRESS come from the provisioner's
# environment_vars (windows.pkr.hcl), read from var.ssh_public_key_file and
# var.phoenix_address. The key is public; nothing secret passes through here.

$ErrorActionPreference = 'Stop'

if (-not $env:PHOENIX_PUBKEY) { throw 'PHOENIX_PUBKEY is empty' }
# A key type, a base64 blob of real length, then an optional comment. On the
# hand-built six (build-the-lab-domain.md), two guests were first given a
# placeholder from a draft, `ssh-ed25519 AAAA... paste here`. The script
# installed it without complaint, and the result was an sshd that phoenix
# could not log in to. Refuse anything that is not shaped like a key.
if ($env:PHOENIX_PUBKEY -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]{60,}={0,3}( \S.*)?$') {
  throw "PHOENIX_PUBKEY is not a public key: '$env:PHOENIX_PUBKEY'"
}
if (-not $env:PHOENIX_ADDRESS) { throw 'PHOENIX_ADDRESS is empty' }

# Server 2025 ships the server installed and disabled; Windows 11 needs the
# capability added, which fetches it over the build's egress.
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($cap.State -ne 'Installed') {
  Add-WindowsCapability -Online -Name $cap.Name | Out-Null
}
Stop-Service -Name sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType Disabled

# For a member of Administrators, sshd reads this file and not the user's own
# authorized_keys, and refuses it unless only Administrators and SYSTEM can
# write it. SIDs rather than names, so a localised image grants the same groups.
$dir = Join-Path $env:ProgramData 'ssh'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$keys = Join-Path $dir 'administrators_authorized_keys'
Set-Content -Path $keys -Value $env:PHOENIX_PUBKEY -Encoding ascii
icacls.exe $keys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls exited $LASTEXITCODE on $keys" }

# Key-only. sshd copies sshd_config_default into place at its first start only
# when no sshd_config exists, so writing one now decides what every clone
# starts with. Password logins would make the build password, which stays
# valid on a clone until Ansible rotates it, a way in from the segment.
$default = Join-Path $env:WINDIR 'System32\OpenSSH\sshd_config_default'
$config = (Get-Content -Path $default) -replace '^#?\s*PasswordAuthentication\s.*$', 'PasswordAuthentication no'
if (-not ($config -match '^PasswordAuthentication no$')) { $config = @('PasswordAuthentication no') + $config }
Set-Content -Path (Join-Path $dir 'sshd_config') -Value $config -Encoding ascii

# Ansible's shell_type is powershell (ansible/inventory/group_vars/all.yaml).
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
  -Value (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')

# The capability's own rule admits every address on every profile. This one
# admits phoenix, which is the only host that has the key anyway — scoping it
# keeps 22 off a /24 sweep from the rest of the segment, the reasoning §7 of
# build-the-lab-domain.md gives for 9182.
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH from phoenix' `
  -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress $env:PHOENIX_ADDRESS `
  -Action Allow | Out-Null
