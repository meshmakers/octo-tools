<#
.SYNOPSIS
    Compares local pipeline YAML files with their deployed versions in a remote OctoMesh tenant.

.DESCRIPTION
    This module provides functionality to detect configuration drift between local pipeline
    definitions and their deployed versions in an OctoMesh tenant. It exports entities from
    the tenant, normalizes both local and tenant YAML files, and uses git diff to display
    differences.

.PARAMETER TenantId
    The tenant ID to compare against. Defaults to "maco".

.PARAMETER LocalPipelineDir
    The directory containing local pipeline YAML files.
    Defaults to "./deployment/maco-deployment/data/pipelines".

.PARAMETER ExportDir
    Temporary directory for exported files. Defaults to "./temp/pipeline-export".

.PARAMETER PipelineFile
    Optional. When specified, only compares a single pipeline file.

.PARAMETER KeepExports
    When set, preserves temporary export files after completion.

.EXAMPLE
    Compare-Pipelines
    Compares all pipelines in the default directory against the default tenant.

.EXAMPLE
    Compare-Pipelines -TenantId staging -PipelineFile ./deployment/maco-deployment/data/pipelines/rt-alarm-emails.yaml
    Compares a single pipeline file against the staging tenant.

.EXAMPLE
    Compare-Pipelines -KeepExports
    Compares all pipelines and preserves temporary files for inspection.
#>

# Import required module if available
if (Get-Module -ListAvailable -Name 'powershell-yaml') {
    Import-Module powershell-yaml -ErrorAction SilentlyContinue
}

#region Helper Functions

function Test-Prerequisites {
    <#
    .SYNOPSIS
        Validates that all prerequisites are met for pipeline comparison.
    #>
    [CmdletBinding()]
    param()

    $errors = @()

    # Check PowerShell version (need 7+ for YAML support via powershell-yaml)
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $errors += "PowerShell 7+ required. Current version: $($PSVersionTable.PSVersion)"
    }

    # Check for powershell-yaml module
    $yamlModule = Get-Module -ListAvailable -Name 'powershell-yaml' | Select-Object -First 1
    if (-not $yamlModule) {
        $errors += "powershell-yaml module not found. Install with: Install-Module -Name powershell-yaml -Scope CurrentUser"
    }

    # Check if octo-cli is available
    $octoCli = Get-Command "octo-cli" -ErrorAction SilentlyContinue
    if (-not $octoCli) {
        $errors += "octo-cli not found in PATH. Please build and configure octo-cli."
    }

    # Check if git is available
    $git = Get-Command "git" -ErrorAction SilentlyContinue
    if (-not $git) {
        $errors += "git not found in PATH. Please install git."
    }

    # Check authentication status
    if ($octoCli) {
        try {
            $authOutput = & octo-cli -c AuthStatus 2>&1
            $authString = $authOutput -join "`n"
            if ($authString -match "Token is not valid|No token|not authenticated" -or $LASTEXITCODE -ne 0) {
                $errors += "Not authenticated with octo-cli. Please run: octo-cli -c LogIn -i"
            }
        }
        catch {
            $errors += "Failed to check octo-cli authentication status: $_"
        }
    }

    if ($errors.Count -gt 0) {
        return @{
            Success = $false
            Errors  = $errors
        }
    }

    return @{
        Success = $true
        Errors  = @()
    }
}

function Get-PipelineFiles {
    <#
    .SYNOPSIS
        Gets the list of pipeline YAML files to process.
    #>
    [CmdletBinding()]
    param(
        [string]$LocalPipelineDir,
        [string]$PipelineFile
    )

    if ($PipelineFile) {
        if (-not (Test-Path $PipelineFile)) {
            throw "Pipeline file not found: $PipelineFile"
        }
        return @(Get-Item $PipelineFile)
    }

    if (-not (Test-Path $LocalPipelineDir)) {
        throw "Pipeline directory not found: $LocalPipelineDir"
    }

    $files = Get-ChildItem -Path $LocalPipelineDir -Filter "*.yaml" -File
    if ($files.Count -eq 0) {
        throw "No YAML files found in: $LocalPipelineDir"
    }

    return $files
}

