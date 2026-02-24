################################################################################
# Nagios powershell script to ask Veeam of repository space usage              #
# Author: Tomas Stanislawski (http://www.hkr.se/)                              #
# Updated: 2025 - v12 module support, GetContainer(), name filter              #
# Version: 2.1                                                                 #
################################################################################

# Parameters
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
$nagiosLongtext = ""

# Load Veeam PowerShell module (v12+)
Import-Module Veeam.Backup.PowerShell -DisableNameChecking -ErrorAction SilentlyContinue

# Check if module is loaded
if (!(Get-Module Veeam.Backup.PowerShell -ErrorAction SilentlyContinue)) { Write-Host "UNKNOWN - Missing Veeam PowerShell Module"; Exit $returnUnknown }

# Fetch all normal repositories and get space from GetContainer()
$normalRepos = foreach ($repo in (Get-VBRBackupRepository)) {
    try {
        $container = $repo.GetContainer()
        $totalBytes = $container.CachedTotalSpace.InBytes
        $freeBytes = $container.CachedFreeSpace.InBytes

        # Fall back to raw numeric if .InBytes doesn't exist
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

    $scaleoutExtents = $scaleoutRepo | Get-VBRRepositoryExtent
    foreach ($extent in $scaleoutExtents) {
        try {
            $container = $extent.Repository.GetContainer()
            $extTotal = $container.CachedTotalSpace.InBytes
            $extFree = $container.CachedFreeSpace.InBytes
            if ($null -eq $extTotal) { $extTotal = [long]$container.CachedTotalSpace }
            if ($null -eq $extFree) { $extFree = [long]$container.CachedFreeSpace }
            $totalBytes += $extTotal
            $freeBytes += $extFree
        } catch {
            # Skip extents we can't read
        }
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

# List mode - just show available repo names and exit
if ($List) {
    Write-Host "Available repositories:"
    foreach ($r in $allRepos) { Write-Host "  [$($r.Name)]" }
    Exit 0
}

# Filter by name if specified (wildcard match)
if ($Name) {
    $Name = $Name.Trim()
    $matched = @()
    foreach ($r in $allRepos) {
        $repoName = $r.Name.Trim()
        if ($repoName -like "*$Name*") { $matched += $r }
    }
    if ($matched.Count -lt 1) {
        Write-Host "UNKNOWN - Repository matching '$Name' not found"
        Write-Host "DEBUG - Available names and lengths:"
        foreach ($r in $allRepos) { Write-Host "  [$($r.Name)] (Length: $($r.Name.Length)) (Trimmed: $($r.Name.Trim().Length))" }
        Write-Host "DEBUG - Search term: [$Name] (Length: $($Name.Length))"
        Exit $returnUnknown
    }
    $allRepos = $matched
}

# Do some error checking, if no repos found do a quick exit
if ($allRepos.Count -lt 1) { Write-Host "UNKNOWN - No repositories could be found"; Exit $returnUnknown }

# Get longest values for output padding
$padTotalSpace = ($allRepos.TotalSpace | Sort-Object -Descending | Select-Object -First 1).ToString().Length
$padFreeSpace = ($allRepos.FreeSpace | Sort-Object -Descending | Select-Object -First 1).ToString().Length
$padName = ($allRepos.Name | ForEach-Object { $_.Length } | Sort-Object -Descending | Select-Object -First 1)

foreach ($repo in ($allRepos | Sort-Object -Property TotalSpace -Descending))
{
    if ($repo.Utilized -lt $Warning)
    {
        $nagiosPerformanceData = $nagiosPerformanceData + '''' + $repo.Name + ' used''=' + ($repo.TotalSpace - $repo.FreeSpace) + 'GB;;;0;' + $repo.TotalSpace + ' ''' + $repo.Name + ' utilization''=' + $repo.Utilized + '%' + ";$Warning;$Critical;0;100 "
        $nagiosLongtext = $nagiosLongtext + $repo.Name.PadRight($padName," ") + " Free space " + $repo.FreeSpace.ToString().PadLeft($padFreeSpace," ") + 'GB of ' + $repo.TotalSpace.ToString().PadLeft($padTotalSpace," ") + 'GB (' + $repo.Utilized.ToString().PadLeft(3," ") + '% utilized)' + "`n"
    } elseif (($repo.Utilized -ge $Warning) -and ($repo.Utilized -lt $Critical)) {
        $returnCode = $returnWarning
        $nagiosTextstatus = "WARNING"
        $nagiosTextoutput = "One or more repositories are in warning state, please see extended output"
        $nagiosPerformanceData = $nagiosPerformanceData + '''' + $repo.Name + ' used''=' + ($repo.TotalSpace - $repo.FreeSpace) + 'GB;;;0;' + $repo.TotalSpace + ' ''' + $repo.Name + ' utilization''=' + $repo.Utilized + '%' + ";$Warning;$Critical;0;100 "
        $nagiosLongtext = $nagiosLongtext + $repo.Name.PadRight($padName," ") + " Free space " + $repo.FreeSpace.ToString().PadLeft($padFreeSpace," ") + 'GB of ' + $repo.TotalSpace.ToString().PadLeft($padTotalSpace," ") + 'GB (' + $repo.Utilized.ToString().PadLeft(3," ") + '% utilized - WARNING)' + "`n"
    } elseif ($repo.Utilized -ge $Critical) {
        $returnCode = $returnCritical
        $nagiosTextstatus = "CRITICAL"
        $nagiosTextoutput = "One or more repositories are in critical state, please see extended output"
        $nagiosPerformanceData = $nagiosPerformanceData + '''' + $repo.Name + ' used''=' + ($repo.TotalSpace - $repo.FreeSpace) + 'GB;;;0;' + $repo.TotalSpace + ' ''' + $repo.Name + ' utilization''=' + $repo.Utilized + '%' + ";$Warning;$Critical;0;100 "
        $nagiosLongtext = $nagiosLongtext + $repo.Name.PadRight($padName," ") + " Free space " + $repo.FreeSpace.ToString().PadLeft($padFreeSpace," ") + 'GB of ' + $repo.TotalSpace.ToString().PadLeft($padTotalSpace," ") + 'GB (' + $repo.Utilized.ToString().PadLeft(3," ") + '% utilized - CRITICAL)' + "`n"
    }
}

# Dump the results
Write-Host "$nagiosTextstatus - $nagiosTextoutput|$nagiosPerformanceData`n$nagiosLongtext" -NoNewline

# And exit with a code
Exit $returnCode
