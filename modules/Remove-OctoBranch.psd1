@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'Remove-OctoBranch.psm1'
    
    # Version number of this module.
    ModuleVersion = '1.0.0'
    
    # ID used to uniquely identify this module
    GUID = 'b2c3d4e5-f6a7-8901-2345-678901bcdef0'
    
    # Author of this module
    Author = 'meshmakers.io'
    
    # Company or vendor of this module
    CompanyName = 'meshmakers.io'
    
    # Copyright statement for this module
    Copyright = '(c) 2025 meshmakers.io. All rights reserved.'
    
    # Description of the functionality provided by this module
    Description = 'Removes branches from all octo-* repositories and switches back to main'
    
    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '5.1'
    
    # Functions to export from this module
    FunctionsToExport = @('Remove-OctoBranch')
    
    # Cmdlets to export from this module
    CmdletsToExport = @()
    
    # Variables to export from this module
    VariablesToExport = @()
    
    # Aliases to export from this module
    AliasesToExport = @()
    
    # Private data to pass to the module specified in RootModule/ModuleToProcess
    PrivateData = @{
        PSData = @{
            # Tags applied to this module. These help with module discovery in online galleries.
            Tags = @('OctoMesh', 'Git', 'Branch', 'Cleanup')
            
            # A URL to the license for this module.
            LicenseUri = ''
            
            # A URL to the main website for this project.
            ProjectUri = 'https://www.meshmakers.io'
            
            # A URL to an icon representing this module.
            IconUri = ''
            
            # ReleaseNotes of this module
            ReleaseNotes = 'Initial release of Remove-OctoBranch module'
        }
    }
}
