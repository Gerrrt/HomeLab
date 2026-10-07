@echo off
rem Runs once on a CLONE, at the end of its first Setup, as SYSTEM.
rem
rem Makes sure what bootstrap.ps1 opened for the build is gone (the sysprep
rem task removed most of it first): the HTTPS WinRM listener, its rule and
rem certificate, Basic auth, and the service. Then starts the one way in a
rem clone keeps: OpenSSH, key-only, admitting phoenix alone, which openssh.ps1
rem installed disabled in the template (ADR-0077). Its first start here is
rem what generates this clone's own host keys.
rem
rem `call winrm`, NEVER BARE `winrm`. winrm is itself a batch file
rem (System32\winrm.cmd, around cscript winrm.vbs), and in cmd one batch file
rem running another without `call` hands over for good: the caller never
rem resumes. That was this script's first line. On 2026-10-02 the first clone
rem of 912 reached the login screen with no guest agent. Windows had logged
rem "executing" this script, yet nothing after that line took effect:
rem unattend-oobe.xml and packer-sysprep.cmd were never deleted, and neither
rem sshd nor the agent was started.
rem
rem EVERY STEP IS LOGGED, BEFORE IT RUNS, to %WINDIR%\Temp\SetupComplete.log,
rem with each command's output and exit code. A script that stops partway
rem then says where, which this one could not. It holds nothing secret, and it
rem stays on the clone. Nothing here may prompt either, because it runs with
rem no console: PowerShell gets -NonInteractive and the WSMan settings -Force.
rem
rem The exit-code lines put the redirect FIRST, `>> "%LOG%" echo ... rc=N`.
rem Written `echo ... rc=%ERRORLEVEL%>> "%LOG%"`, a code of 2 reads `rc=2>>`,
rem and cmd takes that 2 as a stream number: the line goes to stderr, not
rem the log. 912's clone lost every single-digit rc that way (2026-10-03).
rem
rem CRLF line endings are not required here; cmd.exe reads LF files.

set "LOG=%WINDIR%\Temp\SetupComplete.log"
echo %DATE% %TIME% start>> "%LOG%"

rem WinRM has to be RUNNING to be reconfigured. On a clone it is a delayed
rem start and has not come up yet when this runs: on 911's first clone
rem (2026-10-03) every winrm and WSMan call below failed "the client cannot
rem connect", so the build's listener and Basic auth stayed in its
rem configuration behind a disabled service, ready to return if anyone
rem re-enabled it. `net start` waits until it is running.
echo %TIME% WinRM: start, so it can be reconfigured>> "%LOG%"
net start WinRM>> "%LOG%" 2>&1
>> "%LOG%" echo %TIME%   rc=%ERRORLEVEL%

rem A BACKSTOP. The sysprep task (sysprep.ps1) removed the build's HTTPS
rem listener, its rule, and the certificate with its private key before
rem generalising, and logged it to packer-close-winrm.log. This removes
rem whichever of them is still here, and exits 1 only if one is left after
rem that, so rc=0 means none of the three is on this clone. A certificate is
rem removed by its path: Windows PowerShell 5.1 has no -DeleteKey on a piped
rem one, which is how this step failed on every clone before (#846). Basic
rem auth goes back off; AllowUnencrypted is not touched, because the build
rem never turns it on and setting it fails on the Public network a clone
rem starts on.
echo %TIME% powershell: the build's HTTPS listener, its rule and certificate, Basic auth>> "%LOG%"
powershell -NoProfile -NonInteractive -Command "Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' } | Remove-Item -Recurse -Force; Remove-NetFirewallRule -Name 'packer-winrm-https' -ErrorAction SilentlyContinue; Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'packer-winrm' } | ForEach-Object { Remove-Item -Path ('Cert:\LocalMachine\My\' + $_.Thumbprint) -Force }; Set-Item WSMan:\localhost\Service\Auth\Basic $false -Force; $left = @(Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' }).Count + @(Get-NetFirewallRule -Name 'packer-winrm-https' -ErrorAction SilentlyContinue).Count + @(Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq 'packer-winrm' }).Count; Write-Output ('left: ' + $left); if ($left) { exit 1 }">> "%LOG%" 2>&1
>> "%LOG%" echo %TIME%   rc=%ERRORLEVEL%

echo %TIME% WinRM: disable and stop>> "%LOG%"
sc.exe config WinRM start= disabled>> "%LOG%" 2>&1
sc.exe stop WinRM>> "%LOG%" 2>&1
>> "%LOG%" echo %TIME%   rc=%ERRORLEVEL%

del /q "%WINDIR%\Panther\unattend-oobe.xml">> "%LOG%" 2>&1

rem What sysprep.ps1 left to run sysprep outside the build's WinRM session.
rem The task has no trigger and cannot run again, but it has no business in
rem a guest. packer-close-winrm.log stays: it is what the sysprep task did to
rem the build's WinRM, and holds nothing secret.
echo %TIME% packer-sysprep: delete the task, its .cmd and its .ps1>> "%LOG%"
schtasks.exe /delete /tn packer-sysprep /f>> "%LOG%" 2>&1
del /q "%WINDIR%\Temp\packer-sysprep.cmd">> "%LOG%" 2>&1
del /q "%WINDIR%\Temp\packer-close-winrm.ps1">> "%LOG%" 2>&1

rem The account phoenix's key logs in as must be enabled. Client Windows
rem disables the built-in Administrator by default, and generalising puts
rem that default back, so 911's first clone came up with it disabled. sshd
rem then died at the first auth request, before any key check:
rem "LsaLogonUser() failed ... Status 0xC000006E SubStatus 0xC0000072"
rem (account restriction, account disabled), and phoenix saw only
rem "Connection reset". Server leaves it enabled, so this changes nothing
rem there. Found by its well-known RID, 500, not by name, so a localised
rem image works too. ADR-0077 makes this the account Ansible uses. SSH to it
rem is key-only, and #448 rotates its password.
echo %TIME% Administrator (RID 500): enable>> "%LOG%"
powershell -NoProfile -NonInteractive -Command "Get-LocalUser | Where-Object { $_.SID.Value -like '*-500' } | Enable-LocalUser">> "%LOG%" 2>&1
>> "%LOG%" echo %TIME%   rc=%ERRORLEVEL%

echo %TIME% sshd: enable and start>> "%LOG%"
sc.exe config sshd start= auto>> "%LOG%" 2>&1
sc.exe start sshd>> "%LOG%" 2>&1
>> "%LOG%" echo %TIME%   rc=%ERRORLEVEL%

rem Last: the guest agent, which sysprep.ps1 disabled so that it could not
rem answer before this script had run, sshd included. Its first answer is the
rem readiness signal scripts/packer-smoke.sh waits for.
echo %TIME% QEMU-GA: enable and start>> "%LOG%"
sc.exe config QEMU-GA start= auto>> "%LOG%" 2>&1
sc.exe start QEMU-GA>> "%LOG%" 2>&1
>> "%LOG%" echo %TIME%   rc=%ERRORLEVEL%
echo %DATE% %TIME% done>> "%LOG%"
