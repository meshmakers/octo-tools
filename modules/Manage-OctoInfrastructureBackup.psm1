
$script:VolumeShortNames = @('mongo-data0','mongo-data1','mongo-data2','crate-data1','crate-data2','crate-data3')

function Get-ComposeProjectName {
    param([string]$ComposeFile, [string]$InfraPath)

    try {
        $json = docker compose -f $ComposeFile config --format json 2>$null
        if ($LASTEXITCODE -eq 0 -and $json) {
            $config = $json | ConvertFrom-Json
            if ($config.name) {
                return $config.name
            }
        }
    } catch {}

    return Split-Path -Leaf $InfraPath
}

function Test-InfrastructureStopped {
    param([string]$ComposeFile, [string]$ProjectName)

    $ids = docker compose -f $ComposeFile -p $ProjectName ps -q 2>$null
    $running = ($ids | Where-Object { $_ -ne '' } | Measure-Object).Count
    if ($running -gt 0) {
        Write-Error "Infrastructure containers are still running.`nBring them down first (volumes are preserved):`n  docker compose -p $ProjectName down"
        return $false
    }
    return $true
}

function Resolve-DockerVolume {
    param([string]$ProjectName, [string]$ShortName)

    $fullName = "${ProjectName}_${ShortName}"
    docker volume inspect $fullName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return $fullName
    }
    return $null
}

function Get-FriendlySize {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) {
        return "{0:N1}G" -f ($Bytes / 1GB)
    } elseif ($Bytes -ge 1MB) {
        return "{0:N1}M" -f ($Bytes / 1MB)
    } elseif ($Bytes -ge 1KB) {
        return "{0:N1}K" -f ($Bytes / 1KB)
    }
    return "${Bytes}B"
}

function Backup-OctoInfrastructure {
    param(
        [string]$Name,
        [switch]$Json
    )

    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return
    }

    $composeFile = Join-Path $infrastructurePath "docker-compose.yml"
    $backupRoot = Join-Path $infrastructurePath "backups"
    $projectName = Get-ComposeProjectName -ComposeFile $composeFile -InfraPath $infrastructurePath

    if (!(Test-InfrastructureStopped -ComposeFile $composeFile -ProjectName $projectName)) {
        return
    }

    if ([string]::IsNullOrEmpty($Name)) {
        $Name = Get-Date -Format "yyyyMMdd-HHmmss"
    }

    $dest = Join-Path $backupRoot $Name

    if (Test-Path $dest) {
        Write-Error "Backup '$Name' already exists at $dest"
        return
    }

    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    if (-not $Json) {
        Write-Host "Backing up infrastructure volumes (project: $projectName) -> $Name"
        Write-Host ""
    }

    $volumeResults = [System.Collections.Generic.List[object]]::new()
    $failed = $false
    foreach ($short in $script:VolumeShortNames) {
        $vol = Resolve-DockerVolume -ProjectName $projectName -ShortName $short
        if ($null -eq $vol) {
            if (-not $Json) {
                Write-Host "  SKIP  $short  (volume ${projectName}_${short} not found)" -ForegroundColor Yellow
            }
            $volumeResults.Add([ordered]@{ volume = $short; status = 'SKIP' }) | Out-Null
            continue
        }

        if (-not $Json) {
            Write-Host -NoNewline ("{0,-20} ... " -f "  $short")
        }
        docker run --rm -v "${vol}:/source:ro" -v "${dest}:/backup" alpine tar cf "/backup/${short}.tar" -C /source . 2>$null
        if ($LASTEXITCODE -eq 0) {
            $fileInfo = Get-Item (Join-Path $dest "${short}.tar")
            $size = Get-FriendlySize -Bytes $fileInfo.Length
            if (-not $Json) {
                Write-Host "OK ($size)" -ForegroundColor Green
            }
            $volumeResults.Add([ordered]@{ volume = $short; status = 'OK'; sizeBytes = [long]$fileInfo.Length }) | Out-Null
        } else {
            if (-not $Json) {
                Write-Host "FAILED" -ForegroundColor Red
            }
            $volumeResults.Add([ordered]@{ volume = $short; status = 'FAILED' }) | Out-Null
            $failed = $true
        }
    }

    if ($Json) {
        Write-OctoJson -Command 'Backup-OctoInfrastructure' -Data ([ordered]@{
            name    = $Name
            success = [bool](-not $failed)
            volumes = @($volumeResults)
        })
        return
    }

    Write-Host ""
    if (!$failed) {
        Write-Host "Backup complete: $dest"
    } else {
        Write-Error "Backup completed with errors. Check output above."
    }
}

