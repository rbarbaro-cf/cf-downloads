################################################################################
# Nagios Veeam Backup & Replication Monitoring Plugin                          #
# Version: 3.0                                                                 #
# Requires: Veeam v12+ PowerShell Module, NCPA Agent                          #
#                                                                              #
# Checks:                                                                      #
#   RepoSpace  - Repository space utilization                                  #
#   JobStatus  - Last backup job result (success/warning/fail)                 #
#   BackupAge  - Hours since last restore point per VM                         #
#   License    - Days until license expiration                                 #
#                                                                              #
# Usage:                                                                       #
#   CF_Check-Veeam.ps1 -Check RepoSpace [-Name "repo"] [-Warning 80] [-Critical 95]
#   CF_Check-Veeam.ps1 -Check JobStatus [-Exclude "job1,job2"]                #
#   CF_Check-Veeam.ps1 -Check BackupAge [-Warning 24] [-Critical 48] [-Exclude "vm1,vm2"]
#   CF_Check-Veeam.ps1 -Check License [-Warning 30] [-Critical 14]            #
#   CF_Check-Veeam.ps1 -List <RepoSpace|JobStatus|BackupAge>                  #
################################################################################

param(
    [ValidateSet("RepoSpace","JobStatus","BackupAge","License")]
    [string]$Check,
    [string]$Name,
    [string]$Exclude,
    [int]$Warning,
    [int]$Critical,
    [ValidateSet("RepoSpace","JobStatus","BackupAge","License")]
    [string]$List
)

# Exit codes
$returnOK = 0
$returnWarning = 1
$returnCritical = 2
$returnUnknown = 3
$returnCode = $returnOK

# Load Veeam PowerShell module
Import-Module Veeam.Backup.PowerShell -DisableNameChecking -ErrorAction SilentlyContinue
if (!(Get-Module Veeam.Backup.PowerShell -ErrorAction SilentlyContinue)) {
    Write-Host "UNKNOWN - Missing Veeam PowerShell Module"
    Exit $returnUnknown
}

# Validate required params
if (!$Check -and !$List) {
    Write-Host "UNKNOWN - Must specify -Check or -List"
    Exit $returnUnknown
}

# Parse exclude list into array
$excludeList = @()
if ($Exclude) {
    $excludeList = $Exclude.Split(",") | ForEach-Object { $_.Trim() }
}

###############################################################################
# LIST MODE
###############################################################################
if ($List) {
    switch ($List) {
        "RepoSpace" {
            $repos = Get-VBRBackupRepository
            Write-Host "Available repositories:"
            foreach ($r in $repos) { Write-Host "  [$($r.Name.Trim())]" }
        }
        "JobStatus" {
            $jobs = Get-VBRJob -ErrorAction SilentlyContinue
            Write-Host "Available backup jobs:"
            foreach ($j in $jobs) { Write-Host "  [$($j.Name.Trim())]" }
        }
        "BackupAge" {
            $jobs = Get-VBRJob -ErrorAction SilentlyContinue
            Write-Host "Available backup jobs (for VM age tracking):"
            foreach ($j in $jobs) { Write-Host "  [$($j.Name.Trim())]" }
        }
        "License" {
            Write-Host "No list available for License check"
        }
    }
    Exit 0
}