function Get-PipelineMetadata {
    <#
    .SYNOPSIS
        Parses a pipeline YAML file and extracts metadata (rtIds and ckTypeId).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    try {
        $content = Get-Content -Path $FilePath -Raw
        $parsed = $content | ConvertFrom-Yaml

        if (-not $parsed.entities -or $parsed.entities.Count -eq 0) {
            throw "No entities found in YAML file"
        }

        # Find the DataPipeline entity (root of the pipeline hierarchy)
        # The deep graph export will automatically include child entities (MeshPipeline, EdgePipeline)
        # via the Parent-Child associations
        $totalEntities = $parsed.entities.Count

        # Find DataPipeline entity - it's the root that we export from
        $dataPipelineEntity = $parsed.entities | Where-Object {
            $_.ckTypeId -match 'DataPipeline'
        } | Select-Object -First 1

        if (-not $dataPipelineEntity) {
            throw "No DataPipeline entity found in YAML file"
        }

        $rtIds = @($dataPipelineEntity.rtId)
        $ckTypeId = $dataPipelineEntity.ckTypeId

        if (-not $rtIds[0]) {
            throw "DataPipeline entity has no rtId"
        }

        if (-not $ckTypeId) {
            throw "DataPipeline entity has no ckTypeId"
        }

        return @{
            Success       = $true
            RtIds         = $rtIds
            CkTypeId      = $ckTypeId
            TotalEntities = $totalEntities
            Parsed        = $parsed
        }
    }
    catch {
        return @{
            Success = $false
            Error   = $_.Exception.Message
        }
    }
}

function Export-PipelineFromTenant {
    <#
    .SYNOPSIS
        Exports a pipeline from the tenant using octo-cli and extracts the entities.yaml file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$RtIds,

        [Parameter(Mandatory = $true)]
        [string]$CkTypeId,

        [Parameter(Mandatory = $true)]
        [string]$ExportDir,

        [Parameter(Mandatory = $true)]
        [string]$PipelineName
    )

    # Create export directory if it doesn't exist
    if (-not (Test-Path $ExportDir)) {
        New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null
    }

    $zipFile = Join-Path $ExportDir "$PipelineName.zip"
    $extractDir = Join-Path $ExportDir $PipelineName

    # Remove old files if they exist
    if (Test-Path $zipFile) {
        Remove-Item $zipFile -Force
    }
    if (Test-Path $extractDir) {
        Remove-Item $extractDir -Recurse -Force
    }

    # Build the id arguments array (each rtId needs its own -id flag)
    $idArgs = @()
    foreach ($rtId in $RtIds) {
        $idArgs += "-id"
        $idArgs += $rtId
    }

    try {
        # Run octo-cli export command
        $exportOutput = & octo-cli -c ExportRtByDeepGraph -f $zipFile @idArgs -t $CkTypeId 2>&1

        if ($LASTEXITCODE -ne 0) {
            $outputString = $exportOutput -join "`n"
            return @{
                Success = $false
                Error   = "octo-cli export failed: $outputString"
            }
        }

        if (-not (Test-Path $zipFile)) {
            return @{
                Success = $false
                Error   = "Export completed but ZIP file not created"
            }
        }

        # Extract the ZIP file
        Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force

        # Find the RtEntities.yaml file (exported by octo-cli)
        $entitiesFile = Get-ChildItem -Path $extractDir -Filter "RtEntities.yaml" -Recurse | Select-Object -First 1

        if (-not $entitiesFile) {
            return @{
                Success = $false
                Error   = "RtEntities.yaml not found in exported archive"
            }
        }

        return @{
            Success      = $true
            EntitiesPath = $entitiesFile.FullName
            ExtractDir   = $extractDir
            ZipFile      = $zipFile
        }
    }
    catch {
        return @{
            Success = $false
            Error   = $_.Exception.Message
        }
    }
}

