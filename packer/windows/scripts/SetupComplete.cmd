@echo off
rem Runs once on a CLONE, at the end of its first Setup, as SYSTEM.
rem
rem Closes what bootstrap.ps1 opened for the build: the HTTP Basic WinRM
rem listener, its firewall rule, and the service. A clone starts with no remote
rem management at all; how #448 reaches it is #448's decision, made on purpose,
rem not one inherited from a build shortcut (ADR-0073).
rem
rem CRLF line endings are not required here; cmd.exe reads LF files.

winrm delete winrm/config/Listener?Address=*+Transport=HTTP
powershell -NoProfile -Command "Remove-NetFirewallRule -Name 'packer-winrm-http' -ErrorAction SilentlyContinue; Set-Item WSMan:\localhost\Service\Auth\Basic $false; Set-Item WSMan:\localhost\Service\AllowUnencrypted $false"
sc.exe config WinRM start= disabled
sc.exe stop WinRM
del /q "%WINDIR%\Panther\unattend-oobe.xml"
