Import-Module Veeam.Backup.PowerShell -DisableNameChecking

$repos = Get-VBRBackupRepository

foreach ($repo in $repos) {
    Write-Host "=========================================="
    Write-Host "REPO: $($repo.Name)"
    Write-Host "=========================================="
    Write-Host "Type: $($repo.Type)"
    Write-Host ""

    Write-Host "--- Info Properties ---"
    Write-Host "CachedTotalSpace: $($repo.Info.CachedTotalSpace)"
    Write-Host "CachedFreeSpace:  $($repo.Info.CachedFreeSpace)"
    Write-Host ""

    Write-Host "--- Direct Properties ---"
    $repo | Get-Member -MemberType Property | ForEach-Object {
        $propName = $_.Name
        try {
            $val = $repo.$propName
            Write-Host "${propName}: $val"
        } catch {
            Write-Host "${propName}: (error reading)"
        }
    }
    Write-Host ""

    Write-Host "--- GetContainer Attempt ---"
    try {
        $container = $repo.GetContainer()
        Write-Host "CachedTotalSpace: $($container.CachedTotalSpace)"
        Write-Host "CachedFreeSpace:  $($container.CachedFreeSpace)"
        $container | Get-Member -MemberType Property | ForEach-Object {
            $propName = $_.Name
            try {
                $val = $container.$propName
                Write-Host "${propName}: $val"
            } catch {
                Write-Host "${propName}: (error reading)"
            }
        }
    } catch {
        Write-Host "GetContainer failed: $($_.Exception.Message)"
    }
    Write-Host ""
}
