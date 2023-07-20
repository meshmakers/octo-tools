function Start-Octo([Boolean]$botService=$true,
                          [Boolean]$identityService=$true,
                          [Boolean]$assetRepService=$true,
                          [Boolean]$timeSeriesRepService=$true,
                          [Boolean]$communicationControllerService=$true,
                          [Boolean]$adminPanel=$true,
                          [Boolean]$identityOnly=$false
        
)
{
    if ($identityOnly)
    {
        $botService = $false;
        $assetRepService = $false;
        $timeSeriesRepService = $false;
        $communicationControllerService = $false;
        $adminPanel = $false;
    }
    
    $logDir = "logFiles"
    $jobs = New-Object System.Collections.ArrayList
    $publishVersion = "net7.0"

    if (!(Test-Path $rootPath))
    {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    function Start-Service($workingDirectory, $cmd, $logname, $cmdArguments, $jobName, $aspnetEnvironment = "Development")
    {
        Write-Host "Starting $( $jobName ) -> $cmdArguments"
        $arguments = @([System.IO.Path]::Combine($rootPath, $workingDirectory),[System.IO.Path]::Combine($rootPath, $logDir, $logname), $aspnetEnvironment)
        $arguments += $cmdArguments
        $job = Start-Job -ScriptBlock { Set-Location $args[0]; $env:ASPNETCORE_ENVIRONMENT = $args[2]; $localArgs = $args | Select-Object -Skip 3; & "$input" $localArgs 2>&1 >> $args[1] } -InputObject $cmd -ArgumentList $arguments -Name $jobName
        $jobs.Add($job) | OUT-NULL;
    }

    function Get-ServiceStatus()
    {
        foreach ($job in $jobs)
        {
            Write-Host "Status job $( $job.Name ): $( $job.State )"

        }
    }

    function Delete-LogFile([string]$file)
    {
        $file = [System.IO.Path]::Combine($rootPath, $logDir, $file)
        if (Test-Path $file)
        {
            Remove-Item -Force $file
        }
    }

    function Create-LogDirectory()
    {
        $path = [System.IO.Path]::Combine($rootPath, $logDir);
        If (!(test-path $path))
        {
            New-Item -ItemType Directory -Force -Path $path | Out-Null
        }
    }

    $env:OCTO_IDENTITY_LOGDIR = "../../../../logs/identity/"
    $env:OCTO_ASSETREPOSITORY_LOGDIR = "../../../../logs/assetrepository/"
    $env:OCTO_BOT_LOGDIR = "../../../../logs/bot/"
    $env:OCTO_HISTORIAN_LOGDIR = "../../../../logs/historian/"
    $env:OCTO_POLICY_LOGDIR = "../../../../logs/historian/"
    $env:OCTO_SYSTEM__ADMINUSERPASSWORD="OctoAdmin1"
    $env:OCTO_SYSTEM__DATABASEUSERPASSWORD="OctoUser1"


    Create-LogDirectory
    Delete-LogFile -file "IdentityServices.log"
    Delete-LogFile -file "PolicyServices.log"
    Delete-LogFile -file "AssetRepositoryServices.log"
    Delete-LogFile -file "TimeSeriesRepositoryServices.log"
    Delete-LogFile -file "CommunicationControllerServices.log"
    Delete-LogFile -file "BotServices.log"
    Delete-LogFile -file "AdminPanel.log"
    
    if ($identityService)
    {
        Start-Service -workingDirectory "octo-identity-services/bin/Debug/IdentityServices/$publishVersion/publish/" -cmd "dotnet" -logname "IdentityServices.log" -cmdArguments @("Meshmakers.Octo.Backend.IdentityServices.dll", "--urls=https://*:5003/") -jobName "IdentityServices"
    }
    if ($assetRepService)
    {
        Start-Service -workingDirectory "octo-asset-repo-services/bin/Debug/AssetRepositoryServices/$publishVersion/publish/" -cmd "dotnet" -logname "AssetRepositoryServices.log" -cmdArguments @("Meshmakers.Octo.Backend.AssetRepositoryServices.dll", "--urls=http://localhost:5000;https://localhost:5001") -jobName "AssetRepositoryServices"
    }
    if ($timeSeriesRepService)
    {
        Start-Service -workingDirectory "octo-time-series-repo-services/bin/Debug/HistorianRepositoryServices/$publishVersion/publish/" -cmd "dotnet" -logname "TimeSeriesRepositoryServices.log" -cmdArguments @("Meshmakers.Octo.Backend.HistorianRepositoryServices.dll", "--urls=https://localhost:5013") -jobName "TimeSeriesRepositoryServices"
    }
    if ($botService)
    {
        Start-Service -workingDirectory "octo-bot-services/bin/Debug/BotServices/$publishVersion/publish/" -cmd "dotnet" -logname "BotServices.log" -cmdArguments @("Meshmakers.Octo.Backend.BotServices.dll", "--urls=https://localhost:5009") -jobName "BotServices"
    }
    if ($communicationControllerService)
    {
        Start-Service -workingDirectory "octo-communication-controller-services/bin/Debug/CommunicationControllerServices/$publishVersion/publish/" -cmd "dotnet" -logname "CommunicationControllerServices.log" -cmdArguments @("Meshmakers.Octo.Backend.CommunicationControllerServices.dll", "--urls=https://localhost:5015") -jobName "CommunicationControllerServices"
    }
    if ($adminPanel)
    {
        Start-Service -workingDirectory "octo-frontend-admin-panel/bin/Debug/AdminPanel/$publishVersion/publish/" -cmd "dotnet" -logname "AdminPanel.log" -cmdArguments @("Meshmakers.Octo.Backend.AdminPanel.dll", "--urls=https://localhost:5005") -jobName "AdminPanel" -aspnetEnvironment "Staging"
    }

    Get-ServiceStatus

    Write-Host "Started. Press key to exit"

    $wait = $true;
    do
    {
        # wait for a key to be available:
        if ([Console]::KeyAvailable)
        {
            # read the key, and consume it so it won't
            # be echoed to the console:
            [Console]::ReadKey($true) | Out-Null
            # exit loop
            break
        }

        foreach ($job in $jobs)
        {
            if ($job.State -ne "Running")
            {
                Write-Warning "Service $( $job.Name ) is in status $( $job.State )"
                Receive-Job $job | Write-Output
                $wait = $false
                break;
            }
        }

        Start-Sleep -Seconds 2

    } while ($wait)


    Write-Host "Exiting jobs"
    foreach ($job in $jobs)
    {
        Write-Host "Stopping job $( $job.Name )"
        $job.StopJob()
    }
    Wait-Job $jobs | OUT-NULL
    Write-Host "Jobs stopped"

    Get-ServiceStatus
}

Export-ModuleMember -Function @('Start-Octo')