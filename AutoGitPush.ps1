# Auto Git Push on File Changes
$path = "C:\Mach4Hobby\Profiles\BLP\Scripts"
$filter = "*.*"
$excludeDirs = @('.git', 'Dependencies\libBackup')

# Create FileSystemWatcher
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $path
$watcher.Filter = $filter
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::LastWrite

# Debounce timer (avoid multiple commits for rapid changes)
$global:lastCommit = [DateTime]::MinValue
$debounceSeconds = 30  # Wait 30 seconds after last change

$action = {
    $changedPath = $Event.SourceEventArgs.FullPath
    
    # Skip if in excluded directories
    foreach ($exclude in $excludeDirs) {
        if ($changedPath -like "*\$exclude\*") { return }
    }
    
    # Skip git operations
    if ($changedPath -like "*.git*") { return }
    
    # Check debounce
    $now = [DateTime]::Now
    if (($now - $global:lastCommit).TotalSeconds -lt $debounceSeconds) {
        Write-Host "Change detected, waiting for more changes..." -ForegroundColor Yellow
        return
    }
    
    # Wait a bit for file operations to complete
    Start-Sleep -Seconds 2
    
    Write-Host "Auto-committing changes..." -ForegroundColor Green
    Set-Location $path
    
    # Git operations
    & git add .
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    & git commit -m "Auto-commit: $timestamp"
    & git push origin master
    
    $global:lastCommit = $now
    Write-Host "Changes pushed to GitHub!" -ForegroundColor Cyan
}

# Register events
Register-ObjectEvent -InputObject $watcher -EventName "Changed" -Action $action
Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $action
Register-ObjectEvent -InputObject $watcher -EventName "Deleted" -Action $action
Register-ObjectEvent -InputObject $watcher -EventName "Renamed" -Action $action

# Start monitoring
$watcher.EnableRaisingEvents = $true

Write-Host "Monitoring $path for changes..." -ForegroundColor Green
Write-Host "Press Ctrl+C to stop" -ForegroundColor Yellow

# Keep script running
while ($true) { Start-Sleep -Seconds 1 }