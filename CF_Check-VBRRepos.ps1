################################################################################
# Nagios powershell script to ask Veeam of repository space usage              #
# Author: Tomas Stanislawski (http://www.hkr.se/)                              #
# Updated: 2025 - Added v12 module support, name filter, null-safe handling    #
# Version: 2.0                                                                 #
################################################################################

# Parameters
param(
    [string]$Name,
    [int]$Warning = 95,
    [int]$Critical = 99
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

# Fetch all normal repositories
$normalRepos = Get-VBRBackupRepository |
                Select-Object Name,
                              @{Name="TotalSpace";Expression={[math]::Round($PSItem.Info.CachedTotalSpace / 1GB)}},
                              @{Name="FreeSpace";Expression={[math]::Round($PSItem.Info.CachedFreeSpace / 1GB)}},
                              @{Name="Utilized";Expression={ if ($PSItem.Info.CachedTotalSpace -gt 0) { [math]::Round((100*($PSItem.Info.CachedTotalSpace-$PSItem.Info.CachedFreeSpace) / $PSItem.Info.CachedTotalSpace)) } else { 0 } }}

# Fetch all scaleout-repositories
$scaleoutRepos = foreach ($scaleoutRepo in (Get-VBRBackupRepository -ScaleOut -ErrorAction SilentlyContinue))
{
    $scaleoutExtents = $scaleoutRepo | Get-VBRRepositoryExtent
    $totalSpace = 0
    $freeSpace = 0

    foreach ($scaleoutExtent in $scaleoutExtents)
    {
        $totalSpace += $scaleoutExtent.Repository.Info.CachedTotalSpace
        $freeSpace += $scaleoutExtent.Repository.Info.CachedFreeSpace
    }

    # Handle repos with no space reported
    $totalSpaceGB = [math]::Round($totalSpace / 1GB)
    $freeSpaceGB = [math]::Round($freeSpace / 1GB)
    $utilized = if ($totalSpaceGB -gt 0) { [math]::Round((100 * ($totalSpaceGB - $freeSpaceGB) / $totalSpaceGB)) } else { 0 }

    New-Object psobject -Property @{
        Name = $scaleoutRepo.Name
        TotalSpace = $totalSpaceGB
        FreeSpace = $freeSpaceGB
        Utilized = $utilized
    }
}

# Combine all repos
$allRepos = @($normalRepos) + @($scaleoutRepos) | Where-Object { $_ -ne $null }

# Filter by name if specified
if ($Name) {
    $allRepos = $allRepos | Where-Object { $_.Name -eq $Name }
    if ($allRepos.Count -lt 1) { Write-Host "UNKNOWN - Repository '$Name' not found"; Exit $returnUnknown }
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
