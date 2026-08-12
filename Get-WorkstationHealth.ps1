<#
.SYNOPSIS
    Quick workstation health check - system info, disk, performance,
    network, and basic security posture in one report.

.DESCRIPTION
    Pulls together several built-in PowerShell/CIM cmdlets to produce
    a fast snapshot of a Windows machine's state. Useful for IT/SOC
    triage, asset inventory, or a quick "is this machine okay" check.

.NOTES
    Author: Autumn McCurry
    Some sections (failed logons, local admins) benefit from running
    as Administrator. Script will note if a section is skipped due
    to insufficient privileges.

.EXAMPLE
    .\Get-WorkstationHealth.ps1
    .\Get-WorkstationHealth.ps1 -ExportPath "C:\Reports\health.txt"
#>

param(
    [string]$ExportPath
)

# Collect everything into one object so it's easy to export or reuse
$report = [ordered]@{}

function Write-Section($title) {
    Write-Host "`n=== $title ===" -ForegroundColor Cyan
}

# ---------- System Info ----------
Write-Section "System Info"
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$uptime = (Get-Date) - $os.LastBootUpTime

$systemInfo = [PSCustomObject]@{
    Hostname     = $cs.Name
    Manufacturer = $cs.Manufacturer
    Model        = $cs.Model
    OS           = $os.Caption
    OSVersion    = $os.Version
    LastBoot     = $os.LastBootUpTime
    Uptime       = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
}
$systemInfo | Format-List
$report.SystemInfo = $systemInfo

# ---------- Disk Space ----------
Write-Section "Disk Space"
$disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    Select-Object DeviceID,
        @{N="SizeGB"; E={[math]::Round($_.Size / 1GB, 1)}},
        @{N="FreeGB"; E={[math]::Round($_.FreeSpace / 1GB, 1)}},
        @{N="PercentFree"; E={[math]::Round(($_.FreeSpace / $_.Size) * 100, 1)}}
$disks | Format-Table -AutoSize
$report.Disks = $disks

foreach ($d in $disks) {
    if ($d.PercentFree -lt 10) {
        Write-Host "  WARNING: $($d.DeviceID) is below 10% free space!" -ForegroundColor Yellow
    }
}

# ---------- CPU / Memory Snapshot ----------
Write-Section "CPU & Memory"
$cpuLoad = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
$mem = Get-CimInstance Win32_OperatingSystem
$memUsedPercent = [math]::Round((($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) / $mem.TotalVisibleMemorySize) * 100, 1)

$perf = [PSCustomObject]@{
    CPULoadPercent    = $cpuLoad
    MemoryUsedPercent = $memUsedPercent
    TotalMemoryGB     = [math]::Round($mem.TotalVisibleMemorySize / 1MB, 1)
}
$perf | Format-List
$report.Performance = $perf

Write-Host "Top 5 processes by CPU:" -ForegroundColor DarkCyan
$topProcs = Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 Name, CPU, Id
$topProcs | Format-Table -AutoSize
$report.TopProcesses = $topProcs

# ---------- Network ----------
Write-Section "Network Configuration"
$netInfo = Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq "Up" } |
    Select-Object InterfaceAlias,
        @{N="IPAddress"; E={$_.IPv4Address.IPAddress}},
        @{N="Gateway"; E={$_.IPv4DefaultGateway.NextHop}},
        @{N="DNSServers"; E={($_.DNSServer.ServerAddresses -join ", ")}}
$netInfo | Format-Table -AutoSize
$report.Network = $netInfo

# ---------- Security: Failed Logons ----------
Write-Section "Recent Failed Logons (Event ID 4625)"
try {
    $failedLogons = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625} -MaxEvents 10 -ErrorAction Stop |
        Select-Object TimeCreated,
            @{N="Account"; E={$_.Properties[5].Value}},
            @{N="SourceIP"; E={$_.Properties[19].Value}}
    if ($failedLogons) {
        $failedLogons | Format-Table -AutoSize
    } else {
        Write-Host "No failed logon events found." -ForegroundColor Green
    }
    $report.FailedLogons = $failedLogons
} catch {
    Write-Host "  Skipped - requires Administrator privileges or no events found." -ForegroundColor DarkYellow
    $report.FailedLogons = "Skipped (insufficient privileges or no events)"
}

# ---------- Security: Local Admins ----------
Write-Section "Local Administrators Group"
try {
    $admins = Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop |
        Select-Object Name, PrincipalSource, ObjectClass
    $admins | Format-Table -AutoSize
    $report.LocalAdmins = $admins
} catch {
    Write-Host "  Skipped - requires Administrator privileges." -ForegroundColor DarkYellow
    $report.LocalAdmins = "Skipped (insufficient privileges)"
}

# ---------- Patch Status ----------
Write-Section "Recent Windows Updates"
$hotfixes = Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, Description, InstalledOn
$hotfixes | Format-Table -AutoSize
$report.RecentHotfixes = $hotfixes

# ---------- Export ----------
if ($ExportPath) {
    Write-Section "Exporting Report"

    # Make sure the destination folder exists and is writable before touching it.
    # Catches things like a missing parent folder or a protected path (e.g. C:\)
    # up front instead of failing silently section-by-section.
    $exportFolder = Split-Path -Path $ExportPath -Parent
    if ([string]::IsNullOrWhiteSpace($exportFolder)) { $exportFolder = "." }

    $canWrite = $false
    try {
        if (-not (Test-Path $exportFolder)) {
            New-Item -Path $exportFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        # Remove any existing file first so -Append below starts clean each run
        if (Test-Path $ExportPath) { Remove-Item $ExportPath -Force -ErrorAction Stop }
        New-Item -Path $ExportPath -ItemType File -Force -ErrorAction Stop | Out-Null
        $canWrite = $true
    } catch {
        Write-Host "  ERROR: Cannot write to '$ExportPath' - $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Try a path you have write access to, e.g. `"$env:USERPROFILE\Documents\report.txt`"" -ForegroundColor Yellow
    }

    if ($canWrite) {
        $exportFailed = $false
        foreach ($entry in $report.GetEnumerator()) {
            try {
                "`n=== $($entry.Key) ===`n" | Out-File -FilePath $ExportPath -Append -Encoding UTF8 -ErrorAction Stop
                $entry.Value | Format-Table -AutoSize | Out-File -FilePath $ExportPath -Append -Encoding UTF8 -ErrorAction Stop
            } catch {
                $exportFailed = $true
                Write-Host "  ERROR writing section '$($entry.Key)': $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        if ($exportFailed) {
            Write-Host "Report exported with errors - see above. Partial file at $ExportPath" -ForegroundColor Yellow
        } else {
            Write-Host "Report exported to $ExportPath" -ForegroundColor Green
        }
    }
}

Write-Host "`nHealth check complete." -ForegroundColor Cyan
