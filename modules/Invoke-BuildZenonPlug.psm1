function Invoke-BuildZenonPlug {
    param(
        [string]$configuration = "Release",
        [string]$repositoryPath = ".\"
    )
    
    if(!$IsWindows) {
        Write-Host "Zenon plug must be built under windows"
    }
    
    
    
    $logFile = Join-Path $repositoryPath "Invoke-Build.log"
    if (Test-Path $logFile) {
        Remove-Item $logFile
    }
    
    $repositoryPath = $(Resolve-Path -Path $repositoryPath).Path
    
    $windowsServiceProjectPath = Join-Path $repositoryPath "src\Octo.Edge.Adapter.Zenon.WindowsService"
    Invoke-Publish -repositoryPath $windowsServiceProjectPath -configuration $configuration -publishParamerters "--sc"
    
    $msbuildApp = &"${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -prerelease -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe


    Write-Host "[$configuration] Building git repository $repositoryPath" -ForegroundColor Green
    & $msbuildApp /t:Restore /t:Build /p:Configuration=$configuration $repositoryPath  > $logFile
    $state = $LASTEXITCODE -eq 0
    if ($state -eq $false) {
        Write-Host "[$configuration] Build failed" -ForegroundColor Red
    }
    else {
        Write-Host "[$configuration] Build finished" -ForegroundColor Green
    }
    $Global:LASTEXITCODE = $LASTEXITCODE
}


Export-ModuleMember -Function @('Invoke-BuildZenonPlug')