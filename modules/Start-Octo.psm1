function Start-Octo() {
    <#
.SYNOPSIS
Starts all OctoMesh services. 

.DESCRIPTION
The Start-Octo function starts all OctoMesh services, but gives the user control to exclude certain services from being started by setting their corresponding parameter to $false. 

.PARAMETER botService
If set to $true, the Bot Service will be started. If set to $false, it will not be started.

.PARAMETER identityService
If set to $true, the Identity Service will be started. If set to $false, it will not be started.

.PARAMETER assetRepoService
If set to $true, the Asset Repo Service will be started. If set to $false, it will not be started.

.PARAMETER meshAdapter
If set to $true, the mesh adapter will be started. If set to $false, it will not be started.

.PARAMETER communicationControllerService
If set to $true, the Communication Controller Service will be started. If set to $false, it will not be started.

.PARAMETER adminPanel
If set to $true, the Admin Panel will be started. If set to $false, it will not be started.

.PARAMETER identityOnly
If set to $true, only the Identity Service will be started. All other parameters will be ignored.

.EXAMPLE
Start-Octo -botService $false -identityService $true

This example starts all services except for the Bot Service.

.NOTES
Use this function to selectively start OctoMesh services based on your requirements.
#>

    param(
        [Parameter()] [string]$configuration = "Release",
        [Parameter()] [Boolean]$botService = $true,
        [Parameter()] [Boolean]$identityService = $true,
        [Parameter()] [Boolean]$assetRepoService = $true,
        [Parameter()] [Boolean]$meshAdapter = $true,
        [Parameter()] [Boolean]$communicationControllerService = $true,
        [Parameter()] [Boolean]$adminPanel = $true,
        [Parameter()] [Boolean]$identityOnly = $false, 
        [Parameter()] [Boolean]$identityAssetRepoOnly = $false  
    )
    if ($identityOnly) {
        $botService = $false;
        $assetRepoService = $false;
        $meshAdapter = $false;
        $communicationControllerService = $false;
        $adminPanel = $false;
    }
    if ($identityAssetRepoOnly) {
        $botService = $false;
        $meshAdapter = $false;
        $communicationControllerService = $false;
        $adminPanel = $false;
    }
    
    $logDir = "logFiles"
    $jobs = New-Object System.Collections.ArrayList
    $publishVersion = "net8.0"

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    function Start-Service($workingDirectory, $cmd, $logname, $cmdArguments, $jobName, $aspnetEnvironment = "Development") {
        Write-Host "Starting $( $jobName ) -> $cmdArguments"
        $arguments = @([System.IO.Path]::Combine($rootPath, $workingDirectory), [System.IO.Path]::Combine($rootPath, $logDir, $logname), $aspnetEnvironment)
        $arguments += $cmdArguments
        $job = Start-Job -ScriptBlock { Set-Location $args[0]; $env:ASPNETCORE_ENVIRONMENT = $args[2]; $localArgs = $args | Select-Object -Skip 3; & "$input" $localArgs 2>&1 >> $args[1] } -InputObject $cmd -ArgumentList $arguments -Name $jobName
        $jobs.Add($job) | OUT-NULL;
    }

    function Get-ServiceStatus() {
        foreach ($job in $jobs) {
            Write-Host "Status job $( $job.Name ): $( $job.State )"

        }
    }

    function Delete-LogFile([string]$file) {
        $file = [System.IO.Path]::Combine($rootPath, $logDir, $file)
        if (Test-Path $file) {
            Remove-Item -Force $file
        }
    }

    function Create-LogDirectory() {
        $path = [System.IO.Path]::Combine($rootPath, $logDir);
        If (!(test-path $path)) {
            New-Item -ItemType Directory -Force -Path $path | Out-Null
        }
    }

    $env:OCTO_SYSTEM__ADMINUSERPASSWORD = "OctoAdmin1"
    $env:OCTO_SYSTEM__DATABASEUSERPASSWORD = "OctoUser1"
    $env:OCTO_ADAPTER__ADAPTERRTID = "66004fda527ac79a03ecedd7"
    $env:OCTO_ADAPTER__ADAPTERCKTYPEID = "System.Communication/MeshAdapter"
    
    Create-LogDirectory
    Delete-LogFile -file "IdentityServices.log"
    Delete-LogFile -file "PolicyServices.log"
    Delete-LogFile -file "AssetRepositoryServices.log"
    Delete-LogFile -file "MeshAdapter.log"
    Delete-LogFile -file "CommunicationControllerServices.log"
    Delete-LogFile -file "BotServices.log"
    Delete-LogFile -file "AdminPanel.log"

    if ($identityService) {
        Start-Service -workingDirectory "octo-identity-services/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "IdentityServices.log" -cmdArguments @("Meshmakers.Octo.Backend.IdentityServices.dll", "--urls=https://*:5003;http://*:5002") -jobName "IdentityServices"
    }
    if ($assetRepoService) {
        Start-Service -workingDirectory "octo-asset-repo-services/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "AssetRepositoryServices.log" -cmdArguments @("Meshmakers.Octo.Backend.AssetRepositoryServices.dll", "--urls=http://*:5000;https://*:5001") -jobName "AssetRepositoryServices"
    }
    if ($meshAdapter) {
        Start-Service -workingDirectory "octo-mesh-adapter/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "MeshAdapter.log" -cmdArguments @("Meshmakers.Octo.MeshAdapter.dll", "--urls=https://*:5020;http://*:5021") -jobName "MeshAdapter"
    }
    if ($botService) {
        Start-Service -workingDirectory "octo-bot-services/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "BotServices.log" -cmdArguments @("Meshmakers.Octo.Backend.BotServices.dll", "--urls=https://*:5009;http://*:5008") -jobName "BotServices"
    }
    if ($communicationControllerService) {
        Start-Service -workingDirectory "octo-communication-controller-services/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "CommunicationControllerServices.log" -cmdArguments @("Meshmakers.Octo.Backend.CommunicationControllerServices.dll", "--urls=https://*:5015;http://*:5014") -jobName "CommunicationControllerServices"
    }
    if ($adminPanel) {
        Start-Service -workingDirectory "octo-frontend-admin-panel/bin/$configuration/AdminPanel/$publishVersion/publish/" -cmd "dotnet" -logname "AdminPanel.log" -cmdArguments @("Meshmakers.Octo.Backend.AdminPanel.dll", "--urls=https://*:5005;http://*:5004") -jobName "AdminPanel" -aspnetEnvironment "Staging"
    }

    Get-ServiceStatus

    Write-Host "Started. Press key to exit"

    $wait = $true;
    do {
        # wait for a key to be available:
        if ([Console]::KeyAvailable) {
            # read the key, and consume it so it won't
            # be echoed to the console:
            [Console]::ReadKey($true) | Out-Null
            # exit loop
            break
        }

        foreach ($job in $jobs) {
            if ($job.State -ne "Running") {
                Write-Warning "Service $( $job.Name ) is in status $( $job.State )"
                Receive-Job $job | Write-Output
                $wait = $false
                break;
            }
        }

        Start-Sleep -Seconds 2

    } while ($wait)


    Write-Host "Exiting jobs"
    foreach ($job in $jobs) {
        Write-Host "Stopping job $( $job.Name )"
        $job.StopJob()
    }
    Wait-Job $jobs | OUT-NULL
    Write-Host "Jobs stopped"

    Get-ServiceStatus
}

Export-ModuleMember -Function @('Start-Octo')