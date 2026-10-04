# Writes the days left on this evaluation licence where windows_exporter's
# textfile collector reads them. LabWindowsEvaluationExpiring alerts on it
# (stacks/lab/prometheus/rules/lab.rules.yaml). Servers only; placed by
# ansible/roles/licence_clock — edit it there, not on the guest.
$d = (Get-CimInstance SoftwareLicensingProduct |
      Where-Object PartialProductKey |
      Select-Object -First 1).GracePeriodRemaining / 1440
@(
  '# HELP windows_eval_grace_days_remaining Days left on this evaluation licence.'
  '# TYPE windows_eval_grace_days_remaining gauge'
  "windows_eval_grace_days_remaining $([math]::Floor($d))"
) | Set-Content -Encoding ascii `
    "C:\ProgramData\windows_exporter\textfile\licence.prom"