function Restore-OctoInfrastructure {
    param(
        [string]$Name,
        [switch]$Json
    )

    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return
    }

    $composeFile = Join-Path $infrastructurePath "docker-compose.yml"
    $backupRoot = Join-Path $infrastructurePath "backups"
    $projectName = Get-ComposeProjectName -ComposeFile $composeFile -InfraPath $infrastructurePath

    if ([string]::IsNullOrEmpty($Name)) {
        Write-Host "Usage: Restore-OctoInfrastructure -Name <name>"
        Write-Host "Available backups:"
        Get-OctoInfrastructureBackup
        return
    }

    if (!(Test-InfrastructureStopped -ComposeFile $composeFile -ProjectName $projectName)) {
        return
    }

    $src = Join-Path $backupRoot $Name

    if (!(Test-Path $src)) {
        Write-Error "Backup '$Name' not found at $src"
        return
    }

    if (-not $Json) {
        Write-Host "Restoring infrastructure volumes (project: $projectName) <- $Name"
        Write-Host ""
    }

    $volumeResults = [System.Collections.Generic.List[object]]::new()
    $failed = $false
    foreach ($short in $script:VolumeShortNames) {
        $archive = Join-Path $src "${short}.tar"
        if (!(Test-Path $archive)) {
            if (-not $Json) {
                Write-Host "  SKIP  $short  (no archive in backup)" -ForegroundColor Yellow
            }
            $volumeResults.Add([ordered]@{ volume = $short; status = 'SKIP' }) | Out-Null
            continue
        }

        $vol = "${projectName}_${short}"
        docker volume create $vol 2>$null | Out-Null

        if (-not $Json) {
            Write-Host -NoNewline ("{0,-20} ... " -f "  $short")
        }
        docker run --rm -v "${vol}:/target" -v "${src}:/backup:ro" alpine sh -c "rm -rf /target/* /target/..?* /target/.[!.]* 2>/dev/null; tar xf /backup/${short}.tar -C /target"
        if ($LASTEXITCODE -eq 0) {
            if (-not $Json) {
                Write-Host "OK" -ForegroundColor Green
            }
            $volumeResults.Add([ordered]@{ volume = $short; status = 'OK' }) | Out-Null
        } else {
            if (-not $Json) {
                Write-Host "FAILED" -ForegroundColor Red
            }
            $volumeResults.Add([ordered]@{ volume = $short; status = 'FAILED' }) | Out-Null
            $failed = $true
        }
    }

    if ($Json) {
        Write-OctoJson -Command 'Restore-OctoInfrastructure' -Data ([ordered]@{
            name    = $Name
            success = [bool](-not $failed)
            volumes = @($volumeResults)
        })
        return
    }

    Write-Host ""
    if (!$failed) {
        Write-Host "Restore complete."
        Write-Host "Start the infrastructure:"
        Write-Host "  Start-OctoInfrastructure"
    } else {
        Write-Error "Restore completed with errors. Check output above."
    }
}

function Get-OctoInfrastructureBackup {
    param(
        [switch]$Json
    )

    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return
    }

    $backupRoot = Join-Path $infrastructurePath "backups"

    if (!(Test-Path $backupRoot)) {
        if ($Json) {
            Write-OctoJson -Command 'Get-OctoInfrastructureBackup' -Data @()
            return
        }
        Write-Host "(no backups yet)"
        return
    }

    $dirs = Get-ChildItem -Path $backupRoot -Directory
    if ($dirs.Count -eq 0) {
        if ($Json) {
            Write-OctoJson -Command 'Get-OctoInfrastructureBackup' -Data @()
            return
        }
        Write-Host "(no backups yet)"
        return
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in $dirs) {
        $archives = Get-ChildItem -Path $dir.FullName -File | Where-Object { $_.Extension -eq '.tar' -or $_.Extension -eq '.gz' }
        $count = ($archives | Measure-Object).Count
        $totalBytes = ($archives | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $totalBytes) { $totalBytes = 0 }
        $totalSize = Get-FriendlySize -Bytes $totalBytes
        if ($Json) {
            $results.Add([ordered]@{
                name         = $dir.Name
                volumeCount  = [int]$count
                sizeBytes    = [long]$totalBytes
                sizeFriendly = $totalSize
            }) | Out-Null
        } else {
            Write-Host "  $($dir.Name)   ($count volumes, $totalSize)"
        }
    }

    if ($Json) {
        Write-OctoJson -Command 'Get-OctoInfrastructureBackup' -Data @($results)
        return
    }
}

function Remove-OctoInfrastructureBackup {
    param(
        [string]$Name,
        [switch]$Force,
        [switch]$Json
    )

    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return
    }

    $backupRoot = Join-Path $infrastructurePath "backups"

    if ([string]::IsNullOrEmpty($Name)) {
        Write-Error "Usage: Remove-OctoInfrastructureBackup -Name <name>"
        return
    }

    $target = Join-Path $backupRoot $Name

    if (!(Test-Path $target)) {
        Write-Error "Backup '$Name' not found"
        return
    }

    $files = Get-ChildItem -Path $target -File -Recurse
    $totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $totalBytes) { $totalBytes = 0 }
    $totalSize = Get-FriendlySize -Bytes $totalBytes

    if ($Json -and -not $Force) {
        Write-OctoJson -Command 'Remove-OctoInfrastructureBackup' -Data (New-OctoActionResult -Success $false -Extra @{ message = 'Refusing to prompt in -Json mode; pass -Force' })
        return
    }

    if (!$Force) {
        $answer = Read-Host "Delete backup '$Name' ($totalSize)? [y/N]"
        if ($answer -notmatch '^[Yy]$') {
            Write-Host "Aborted."
            return
        }
    }

    Remove-Item -Path $target -Recurse -Force

    if ($Json) {
        Write-OctoJson -Command 'Remove-OctoInfrastructureBackup' -Data (New-OctoActionResult -Success $true -Extra @{ name = $Name })
        return
    }

    Write-Host "Deleted."
}

Export-ModuleMember -Function @('Backup-OctoInfrastructure', 'Restore-OctoInfrastructure', 'Get-OctoInfrastructureBackup', 'Remove-OctoInfrastructureBackup')
