Import-Module Veeam.Backup.PowerShell -DisableNameChecking

Write-Host "=== JobStatus Speed Test ==="
$jobs = Get-VBRJob -ErrorAction SilentlyContinue
$job = $jobs | Select-Object -First 1
Write-Host "Test job: $($job.Name)"

Write-Host ""
Write-Host "--- Method 1: FindLastSession ---"
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $session = $job.FindLastSession()
    $sw.Stop()
    Write-Host "Result: $($session.Result) EndTime: $($session.EndTime)"
    Write-Host "Time: $($sw.ElapsedMilliseconds)ms"
} catch {
    Write-Host "FindLastSession not available: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "--- Method 2: Get-VBRBackupSession -Job ---"
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $session2 = Get-VBRBackupSession -Job $job -ErrorAction SilentlyContinue | Sort-Object EndTime -Descending | Select-Object -First 1
    $sw.Stop()
    Write-Host "Result: $($session2.Result) EndTime: $($session2.EndTime)"
    Write-Host "Time: $($sw.ElapsedMilliseconds)ms"
} catch {
    Write-Host "Get-VBRBackupSession -Job not available: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "=== BackupAge Speed Test ==="

Write-Host ""
Write-Host "--- Method 1: Get-VBRBackup + GetLastPoint ---"
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $backups = Get-VBRBackup -ErrorAction SilentlyContinue
    $backup = $backups | Select-Object -First 1
    Write-Host "Test backup: $($backup.Name)"
    $lastPoint = $backup.GetLastPoint()
    $sw.Stop()
    Write-Host "VM: $($lastPoint.Name) Created: $($lastPoint.CreationTime)"
    Write-Host "Time: $($sw.ElapsedMilliseconds)ms"
} catch {
    Write-Host "GetLastPoint not available: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "--- Method 2: Get-VBRRestorePoint -Backup ---"
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $backup2 = Get-VBRBackup -ErrorAction SilentlyContinue | Select-Object -First 1
    $rps = Get-VBRRestorePoint -Backup $backup2 -ErrorAction SilentlyContinue
    $sw.Stop()
    $latest = $rps | Sort-Object CreationTime -Descending | Select-Object -First 1
    Write-Host "VM: $($latest.Name) Created: $($latest.CreationTime)"
    Write-Host "Count: $($rps.Count) restore points"
    Write-Host "Time: $($sw.ElapsedMilliseconds)ms"
} catch {
    Write-Host "Get-VBRRestorePoint -Backup not available: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "--- Method 3: Get-VBRBackup + GetOibs ---"
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $backup3 = Get-VBRBackup -ErrorAction SilentlyContinue | Select-Object -First 1
    $oibs = $backup3.GetOibs()
    $sw.Stop()
    Write-Host "VMs in backup:"
    foreach ($oib in $oibs) {
        Write-Host "  $($oib.Name) - Latest: $($oib.CreationTime)"
    }
    Write-Host "Time: $($sw.ElapsedMilliseconds)ms"
} catch {
    Write-Host "GetOibs not available: $($_.Exception.Message)"
}
