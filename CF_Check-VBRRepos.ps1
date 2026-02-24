################################################################################
# Nagios powershell script to check Veeam repository space usage               #
# Original Author: Tomas Stanislawski (http://www.hkr.se/)                     #
# Updated: 2025 - Veeam v12 module support, GetContainer(), name filter        #
# Version: 2.2                                                                 #
################################################################################

param(
    [string]$Name,
    [int]$Warning = 95,
    [int]$Critical = 99,
    [switch]$List
)

# Exit codes
$returnOK = 0
$returnWarning = 1
$returnCritical = 2
$returnUnknown = 3
$returnCode = $returnOK

# Default plugin outputs
$nagiosTextstatus = "OK"
$nagiosTextoutput = "All repositories within limits"
$nagiosPerformanceData = ""

# Load Veeam PowerShell module (v12+)
Import-Module Veeam.Backup.PowerShell -DisableNameChecking -ErrorAction SilentlyContinue
if (!(Get-Module Veeam.Backup.PowerShell -ErrorAction SilentlyContinue)) { Write-Host "UNKNOWN - Missing Veeam PowerShell Module"; Exit $returnUnknown }

# Fetch all normal repositories using GetContainer() for accurate space data
$normalRepos = foreach ($repo in (Get-VBRBackupRepository)) {
    try {
        $container = $repo.GetContainer()
        $totalBytes = $container.CachedTotalSpace.InBytes
        $freeBytes = $container.CachedFreeSpace.InBytes
        if ($null -eq $totalBytes) { $totalBytes = [long]$container.CachedTotalSpace }
        if ($null -eq $freeBytes) { $freeBytes = [long]$container.CachedFreeSpace }
    } catch {
        $totalBytes = 0
        $freeBytes = 0
    }

    $totalGB = [math]::Round($totalBytes / 1GB, 1)
    $freeGB = [math]::Round($freeBytes / 1GB, 1)
    $utilized = if ($totalGB -gt 0) { [math]::Round((($totalGB - $freeGB) / $totalGB) * 100) } else { 0 }

    New-Object psobject -Property @{
        Name       = $repo.Name
        TotalSpace = $totalGB
        FreeSpace  = $freeGB
        Utilized   = $utilized
    }
}

# Fetch all scaleout-repositories
$scaleoutRepos = foreach ($scaleoutRepo in (Get-VBRBackupRepository -ScaleOut -ErrorAction SilentlyContinue)) {
    $totalBytes = 0
    $freeBytes = 0

    foreach ($extent in ($scaleoutRepo | Get-VBRRepositoryExtent)) {
        try {
            $container = $extent.Repository.GetContainer()
            $extTotal = $container.CachedTotalSpace.InBytes
            $extFree = $container.CachedFreeSpace.InBytes
            if ($null -eq $extTotal) { $extTotal = [long]$container.CachedTotalSpace }
            if ($null -eq $extFree) { $extFree = [long]$container.CachedFreeSpace }
            $totalBytes += $extTotal
            $freeBytes += $extFree
        } catch {}
    }

    $totalGB = [math]::Round($totalBytes / 1GB, 1)
    $freeGB = [math]::Round($freeBytes / 1GB, 1)
    $utilized = if ($totalGB -gt 0) { [math]::Round((($totalGB - $freeGB) / $totalGB) * 100) } else { 0 }

    New-Object psobject -Property @{
        Name       = $scaleoutRepo.Name
        TotalSpace = $totalGB
        FreeSpace  = $freeGB
        Utilized   = $utilized
    }
}

# Combine all repos
$allRepos = @($normalRepos) + @($scaleoutRepos) | Where-Object { $_ -ne $null }

# List mode - show available repo names and exit
if ($List) {
    Write-Host "Available repositories:"
    foreach ($r in $allRepos) { Write-Host "  [$($r.Name.Trim())]" }
    Exit 0
}

# Filter by name if specified
if ($Name) {
    $Name = $Name.Trim()
    $matched = @()
    foreach ($r in $allRepos) {
        if ($r.Name.Trim() -like "*$Name*") { $matched += $r }
    }
    if ($matched.Count -lt 1) { Write-Host "UNKNOWN - Repository matching '$Name' not found"; Exit $returnUnknown }
    $allRepos = $matched
}

# No repos found
if ($allRepos.Count -lt 1) { Write-Host "UNKNOWN - No repositories could be found"; Exit $returnUnknown }

# Evaluate thresholds and build perfdata
foreach ($repo in ($allRepos | Sort-Object -Property TotalSpace -Descending))
{
    $repoName = $repo.Name.Trim()
    $usedGB = $repo.TotalSpace - $repo.FreeSpace
    $nagiosPerformanceData += "'${repoName} used'=${usedGB}GB;;;0;$($repo.TotalSpace) '${repoName} utilization'=$($repo.Utilized)%;$Warning;$Critical;0;100 "

    if (($repo.Utilized -ge $Warning) -and ($repo.Utilized -lt $Critical) -and ($returnCode -lt $returnWarning)) {
        $returnCode = $returnWarning
        $nagiosTextstatus = "WARNING"
        $nagiosTextoutput = "One or more repositories in warning state"
    }
    if (($repo.Utilized -ge $Critical) -and ($returnCode -lt $returnCritical)) {
        $returnCode = $returnCritical
        $nagiosTextstatus = "CRITICAL"
        $nagiosTextoutput = "One or more repositories in critical state"
    }
}

# Output single Nagios status line with perfdata
Write-Host "$nagiosTextstatus - $nagiosTextoutput|$nagiosPerformanceData" -NoNewline

Exit $returnCode
