function Invoke-BuildZenonPlug {
    param(
        [string]$configuration = "Release",
        [string]$repositoryPath = ".\",
        [switch]$Json
    )

    if(!$IsWindows) {
        if (-not $Json) {
            Write-Host "Skipping Zenon plug (Windows-only)" -ForegroundColor Yellow
        }
        if ($Json) {
            Write-OctoJson -Command 'Invoke-BuildZenonPlug' -Data (New-OctoActionResult -Success $true -ExitCode 0 -Extra @{
                logFile = $null
                skipped = $true
            })
        }
        return
    }
    
    
    
    $logFile = Join-Path $repositoryPath "Invoke-Build.log"
    if (Test-Path $logFile) {
        Remove-Item $logFile
    }
    
    $repositoryPath = $(Resolve-Path -Path $repositoryPath).Path
    
    $windowsServiceProjectPath = Join-Path $repositoryPath "src\Octo.Edge.Adapter.Zenon.WindowsService"
    # Framework-dependent publish with explicit win-x64 RID so output lands in
    # net10.0\win-x64\publish\ (where the WiX Setup project's createFileList.ps1
    # looks). Matches the Azure Release pipeline layout without bloating the MSI
    # with a self-contained .NET runtime.
    Invoke-Publish -repositoryPath $windowsServiceProjectPath -configuration $configuration -publishParameters @("-r", "win-x64", "--self-contained", "false")
    
    $msbuildApp = &"${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -prerelease -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe


    if (-not $Json) {
        Write-Host "[$configuration] Building git repository $repositoryPath" -ForegroundColor Green
    }
    & $msbuildApp /t:Restore /t:Build /p:Configuration=$configuration $repositoryPath  > $logFile
    $exitCode = $LASTEXITCODE
    $state = $exitCode -eq 0
    if (-not $Json) {
        if ($state -eq $false) {
            Write-Host "[$configuration] Build failed" -ForegroundColor Red
        }
        else {
            Write-Host "[$configuration] Build finished" -ForegroundColor Green
        }
    }
    $Global:LASTEXITCODE = $exitCode

    if ($Json) {
        Write-OctoJson -Command 'Invoke-BuildZenonPlug' -Data (New-OctoActionResult -Success $state -ExitCode $exitCode -Extra @{
            logFile = $logFile
        })
        return
    }
}


Export-ModuleMember -Function @('Invoke-BuildZenonPlug')