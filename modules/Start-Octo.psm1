function Start-Octo() {
    <#
.SYNOPSIS
Starts all OctoMesh services. 

.DESCRIPTION
The Start-Octo function starts all OctoMesh services, but gives the user control to exclude certain services from being started by setting their corresponding parameter to $false. 

.PARAMETER SystemDatabase
The name of the system database to use. Defaults to "OctoSystem".

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

.PARAMETER platformServices
If set to $true, the Platform Services (tenant-scoped `_configuration` discovery endpoint that replaced the legacy admin-panel host) will be started. If set to $false, it will not be started.

.PARAMETER dataRefineryStudio
If set to $true, the Data Refinery Studio will be started. If set to $false, it will not be started.

.PARAMETER frontendLibraries
If set to $true, the Frontend Libraries dev servers will be started. If set to $false, they will not be started.

.PARAMETER identityOnly
If set to $true, only the Identity Service will be started. All other parameters will be ignored.

.PARAMETER reportingService
If set to $true, the Reporting Service will be started. If set to $false, it will not be started.

.PARAMETER simulationAdapter
If set to $true, the Simulation Adapter will be started. If set to $false, it will not be started. Defaults to $false.

.PARAMETER meshAdapterTenantId
The tenant ID to use for the Mesh Adapter. Defaults to "meshtest".

.PARAMETER meshAdapterId
The adapter runtime ID to use for the Mesh Adapter. Defaults to "66004fda527ac79a03ecedd7".

.PARAMETER simulationAdapterTenantId
The tenant ID to use for the Simulation Adapter. Defaults to "meshtest".

.PARAMETER simulationAdapterId
The adapter runtime ID to use for the Simulation Adapter. Defaults to "65d5c447b420da3fb12381bc".

.PARAMETER nonInteractive
If set to $true, the function will not wait for a keypress to exit. Instead it blocks until a job fails
or a stop signal file is created. Use Stop-Octo to gracefully stop services in non-interactive mode.
This is useful for running services from background agents or CI/CD pipelines.

.PARAMETER mcpService
If set to $true, the MCP Service will be started if the octo-mcp-service directory exists locally. If set to $false, it will not be started. Defaults to $true.

.PARAMETER aiService
If set to $true, the AI Service will be started if the octo-ai-services directory exists locally. If set to $false, it will not be started. Defaults to $true.

.PARAMETER aiWorker
If set to $true, the standalone AI Worker (Remote agent-worker host, see #4130 Phase B) will be started if the octo-ai-services directory exists locally. Defaults to $false because the AI Service's default Subprocess mode (AiWorker:Mode=Subprocess) spawns the agent CLI directly without this host — only flip this on when you want to exercise the Remote agent-worker path locally.

.EXAMPLE
Start-Octo -botService $false -identityService $true

This example starts all services except for the Bot Service.

.EXAMPLE
Start-Octo -SystemDatabase "MyCustomSystem"

This example starts all services using "MyCustomSystem" as the system database name.

.EXAMPLE
Start-Octo -nonInteractive $true -configuration DebugL -identityAssetRepoOnly $true

This example starts only Identity and Asset Repo services in non-interactive mode with DebugL configuration.
Use Stop-Octo to stop the services.

.NOTES
Use this function to selectively start OctoMesh services based on your requirements.
#>

    param(
        [string]$branch = "",
        [Parameter()] [string]$configuration = "Release",
        [Parameter()] [string]$SystemDatabase = "OctoSystem",
        [Parameter()] [Boolean]$botService = $true,
        [Parameter()] [Boolean]$identityService = $true,
        [Parameter()] [Boolean]$assetRepoService = $true,
        [Parameter()] [Boolean]$meshAdapter = $true,
        [Parameter()] [Boolean]$communicationControllerService = $true,
        [Parameter()] [Boolean]$platformServices = $true,
        [Parameter()] [Boolean]$dataRefineryStudio = $true,
        [Parameter()] [Boolean]$frontendLibraries = $true,
        [Parameter()] [Boolean]$identityOnly = $false,
        [Parameter()] [Boolean]$identityAssetRepoOnly = $false,
        [Parameter()] [Boolean]$reportingService = $false,
        [Parameter()] [string]$meshAdapterTenantId = "meshtest",
        [Parameter()] [string]$meshAdapterId = "670000000000000000000002",
        [Parameter()] [Boolean]$simulationAdapter = $false,
        [Parameter()] [string]$simulationAdapterTenantId = "meshtest",
        [Parameter()] [string]$simulationAdapterId = "65d5c447b420da3fb12381bc",
        [Parameter()] [Boolean]$nonInteractive = $false,
        [Parameter()] [Boolean]$mcpService = $true,
        [Parameter()] [Boolean]$aiService = $true,
        [Parameter()] [Boolean]$aiWorker = $false
    )
    if ($identityOnly) {
        $botService = $false;
        $assetRepoService = $false;
        $meshAdapter = $false;
        $communicationControllerService = $false;
        $platformServices = $false;
        $dataRefineryStudio = $false;
        $frontendLibraries = $false;
        $mcpService = $false;
        $aiService = $false;
        $aiWorker = $false;
    }
    if ($identityAssetRepoOnly) {
        $botService = $false;
        $meshAdapter = $false;
        $communicationControllerService = $false;
        $platformServices = $false;
        $dataRefineryStudio = $false;
        $frontendLibraries = $false;
        $mcpService = $false;
        $aiService = $false;
        $aiWorker = $false;
    }
    
    $logDir = "logFiles"
    $jobs = New-Object System.Collections.ArrayList
    $publishVersion = "net10.0"

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    function Start-Service($workingDirectory, [string]$branch, $cmd, $logname, $cmdArguments, $jobName, $aspnetEnvironment = "Development") {

        # Check if branch is empty, if not use the branch name in log
        $branchString = $branch
        if ([string]::IsNullOrEmpty($branch)) {
            $branchString = "default"
        }
        Write-Host "Starting $( $jobName ) (branch $branchString) -> $cmdArguments" -ForegroundColor Green
        $branchRootPath = [System.IO.Path]::Combine($rootPath, $branch)
        $arguments = @([System.IO.Path]::Combine($branchRootPath, $workingDirectory), [System.IO.Path]::Combine($branchRootPath, $logDir, $logname), $aspnetEnvironment)
        $arguments += $cmdArguments
        $job = Start-Job -ScriptBlock { Set-Location $args[0]; $env:ASPNETCORE_ENVIRONMENT = $args[2]; $localArgs = $args | Select-Object -Skip 3; & "$input" $localArgs 2>&1 >> $args[1] } -InputObject $cmd -ArgumentList $arguments -Name $jobName
        $jobs.Add($job) | OUT-NULL;
    }

    function Get-ServiceStatus() {
        foreach ($job in $jobs) {
            Write-Host "Status job $( $job.Name ): $( $job.State )"

        }
    }

    function Delete-LogFile([string]$branch, [string]$file) {
        $branchRootPath = [System.IO.Path]::Combine($rootPath, $branch)
        $file = [System.IO.Path]::Combine($branchRootPath, $logDir, $file)
        if (Test-Path $file) {
            Remove-Item -Force $file
        }
    }

    function Create-LogDirectory([string]$branch) {
        $branchRootPath = [System.IO.Path]::Combine($rootPath, $branch)
        $path = [System.IO.Path]::Combine($branchRootPath, $logDir);
        If (!(test-path $path)) {
            New-Item -ItemType Directory -Force -Path $path | Out-Null
        }
    }

    $env:OCTO_SYSTEM__SYSTEMDATABASENAME = $SystemDatabase
    $env:OCTO_SYSTEM__ADMINUSERPASSWORD = "OctoAdmin1"
    $env:OCTO_SYSTEM__DATABASEUSERPASSWORD = "OctoUser1"
    $env:OCTO_SYSTEM__USEDIRECTCONNECTION = "true"

    # Point the local file-system catalogs at the selected branch checkout's .octo directory
    # instead of the central ~/.octo defaults. Derived from $branchRootPath (= $rootPath/$branch)
    # so the path tracks -branch (e.g. main -> meshmakers/main/.octo/...). The Start-Job service
    # processes below inherit these; asset-repo binds OCTO_<section>__RootPath and resolves the
    # catalogs per-checkout (RootPath drives content and, via ApplyRootPath, the co-located cache).
    $branchRootPath = [System.IO.Path]::Combine($rootPath, $branch)
    $env:OCTO_LocalFileSystemCatalog__RootPath          = [System.IO.Path]::Combine($branchRootPath, ".octo/local-catalog")
    $env:OCTO_LocalFileSystemBlueprintCatalog__RootPath = [System.IO.Path]::Combine($branchRootPath, ".octo/local-blueprint-catalog")

    # Concept §5: instance-level gate for stream data. With this set to true the asset-repo
    # accepts EnableStreamDataAsync calls per tenant; without it the controller throws
    # StreamDataNotEnabledException. Local dev defaults to enabled.
    $env:OCTO_STREAMDATA__ENABLED = "true"

    # At-rest secret encryption — shared dev key across services so cross-replica
    # round-trips work (M1 operational unification, see octo-ai-services
    # docs/concepts/implementation-m1.md §3.5). The same byte value feeds both
    # OCTO_AIENCRYPTION__INSTANCESECRETKEY (binds to AiEncryptionOptions, consumed
    # by the AI Adapter's InstanceSecretEncryptionService) and
    # OCTO_COMMUNICATIONCONTROLLER__INSTANCESECRETKEY (binds to
    # CommunicationControllerOptions, consumed by WorkloadEncryptionService). Both
    # services delegate the actual crypto to Meshmakers.Octo.Sdk.Common.Encryption.
    # InstanceSecretCrypto. Production sets the same byte value via the Helm
    # global.instanceSecretKey materialised into both env vars.
    $env:OCTO_AIENCRYPTION__INSTANCESECRETKEY = "RGV2SW5zdGFuY2VLZXktT2N0b0FpU2VydmljZXMtMzI="
    $env:OCTO_COMMUNICATIONCONTROLLER__INSTANCESECRETKEY = "RGV2SW5zdGFuY2VLZXktT2N0b0FpU2VydmljZXMtMzI="
    $env:OCTO_IDENTITY__IdentityServerLicenseKey = "eyJhbGciOiJQUzI1NiIsImtpZCI6IklkZW50aXR5U2VydmVyTGljZW5zZWtleS83Y2VhZGJiNzgxMzA0NjllODgwNjg5MTAyNTQxNGYxNiIsInR5cCI6ImxpY2Vuc2Urand0In0.eyJpc3MiOiJodHRwczovL2R1ZW5kZXNvZnR3YXJlLmNvbSIsImF1ZCI6IklkZW50aXR5U2VydmVyIiwiaWF0IjoxNzI0Mzk1MTUyLCJleHAiOjE3NTU5MzExNTIsImNvbXBhbnlfbmFtZSI6ImdlcmFsZC5sb2NobmVyQHNhbHpidXJnZGV2LmF0IiwiY29udGFjdF9pbmZvIjoiZ2VyYWxkLmxvY2huZXJAc2FsemJ1cmdkZXYuYXQiLCJlZGl0aW9uIjoiQ29tbXVuaXR5In0.FAmDK4UWFuh83RpqFtVR4lSktDfGVGsow1qjTNyhlkZqUJwFtO7z_d9wmGle1lUbxbB0JtKD6BHxhPlnqMvaj1jOQlSkLoz9T9IV3FrZgvK-09nPJUyt0__fdCbIQPrTE3Wri0OsxNOnOz8be0KWeyuLCZxCPZPLRzpDamjITiiG3mBHS-EFxZnNhLsn7VJwKMsi7efVZ1JOwggqqZbZ49phKQSe7dWFHMs8w3F-lhNURnJIRjZ6JuRSOiYClFFA1rO23dtfGatjQdKwYkSvsPJTDMwBdGip7FcAtiTNi_SBjI2GtOao7VD1rSUOxI5o9-VPzC9wi_V2v7ZGYc7hxQ"
    $env:OCTO_IDENTITY__AutoMapperLicenseKey = "eyJhbGciOiJSUzI1NiIsImtpZCI6Ikx1Y2t5UGVubnlTb2Z0d2FyZUxpY2Vuc2VLZXkvYmJiMTNhY2I1OTkwNGQ4OWI0Y2IxYzg1ZjA4OGNjZjkiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2x1Y2t5cGVubnlzb2Z0d2FyZS5jb20iLCJhdWQiOiJMdWNreVBlbm55U29mdHdhcmUiLCJleHAiOiIxNzg1MTk2ODAwIiwiaWF0IjoiMTc1MzcxMzU3MSIsImFjY291bnRfaWQiOiIwMTk4NTE3OTFmNzY3ZDEwOGMwYjNiYzhjODNlMmY5NSIsImN1c3RvbWVyX2lkIjoiY3RtXzAxazE4cWp4NTJtemtlbW1wcWszZmF5Mnl3Iiwic3ViX2lkIjoiLSIsImVkaXRpb24iOiIwIiwidHlwZSI6IjIifQ.qlbbn1_eEpLhfUIIaVMGHhiKT_FTgR7b9niUJAfZE6MA5jPLAdpzQFKhvAsMTAl8fB2tCXsrsN7lT_OSFSSsmZKY1nLwvQs5GgfyGfG0vGbWQBbQbml27ofnZcTbMVideLqOJ1uZtWkilFjQ5utvt2id4n7zegDSgXbL2uA8Fe7iE1uZdm7rMjx5nFBXSt3694FlljVQ0YcJwIhGM1J-JxoGPfsfhbpSMP3YHbWlRDv2Gt53mir5tSpYLb6ZelFkjz7a4j7Fp0kctbWMI2nPH-XIz3KbExGxRIQ3G4XJ-lHnf9mWrrgoOXmGWQihQPStfpsLIpDy7zqyLJmPbB1M4g"

    # Set environment to development, because so we get more information in the logs
    $env:ASPNETCORE_ENVIRONMENT = "Development"
    
    Create-LogDirectory -branch $branch
    Delete-LogFile -branch $branch -file "IdentityServices.log"
    Delete-LogFile -branch $branch -file "PolicyServices.log"
    Delete-LogFile -branch $branch -file "AssetRepositoryServices.log"
    Delete-LogFile -branch $branch -file "MeshAdapter.log"
    Delete-LogFile -branch $branch -file "CommunicationControllerServices.log"
    Delete-LogFile -branch $branch -file "BotServices.log"
    Delete-LogFile -branch $branch -file "PlatformServices.log"
    Delete-LogFile -branch $branch -file "ReportingServices.log"
    Delete-LogFile -branch $branch -file "SimulationAdapter.log"
    Delete-LogFile -branch $branch -file "McpServices.log"
    Delete-LogFile -branch $branch -file "AiServices.log"
    Delete-LogFile -branch $branch -file "AiWorker.log"

    if ($identityService) {
        Start-Service -branch $branch -workingDirectory "octo-identity-services/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "IdentityServices.log" -cmdArguments @("Meshmakers.Octo.Backend.IdentityServices.dll", "--urls=https://0.0.0.0:5003;http://0.0.0.0:5002") -jobName "IdentityServices"
    }
    if ($assetRepoService) {
        Start-Service -branch $branch -workingDirectory "octo-asset-repo-services/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "AssetRepositoryServices.log" -cmdArguments @("Meshmakers.Octo.Backend.AssetRepositoryServices.dll", "--urls=http://0.0.0.0:5000;https://0.0.0.0:5001") -jobName "AssetRepositoryServices"
    }
    if ($meshAdapter) {
        Start-Service -branch $branch -workingDirectory "octo-mesh-adapter/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "MeshAdapter.log" -cmdArguments @("Meshmakers.Octo.MeshAdapter.dll", "--urls=https://0.0.0.0:5020;http://0.0.0.0:5021", "--Adapter:TenantId=$meshAdapterTenantId", "--Adapter:AdapterRtId=$meshAdapterId", "--Adapter:AdapterCkTypeId=System.Communication/Adapter") -jobName "MeshAdapter"
    }
    if ($botService) {
        Start-Service -branch $branch -workingDirectory "octo-bot-services/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "BotServices.log" -cmdArguments @("Meshmakers.Octo.Backend.BotServices.dll", "--urls=https://0.0.0.0:5009;http://0.0.0.0:5008") -jobName "BotServices"
    }
    if ($communicationControllerService) {
        Start-Service -branch $branch -workingDirectory "octo-communication-controller-services/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "CommunicationControllerServices.log" -cmdArguments @("Meshmakers.Octo.Backend.CommunicationControllerServices.dll", "--urls=https://0.0.0.0:5015;http://0.0.0.0:5014") -jobName "CommunicationControllerServices"
    }
    if ($platformServices) {
        Start-Service -branch $branch -workingDirectory "octo-platform-services/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "PlatformServices.log" -cmdArguments @("Meshmakers.Octo.Backend.PlatformServices.dll", "--urls=https://0.0.0.0:5025;http://0.0.0.0:5024") -jobName "PlatformServices"
    }
    if ($reportingService) {
        Start-Service -branch $branch -workingDirectory "octo-report-services/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "ReportingServices.log" -cmdArguments @("Meshmakers.Octo.Backend.ReportingServices.dll", "--urls=https://0.0.0.0:5007;http://0.0.0.0:5006") -jobName "ReportingServices"
    }
    if ($simulationAdapter) {
        Write-Host "Starting SimulationAdapter (branch $( if ([string]::IsNullOrEmpty($branch)) { 'default' } else { $branch } )) -> TenantId=$simulationAdapterTenantId, AdapterId=$simulationAdapterId" -ForegroundColor Green
        $simBranchRootPath = [System.IO.Path]::Combine($rootPath, $branch)
        $simWorkingDirectory = [System.IO.Path]::Combine($simBranchRootPath, "octo-sdk/src/Sdk.Plug.Simulation/bin/$configuration/$publishVersion/")
        $simLogFile = [System.IO.Path]::Combine($simBranchRootPath, $logDir, "SimulationAdapter.log")
        $job = Start-Job -ScriptBlock {
            param($workDir, $logPath, $tenantId, $adapterId)
            Set-Location $workDir
            $env:ASPNETCORE_ENVIRONMENT = "Development"
            & dotnet "Sdk.Plug.Simulation.dll" "--Adapter:TenantId=$tenantId" "--Adapter:AdapterRtId=$adapterId" 2>&1 >> $logPath
        } -ArgumentList $simWorkingDirectory, $simLogFile, $simulationAdapterTenantId, $simulationAdapterId -Name "SimulationAdapter"
        $jobs.Add($job) | Out-Null
    }

    if ($mcpService) {
        $mcpServicePath = [System.IO.Path]::Combine($rootPath, $branch, "octo-mcp-service/bin/$configuration/$publishVersion/")
        if (Test-Path $mcpServicePath) {
            Start-Service -branch $branch -workingDirectory "octo-mcp-service/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "McpServices.log" -cmdArguments @("Meshmakers.Octo.Backend.McpServices.dll", "--urls=https://0.0.0.0:5017;http://0.0.0.0:5016") -jobName "McpServices"
        } else {
            Write-Host "Skipping McpServices (directory not found: $mcpServicePath)" -ForegroundColor Yellow
        }
    }

    if ($aiService) {
        $aiServicePath = [System.IO.Path]::Combine($rootPath, $branch, "octo-ai-services/bin/$configuration/$publishVersion/")
        if (Test-Path $aiServicePath) {
            # Main AI Adapter API + SignalR hub. Phase-1 default has the orchestrator spawn the
            # agent CLI as a subprocess (AiWorker:Mode=Subprocess), so the standalone AiWorker
            # below is not required for local end-to-end testing.
            Start-Service -branch $branch -workingDirectory "octo-ai-services/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "AiServices.log" -cmdArguments @("Meshmakers.Octo.Backend.AiServices.dll", "--urls=https://0.0.0.0:5019;http://0.0.0.0:5018") -jobName "AiServices"
        } else {
            Write-Host "Skipping AiServices (directory not found: $aiServicePath)" -ForegroundColor Yellow
        }
    }

    if ($aiWorker) {
        $aiWorkerPath = [System.IO.Path]::Combine($rootPath, $branch, "octo-ai-services/bin/$configuration/$publishVersion/")
        if (Test-Path $aiWorkerPath) {
            # Standalone worker host targeted by RemoteAgentWorkerClient (#4130 Phase B). Only
            # started when explicitly enabled — Subprocess mode in the AI service spawns the
            # agent CLI in-process and doesn't need this host. To exercise it locally also flip
            # the AI service to Remote mode:
            #   $env:OCTO_AIWORKER__MODE = "Remote"
            #   $env:OCTO_AIWORKER__REMOTEWORKERURL = "http://localhost:5022/internal/worker/run"
            Start-Service -branch $branch -workingDirectory "octo-ai-services/bin/$configuration/$publishVersion/" -cmd "dotnet" -logname "AiWorker.log" -cmdArguments @("Meshmakers.Octo.Backend.AiWorker.dll", "--urls=https://0.0.0.0:5023;http://0.0.0.0:5022") -jobName "AiWorker"
        } else {
            Write-Host "Skipping AiWorker (directory not found: $aiWorkerPath)" -ForegroundColor Yellow
        }
    }

    # Start custom octo-start.ps1 scripts from repositories
    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch
    $octoDirectories = Get-ChildItem -Directory -Path $branchRootPath -Filter "octo-*"
    foreach ($directory in $octoDirectories) {
        $startScript = Join-Path -Path $directory.FullName -ChildPath "octo-start.ps1"
        if (Test-Path $startScript) {
            $repoName = $directory.Name

            # Skip Data Refinery Studio if disabled
            if ($repoName -eq "octo-frontend-refinery-studio" -and -not $dataRefineryStudio) {
                Write-Host "Skipping $repoName (disabled)" -ForegroundColor Yellow
                continue
            }

            # Skip Frontend Libraries if disabled
            if ($repoName -eq "octo-frontend-libraries" -and -not $frontendLibraries) {
                Write-Host "Skipping $repoName (disabled)" -ForegroundColor Yellow
                continue
            }

            Write-Host "Found custom start script in $repoName" -ForegroundColor Cyan
            Delete-LogFile -branch $branch -file "$repoName.log"

            $logFile = [System.IO.Path]::Combine($branchRootPath, $logDir, "$repoName.log")
            $job = Start-Job -ScriptBlock {
                param($scriptPath, $config, $logPath)
                & $scriptPath -configuration $config 2>&1 >> $logPath
            } -ArgumentList $startScript, $configuration, $logFile -Name $repoName
            $jobs.Add($job) | Out-Null
        }
    }

    Get-ServiceStatus

    if ($nonInteractive) {
        $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch
        $stopFile = Join-Path -Path $branchRootPath -ChildPath ".octo-stop"

        # Clean up any leftover stop signal
        if (Test-Path $stopFile) {
            Remove-Item -Force $stopFile
        }

        Write-Host "Started in non-interactive mode. Create '$stopFile' or send SIGTERM to stop."

        $wait = $true
        do {
            # Check for stop signal file
            if (Test-Path $stopFile) {
                Write-Host "Stop signal received."
                Remove-Item -Force $stopFile
                break
            }

            foreach ($job in $jobs) {
                if ($job.State -ne "Running") {
                    Write-Host ""
                    Write-Host "========================================" -ForegroundColor Red
                    Write-Warning "Service $( $job.Name ) is in status $( $job.State )"
                    Write-Host "--- Last output from $( $job.Name ): ---" -ForegroundColor Yellow
                    Receive-Job $job | Write-Output
                    Write-Host "========================================" -ForegroundColor Red
                    Write-Host ""
                    $wait = $false
                    break
                }
            }

            Start-Sleep -Seconds 2
        } while ($wait)
    }
    else {
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
                    Write-Host ""
                    Write-Host "========================================" -ForegroundColor Red
                    Write-Warning "Service $( $job.Name ) is in status $( $job.State )"
                    Write-Host "--- Last output from $( $job.Name ): ---" -ForegroundColor Yellow
                    Receive-Job $job | Write-Output
                    Write-Host "========================================" -ForegroundColor Red
                    Write-Host ""
                    $wait = $false
                    break;
                }
            }

            Start-Sleep -Seconds 2

        } while ($wait)
    }

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