function Normalize-PipelineYaml {
    <#
    .SYNOPSIS
        Normalizes a pipeline YAML for deterministic comparison by sorting entities,
        stripping CK version suffixes, removing runtime-only fields, and ensuring
        consistent key ordering.

    .DESCRIPTION
        This function performs the following normalizations:
        - Sorts entities by rtId
        - Sorts attributes and associations within each entity
        - Strips CK version suffixes (-1, -2, etc.) from ckTypeId, attribute id, roleId, targetCkTypeId
        - Removes runtime metadata fields (rtCreationDateTime, rtChangedDateTime)
        - Filters out runtime-only attributes (DeploymentState, StatusMessage)
        - Rebuilds all objects with consistent key ordering for deterministic YAML output
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    # Runtime-only attribute IDs to exclude (base names without version suffix)
    $runtimeAttributeIds = @(
        'System.Communication/DeploymentState',
        'System.Communication/StatusMessage'
    )

    try {
        $content = Get-Content -Path $FilePath -Raw
        $parsed = $content | ConvertFrom-Yaml

        if ($parsed.entities) {
            # Sort entities by rtId and rebuild with consistent key order
            $normalizedEntities = @()

            foreach ($entity in ($parsed.entities | Sort-Object -Property { $_.rtId })) {
                # Strip version suffix from ckTypeId
                $ckTypeId = if ($entity.ckTypeId) {
                    $entity.ckTypeId -replace '-\d+$', ''
                } else { $null }

                # Process attributes: filter runtime-only and strip version suffixes
                $normalizedAttributes = @()
                if ($entity.attributes) {
                    $normalizedAttributes = @($entity.attributes | Where-Object {
                        $baseId = $_.id -replace '-\d+$', ''
                        $baseId -notin $runtimeAttributeIds
                    } | ForEach-Object {
                        # Rebuild attribute with consistent key order: id, value
                        $normalizedAttr = [ordered]@{}
                        if ($null -ne $_.value) {
                            $normalizedAttr['value'] = $_.value
                        }
                        if ($_.id) {
                            $normalizedAttr['id'] = $_.id -replace '-\d+$', ''
                        }
                        $normalizedAttr
                    } | Sort-Object -Property { $_.id })
                }

                # Process associations: strip version suffixes and rebuild with consistent key order
                $normalizedAssociations = @()
                if ($entity.associations) {
                    $normalizedAssociations = @($entity.associations | ForEach-Object {
                        # Rebuild association with consistent key order
                        $normalizedAssoc = [ordered]@{}
                        if ($_.targetCkTypeId) {
                            $normalizedAssoc['targetCkTypeId'] = $_.targetCkTypeId -replace '-\d+$', ''
                        }
                        if ($_.roleId) {
                            $normalizedAssoc['roleId'] = $_.roleId -replace '-\d+$', ''
                        }
                        if ($null -ne $_.attributes) {
                            $normalizedAssoc['attributes'] = $_.attributes
                        }
                        if ($_.targetRtId) {
                            $normalizedAssoc['targetRtId'] = $_.targetRtId
                        }
                        $normalizedAssoc
                    } | Sort-Object -Property { $_.roleId }, { $_.targetRtId })
                }

                # Rebuild entity with consistent key order: rtId, ckTypeId, attributes, associations
                $normalizedEntity = [ordered]@{
                    'rtId' = $entity.rtId
                }
                if ($ckTypeId) {
                    $normalizedEntity['ckTypeId'] = $ckTypeId
                }
                $normalizedEntity['attributes'] = $normalizedAttributes
                $normalizedEntity['associations'] = $normalizedAssociations

                $normalizedEntities += $normalizedEntity
            }

            $parsed.entities = $normalizedEntities
        }

        # Rebuild root object with consistent key order
        $normalizedRoot = [ordered]@{
            'entities' = $parsed.entities
        }
        if ($null -ne $parsed.dependencies) {
            $normalizedRoot['dependencies'] = $parsed.dependencies
        }
        if ($parsed.'$schema') {
            $normalizedRoot['$schema'] = $parsed.'$schema'
        }

        # Convert back to YAML and write to output
        $normalizedYaml = $normalizedRoot | ConvertTo-Yaml
        Set-Content -Path $OutputPath -Value $normalizedYaml -NoNewline

        return @{
            Success = $true
        }
    }
    catch {
        return @{
            Success = $false
            Error   = $_.Exception.Message
        }
    }
}

