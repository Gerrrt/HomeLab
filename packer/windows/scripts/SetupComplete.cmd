@echo off
rem Runs once on a CLONE, at the end of its first Setup, as SYSTEM.
rem
rem Closes what bootstrap.ps1 opened for the build: the HTTP Basic WinRM
rem listener, its firewall rule, and the service. Then starts the one way in a
rem clone keeps: OpenSSH, key-only, admitting phoenix alone, which openssh.ps1
rem installed disabled in the template (ADR-0076). Its first start here is what
rem generates this clone's own host keys.
rem
rem CRLF line endings are not required here; cmd.exe reads LF files.

winrm delete winrm/config/Listener?Address=*+Transport=HTTP
powershell -NoProfile -Command "Remove-NetFirewallRule -Name 'packer-winrm-http' -ErrorAction SilentlyContinue; Set-Item WSMan:\localhost\Service\Auth\Basic $false; Set-Item WSMan:\localhost\Service\AllowUnencrypted $false"
sc.exe config WinRM start= disabled
sc.exe stop WinRM
del /q "%WINDIR%\Panther\unattend-oobe.xml"

sc.exe config sshd start= auto
sc.exe start sshd

rem Last: the guest agent, which sysprep.ps1 disabled so that it could not
rem answer before this script had run, sshd included. Its first answer is the
rem readiness signal scripts/packer-smoke.sh waits for.
sc.exe config QEMU-GA start= auto
sc.exe start QEMU-GA