###############################################################################
# CHECK: RepoSpace
###############################################################################
if ($Check -eq "RepoSpace") {
    if (!$Warning) { $Warning = 95 }
    if (!$Critical) { $Critical = 99 }

    $nagiosTextstatus = "OK"
    $nagiosTextoutput = "All repositories within limits"
    $nagiosPerformanceData = ""

    # Normal repositories
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

    # Scaleout repositories
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

    $allRepos = @($normalRepos) + @($scaleoutRepos) | Where-Object { $_ -ne $null }

    # Filter by name
    if ($Name) {
        $Name = $Name.Trim()
        $matched = @()
        foreach ($r in $allRepos) {
            if ($r.Name.Trim() -like "*$Name*") { $matched += $r }
        }
        if ($matched.Count -lt 1) { Write-Host "UNKNOWN - Repository matching '$Name' not found"; Exit $returnUnknown }
        $allRepos = $matched
    }

    if ($allRepos.Count -lt 1) { Write-Host "UNKNOWN - No repositories could be found"; Exit $returnUnknown }

    foreach ($repo in ($allRepos | Sort-Object -Property TotalSpace -Descending)) {
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

    Write-Host "$nagiosTextstatus - $nagiosTextoutput|$nagiosPerformanceData" -NoNewline
    Exit $returnCode
}

###############################################################################
# CHECK: JobStatus
###############################################################################
if ($Check -eq "JobStatus") {
    $nagiosTextstatus = "OK"
    $nagiosTextoutput = "All backup jobs completed successfully"
    $nagiosPerformanceData = ""
    $warningJobs = @()
    $failedJobs = @()

    $jobs = Get-VBRJob -ErrorAction SilentlyContinue
    if ($null -eq $jobs -or $jobs.Count -lt 1) { Write-Host "UNKNOWN - No backup jobs found"; Exit $returnUnknown }

    foreach ($job in $jobs) {
        $jobName = $job.Name.Trim()

        # Skip excluded jobs
        $skip = $false
        foreach ($ex in $excludeList) {
            if ($jobName -like "*$ex*") { $skip = $true; break }
        }
        if ($skip) { continue }

        # Get last session for this job
        $lastSession = Get-VBRBackupSession -ErrorAction SilentlyContinue |
            Where-Object { $_.JobId -eq $job.Id } |
            Sort-Object -Property EndTime -Descending |
            Select-Object -First 1

        if ($null -eq $lastSession) {
            $warningJobs += "$jobName (no sessions found)"
            if ($returnCode -lt $returnWarning) { $returnCode = $returnWarning }
            continue
        }

        $result = $lastSession.Result.ToString()
        $endTime = $lastSession.EndTime.ToString("yyyy-MM-dd HH:mm")

        switch ($result) {
            "Failed" {
                $failedJobs += "$jobName (Failed $endTime)"
                if ($returnCode -lt $returnCritical) { $returnCode = $returnCritical }
            }
            "Warning" {
                $warningJobs += "$jobName (Warning $endTime)"
                if ($returnCode -lt $returnWarning) { $returnCode = $returnWarning }
            }
            default {
                $nagiosPerformanceData += "'${jobName}'=0;;;; "
            }
        }
    }

    if ($returnCode -eq $returnCritical) {
        $nagiosTextstatus = "CRITICAL"
        $nagiosTextoutput = "Failed: " + ($failedJobs -join ", ")
        if ($warningJobs.Count -gt 0) { $nagiosTextoutput += " | Warnings: " + ($warningJobs -join ", ") }
    } elseif ($returnCode -eq $returnWarning) {
        $nagiosTextstatus = "WARNING"
        $nagiosTextoutput = "Warnings: " + ($warningJobs -join ", ")
    }

    Write-Host "$nagiosTextstatus - $nagiosTextoutput|$nagiosPerformanceData" -NoNewline
    Exit $returnCode
}

###############################################################################
# CHECK: BackupAge
###############################################################################
if ($Check -eq "BackupAge") {
    if (!$Warning) { $Warning = 24 }
    if (!$Critical) { $Critical = 48 }

    $nagiosTextstatus = "OK"
    $nagiosTextoutput = "All backups within age limits"
    $nagiosPerformanceData = ""
    $warningVMs = @()
    $criticalVMs = @()
    $now = Get-Date

    $allRestorePoints = Get-VBRRestorePoint -ErrorAction SilentlyContinue
    if ($null -eq $allRestorePoints -or $allRestorePoints.Count -lt 1) {
        Write-Host "UNKNOWN - No restore points found"
        Exit $returnUnknown
    }

    # Group by VM name and get latest restore point per VM
    $vmGroups = $allRestorePoints | Group-Object -Property Name

    foreach ($vmGroup in $vmGroups) {
        $vmName = $vmGroup.Name.Trim()

        # Skip excluded VMs
        $skip = $false
        foreach ($ex in $excludeList) {
            if ($vmName -like "*$ex*") { $skip = $true; break }
        }
        if ($skip) { continue }

        $latestRP = $vmGroup.Group | Sort-Object -Property CreationTime -Descending | Select-Object -First 1
        $ageHours = [math]::Round(($now - $latestRP.CreationTime).TotalHours, 1)

        $nagiosPerformanceData += "'${vmName} age'=${ageHours}h;$Warning;$Critical;0; "

        if ($ageHours -ge $Critical) {
            $criticalVMs += "$vmName (${ageHours}h)"
            if ($returnCode -lt $returnCritical) { $returnCode = $returnCritical }
        } elseif ($ageHours -ge $Warning) {
            $warningVMs += "$vmName (${ageHours}h)"
            if ($returnCode -lt $returnWarning) { $returnCode = $returnWarning }
        }
    }

    if ($returnCode -eq $returnCritical) {
        $nagiosTextstatus = "CRITICAL"
        $nagiosTextoutput = "Stale backups: " + ($criticalVMs -join ", ")
        if ($warningVMs.Count -gt 0) { $nagiosTextoutput += " | Aging: " + ($warningVMs -join ", ") }
    } elseif ($returnCode -eq $returnWarning) {
        $nagiosTextstatus = "WARNING"
        $nagiosTextoutput = "Aging backups: " + ($warningVMs -join ", ")
    }

    Write-Host "$nagiosTextstatus - $nagiosTextoutput|$nagiosPerformanceData" -NoNewline
    Exit $returnCode
}

###############################################################################
# CHECK: License
###############################################################################
if ($Check -eq "License") {
    if (!$Warning) { $Warning = 30 }
    if (!$Critical) { $Critical = 14 }

    $nagiosTextstatus = "OK"
    $nagiosTextoutput = ""

    $license = Get-VBRInstalledLicense -ErrorAction SilentlyContinue
    if ($null -eq $license) { Write-Host "UNKNOWN - Unable to retrieve license information"; Exit $returnUnknown }

    $expDate = $license.ExpirationDate
    $daysLeft = [math]::Round(($expDate - (Get-Date)).TotalDays)
    $licType = $license.Type
    $licEdition = $license.Edition

    if ($daysLeft -le 0) {
        $returnCode = $returnCritical
        $nagiosTextstatus = "CRITICAL"
        $nagiosTextoutput = "$licEdition $licType license EXPIRED on $($expDate.ToString('yyyy-MM-dd'))"
    } elseif ($daysLeft -le $Critical) {
        $returnCode = $returnCritical
        $nagiosTextstatus = "CRITICAL"
        $nagiosTextoutput = "$licEdition $licType license expires in $daysLeft days ($($expDate.ToString('yyyy-MM-dd')))"
    } elseif ($daysLeft -le $Warning) {
        $returnCode = $returnWarning
        $nagiosTextstatus = "WARNING"
        $nagiosTextoutput = "$licEdition $licType license expires in $daysLeft days ($($expDate.ToString('yyyy-MM-dd')))"
    } else {
        $nagiosTextoutput = "$licEdition $licType license valid - $daysLeft days remaining ($($expDate.ToString('yyyy-MM-dd')))"
    }

    Write-Host "$nagiosTextstatus - $nagiosTextoutput" -NoNewline
    Exit $returnCode
}
