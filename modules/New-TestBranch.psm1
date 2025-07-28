<#
.Synopsis
Creates a test branch for all octo-* git repositories and updates version
.Description
This function creates a test branch with format /test/0.x-text for all octo-* repositories
and updates the OctoVersion in Directory.Build.props from 0.1.* to 0.x.*
.Example
New-TestBranch -Version 5 -Description "feature-test"
# Creates branch /test/0.5-feature-test
.Parameter Version
The version number (2-999) to use in branch name and version update
.Parameter Description
The description text to append to branch name
.Parameter NoPush
Skip pushing the branch to remote origin
.Parameter NugetServer
Optional NuGet server URL to use in Octo.User.props
#>
function New-TestBranch {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(2, 999)]
        [int]$Version,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [Parameter(Mandatory = $false)]
        [switch]$NoPush,

        [Parameter(Mandatory = $false)]
        [string]$NugetServer = "https://nuget.mm.cloud/v3/index.json"
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return
    }

    $branchName = "test/0.$Version-$Description"
    $newVersionPattern = "0.$Version.*"
    $status = @{}

    # Get all directories starting with "octo-"
    $octoDirectories = Get-ChildItem -Directory -Path $rootPath -Filter "octo-*"

    foreach ($directory in $octoDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"
        $directoryName = $directory.Name

        # Check if the ".git" directory exists
        if (Test-Path -Path $gitDirectory -PathType Container) {
            try {
                Write-Host "Processing repository $directoryName" -ForegroundColor Green

                $basedir = $PWD
                Push-Location $directory.FullName

                # Create and checkout new branch
                git checkout -b $branchName
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create branch $branchName"
                }

                # Create Octo.User.props file
                $octoUserPropsPath = Join-Path -Path $directory.FullName -ChildPath "Octo.User.props"
                $octoUserPropsContent = @"
<Project>
    <PropertyGroup>
        <OctoNugetPrivateServer>$NugetServer</OctoNugetPrivateServer>
        <OctoVersion Condition="'`$(OctoNugetPrivateServer)'!='' And '`$(OctoVersion)'==''">$newVersionPattern</OctoVersion>
    </PropertyGroup>
</Project>
"@
                Set-Content -Path $octoUserPropsPath -Value $octoUserPropsContent -Encoding UTF8
                Write-Host "  Created Octo.User.props with version $newVersionPattern" -ForegroundColor Blue

                # Add and commit the Octo.User.props file
                git add "Octo.User.props"
                git commit -m "Add Octo.User.props for test branch with version $newVersionPattern"
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to commit Octo.User.props"
                }

                # Push branch to remote origin
                if (-not $NoPush) {
                    Write-Host "  Pushing branch to origin..." -ForegroundColor Blue
                    git push -u origin $branchName
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to push branch $branchName to origin"
                    }
                    Write-Host "  Branch pushed successfully" -ForegroundColor Green
                }

                Pop-Location
                $status.Add($directoryName, $true)

            } catch {
                Write-Host "Error processing repository $directoryName : $_" -ForegroundColor Red
                Pop-Location
                $status.Add($directoryName, $false)
            }
        } else {
            Write-Host "Skipping $directoryName (no git repository)" -ForegroundColor Yellow
        }
    }

    # Summary
    Write-Host ""
    Write-Host "Branch creation summary:" -ForegroundColor Cyan
    foreach($key in $status.Keys) {
        if($status[$key] -eq $true) {
            $pushStatus = if ($NoPush) { "(local only)" } else { "and pushed" }
            Write-Host "  ✓ $key - Branch '$branchName' created $pushStatus" -ForegroundColor Green
        } else {
            Write-Host "  ✗ $key - Failed to create branch" -ForegroundColor Red
        }
    }

    Write-Host ""
    $pushInfo = if ($NoPush) { " (local only)" } else { " and pushed to origin" }
    Write-Host "Done. Created test branch '$branchName' with version '$newVersionPattern'$pushInfo" -ForegroundColor Cyan
}

Export-ModuleMember -Function @('New-TestBranch')