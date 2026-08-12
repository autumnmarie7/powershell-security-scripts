# Get-WorkstationHealth.ps1

A quick PowerShell health-check script for Windows workstations. Pulls system info, disk space, CPU/memory usage, network configuration, recent failed logon attempts, local admin group membership, and recent patch history into a single report.

## Why

Built as a fast triage tool for IT/SOC-style workflows — the kind of thing you'd run on a machine to get an at-a-glance sense of its state before digging deeper, or to standardize what gets checked during a quick audit.

## Usage

```powershell
# Run interactively, output to console
.\Get-WorkstationHealth.ps1

# Run and export a text report
.\Get-WorkstationHealth.ps1 -ExportPath "C:\Reports\health-$(Get-Date -Format yyyyMMdd).txt"
```

Some sections (failed logons, local admin membership) require running PowerShell as Administrator. If run without elevation, those sections are skipped gracefully with a note rather than erroring out.

## What it checks

| Section | Details |
|---|---|
| System Info | Hostname, OS, model, uptime |
| Disk Space | Free space per volume, flags anything under 10% free |
| CPU & Memory | Current load, top 5 processes by CPU |
| Network | Active adapters, IP, gateway, DNS |
| Failed Logons | Last 10 Event ID 4625 entries (source IP, account) |
| Local Admins | Members of the local Administrators group |
| Patch Status | Last 5 installed hotfixes |

## Notes

- Uses `Get-CimInstance` instead of the deprecated `Get-WmiObject`.
- All output is built as PowerShell objects first, so it's easy to pipe into `Export-Csv`, `ConvertTo-Json`, or filter further — the console/`Format-Table` output is just the default view.
- Designed to run standalone with no external modules required.

## Possible extensions

- Add a `-CriticalOnly` switch to only print sections with warnings
- Email or Slack the report on a schedule via Task Scheduler
- Add BitLocker/Defender status checks
- Convert to a scheduled remote sweep across multiple machines with `Invoke-Command`