function Compare-PipelineFiles {
    <#
    .SYNOPSIS
        Compares two normalized pipeline YAML files using git diff.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalFile,

        [Parameter(Mandatory = $true)]
        [string]$TenantFile,

        [Parameter(Mandatory = $true)]
        [string]$TempDir
    )

    $localNormalized = Join-Path $TempDir "local-normalized.yaml"
    $tenantNormalized = Join-Path $TempDir "tenant-normalized.yaml"

    # Normalize both files
    $localResult = Normalize-PipelineYaml -FilePath $LocalFile -OutputPath $localNormalized
    if (-not $localResult.Success) {
        return @{
            Success = $false
            Error   = "Failed to normalize local file: $($localResult.Error)"
        }
    }

    $tenantResult = Normalize-PipelineYaml -FilePath $TenantFile -OutputPath $tenantNormalized
    if (-not $tenantResult.Success) {
        return @{
            Success = $false
            Error   = "Failed to normalize tenant file: $($tenantResult.Error)"
        }
    }

    # Run git diff
    $diffOutput = & git diff --no-index --color=always $localNormalized $tenantNormalized 2>&1
    $diffExitCode = $LASTEXITCODE

    # git diff returns 0 if files are identical, 1 if different
    $isIdentical = ($diffExitCode -eq 0)

    return @{
        Success    = $true
        IsIdentical = $isIdentical
        DiffOutput  = $diffOutput
    }
}

#endregion

#region Main Function

