@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'Update-OctoVersionAndBranches.psm1'
    
    # Version number of this module.
    ModuleVersion = '1.0.0'
    
    # ID used to uniquely identify this module
    GUID = 'c3d4e5f6-a7b8-9012-3456-789012cdef01'
    
    # Author of this module
    Author = 'meshmakers.io'
    
    # Company or vendor of this module
    CompanyName = 'meshmakers.io'
    
    # Copyright statement for this module
    Copyright = '(c) 2025 meshmakers.io. All rights reserved.'
    
    # Description of the functionality provided by this module
    Description = 'Updates OctoVersion and manages branches in all octo-* repositories including submodules'
    
    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '5.1'
    
    # Functions to export from this module
    FunctionsToExport = @('Update-OctoVersionAndBranches')
    
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
            Tags = @('OctoMesh', 'Version', 'Git', 'Build', 'Submodules')
            
            # A URL to the license for this module.
            LicenseUri = ''
            
            # A URL to the main website for this project.
            ProjectUri = 'https://www.meshmakers.io'
            
            # A URL to an icon representing this module.
            IconUri = ''
            
            # ReleaseNotes of this module
            ReleaseNotes = 'Version and branch management with submodule support'
        }
    }
}