function Compare-Pipelines {
    <#
    .SYNOPSIS
        Compares local pipeline YAML files with their deployed versions in a remote OctoMesh tenant.
    #>
    [CmdletBinding()]
    param(
        [string]$TenantId = "maco",
        [string]$LocalPipelineDir = "./deployment/maco-deployment/data/pipelines",
        [string]$ExportDir = "./temp/pipeline-export",
        [string]$PipelineFile = "",
        [switch]$KeepExports,
        [switch]$Json
    )

    # Track results
    $results = @{
        Identical      = @()
        Modified       = @()
        MissingInTenant = @()
        Errors         = @()
    }

    Write-Host ""
    Write-Host "Pipeline Comparison Tool" -ForegroundColor Cyan
    Write-Host "========================" -ForegroundColor Cyan
    Write-Host "Tenant: $TenantId" -ForegroundColor Gray
    Write-Host ""

    # Phase 1: Test prerequisites
    Write-Host "Checking prerequisites..." -ForegroundColor Yellow
    $prereqResult = Test-Prerequisites
    if (-not $prereqResult.Success) {
        Write-Host ""
        Write-Host "Prerequisites not met:" -ForegroundColor Red
        foreach ($error in $prereqResult.Errors) {
            Write-Host "  - $error" -ForegroundColor Red
        }
        $global:LASTEXITCODE = 3
        return
    }
    Write-Host "  Prerequisites OK" -ForegroundColor Green
    Write-Host ""

    # Phase 2: Get pipeline files
    try {
        $pipelineFiles = Get-PipelineFiles -LocalPipelineDir $LocalPipelineDir -PipelineFile $PipelineFile
        Write-Host "Found $($pipelineFiles.Count) pipeline file(s) to compare" -ForegroundColor Gray
        Write-Host ""
    }
    catch {
        Write-Host "Error: $_" -ForegroundColor Red
        $global:LASTEXITCODE = 3
        return
    }

    # Create temp directory
    $tempDir = Join-Path $ExportDir "temp"
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }

    # Phase 3: Process each pipeline file
    foreach ($file in $pipelineFiles) {
        $fileName = $file.Name
        Write-Host "Comparing: $fileName" -ForegroundColor White

        # Get metadata from local file
        $metadata = Get-PipelineMetadata -FilePath $file.FullName
        if (-not $metadata.Success) {
            Write-Host "  Status: ERROR - $($metadata.Error)" -ForegroundColor Red
            $results.Errors += $fileName
            Write-Host ""
            continue
        }

        $localEntityCount = $metadata.TotalEntities
        Write-Host "  DataPipeline: $($metadata.RtIds[0]) ($($localEntityCount - 1) child entities in local file)" -ForegroundColor Gray

        # Export from tenant
        Write-Host "  Exporting from tenant..." -ForegroundColor Gray
        $pipelineName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $exportResult = Export-PipelineFromTenant -RtIds $metadata.RtIds -CkTypeId $metadata.CkTypeId -ExportDir $ExportDir -PipelineName $pipelineName

        if (-not $exportResult.Success) {
            if ($exportResult.Error -match "not found|does not exist|No entities") {
                Write-Host "  Status: MISSING IN TENANT" -ForegroundColor Yellow
                $results.MissingInTenant += $fileName
            }
            else {
                Write-Host "  Status: ERROR - $($exportResult.Error)" -ForegroundColor Red
                $results.Errors += $fileName
            }
            Write-Host ""
            continue
        }

        # Compare files
        $compareResult = Compare-PipelineFiles -LocalFile $file.FullName -TenantFile $exportResult.EntitiesPath -TempDir $tempDir

        if (-not $compareResult.Success) {
            Write-Host "  Status: ERROR - $($compareResult.Error)" -ForegroundColor Red
            $results.Errors += $fileName
            Write-Host ""
            continue
        }

        if ($compareResult.IsIdentical) {
            Write-Host "  Status: IDENTICAL" -ForegroundColor Green
            $results.Identical += $fileName
        }
        else {
            Write-Host "  Status: MODIFIED" -ForegroundColor Yellow
            $results.Modified += $fileName
            Write-Host ""
            # Show diff output
            $diffLines = $compareResult.DiffOutput -split "`n"
            foreach ($line in $diffLines) {
                Write-Host "  $line"
            }
        }
        Write-Host ""
    }

    # Phase 4: Display summary
    if (-not $Json) {
        Write-Host ""
        Write-Host "Pipeline Comparison Summary" -ForegroundColor Cyan
        Write-Host "===========================" -ForegroundColor Cyan
        Write-Host "Total files:    $($pipelineFiles.Count)"
        Write-Host "Identical:      $($results.Identical.Count) " -NoNewline
        Write-Host ([char]0x2713) -ForegroundColor Green
        Write-Host "Modified:       $($results.Modified.Count) " -NoNewline
        if ($results.Modified.Count -gt 0) { Write-Host ([char]0x26A0) -ForegroundColor Yellow } else { Write-Host "" }
        Write-Host "Missing:        $($results.MissingInTenant.Count) " -NoNewline
        if ($results.MissingInTenant.Count -gt 0) { Write-Host ([char]0x26A0) -ForegroundColor Yellow } else { Write-Host "" }
        Write-Host "Errors:         $($results.Errors.Count) " -NoNewline
        if ($results.Errors.Count -gt 0) { Write-Host ([char]0x2717) -ForegroundColor Red } else { Write-Host "" }

        if ($results.Modified.Count -gt 0) {
            Write-Host ""
            Write-Host "Modified files:" -ForegroundColor Yellow
            foreach ($f in $results.Modified) {
                Write-Host "  - $f" -ForegroundColor Yellow
            }
        }

        if ($results.MissingInTenant.Count -gt 0) {
            Write-Host ""
            Write-Host "Missing in tenant:" -ForegroundColor Yellow
            foreach ($f in $results.MissingInTenant) {
                Write-Host "  - $f" -ForegroundColor Yellow
            }
        }

        if ($results.Errors.Count -gt 0) {
            Write-Host ""
            Write-Host "Files with errors:" -ForegroundColor Red
            foreach ($f in $results.Errors) {
                Write-Host "  - $f" -ForegroundColor Red
            }
        }
    }

    # Phase 5: Cleanup
    if (-not $KeepExports) {
        if (-not $Json) {
            Write-Host ""
            Write-Host "Cleaning up temporary files..." -ForegroundColor Gray
        }
        if (Test-Path $ExportDir) {
            Remove-Item $ExportDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        if (-not $Json) {
            Write-Host ""
            Write-Host "Temporary files preserved in: $ExportDir" -ForegroundColor Gray
        }
    }

    # Phase 6: Determine exit code
    $exitCode = 0
    if ($results.Modified.Count -gt 0) {
        $exitCode = 1
    }
    elseif ($results.MissingInTenant.Count -gt 0) {
        $exitCode = 2
    }
    elseif ($results.Errors.Count -gt 0) {
        $exitCode = 3
    }

    if ($Json) {
        $payload = [ordered]@{
            identical       = @($results.Identical)
            modified        = @($results.Modified)
            missingInTenant = @($results.MissingInTenant)
            errors          = @($results.Errors)
            counts          = [ordered]@{
                identical       = $results.Identical.Count
                modified        = $results.Modified.Count
                missingInTenant = $results.MissingInTenant.Count
                errors          = $results.Errors.Count
            }
        }
        Write-OctoJson -Command 'Compare-Pipelines' -Data $payload
        $global:LASTEXITCODE = $exitCode
        return
    }

    Write-Host ""
    $global:LASTEXITCODE = $exitCode
    return $exitCode
}

#endregion

Export-ModuleMember -Function @('Compare-Pipelines')
