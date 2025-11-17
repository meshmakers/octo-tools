function New-AspNetDeveloperCertificate {
    <#
    .SYNOPSIS
    Creates an ASP.NET Core developer certificate with support for multiple hostnames (Cross-Platform).
    
    .DESCRIPTION
    The New-AspNetDeveloperCertificate function creates a self-signed developer certificate compatible with 
    ASP.NET Core applications on Windows, macOS, and Linux. It supports multiple DNS names including 
    localhost, custom domains, and machine-specific hostnames. 
    
    On macOS, it uses direct Keychain integration instead of dotnet dev-certs import due to compatibility issues.
    
    .PARAMETER CertificateName
    The name of the certificate. Default is "aspnetcore-dev".
    
    .PARAMETER DnsNames
    An array of DNS names that this certificate should be valid for. 
    Default includes "localhost" and machine-specific names based on OS.
    
    .PARAMETER IpAddresses
    An array of IP addresses that this certificate should be valid for.
    Default includes "127.0.0.1" and "::1" (IPv6 localhost).
    
    .PARAMETER ValidityDays
    The validity period of the certificate in days. Default is 825 days (max for browsers).
    
    .PARAMETER OutputDirectory
    The directory where the certificate files will be created. 
    Default is user's home directory under .aspnet/https.
    
    .PARAMETER KeySize
    The RSA key size in bits. Default is 2048 bits.
    
    .PARAMETER Password
    Optional password for the PFX file. If not provided, a random password will be generated.
    
    .PARAMETER TrustCertificate
    Automatically trust the certificate. Default is $true.
    On macOS, this directly imports to Keychain instead of using dotnet dev-certs.
    
    .PARAMETER UpdateHostsFile
    Automatically update hosts file to include custom domain entries. Default is $false.
    
    .PARAMETER CleanExisting
    Clean existing ASP.NET developer certificates before creating new one. Default is $true.
    
    .EXAMPLE
    New-AspNetDeveloperCertificate
    
    Creates a developer certificate with default settings.
    
    .EXAMPLE
    New-AspNetDeveloperCertificate -DnsNames @("localhost", "api.local", "*.app.local") -Password "SecurePass123!"
    
    Creates a certificate for multiple hostnames with a specific password.
    
    .EXAMPLE
    # macOS example with multiple hostnames
    New-AspNetDeveloperCertificate `
        -DnsNames @("localhost", "mac.local", "*.mac.local") `
        -UpdateHostsFile `
        -Password "MyPassword123"
    
    .NOTES
    Prerequisites:
    - .NET SDK installed (includes dotnet dev-certs tool)
    - OpenSSL installed:
      * Windows: winget install OpenSSL or https://slproweb.com/products/Win32OpenSSL.html
      * macOS: brew install openssl
      * Linux: apt-get install openssl or yum install openssl
    - Administrative privileges may be required for trusting certificates and updating hosts file
    
    Known Issues:
    - dotnet dev-certs import is broken on macOS with .NET 8+ due to EphemeralKeySet issue
    - On macOS, the script uses direct Keychain integration instead
    
    Output Files:
    - [CertificateName].key - Private key
    - [CertificateName].crt - Certificate
    - [CertificateName].pem - Combined certificate and key
    - [CertificateName].pfx - PKCS#12 format for ASP.NET Core
    - [CertificateName].p12 - Alternative PKCS#12 format (macOS)
    #>
    param(
        [Parameter()]
        [string]$CertificateName = "aspnetcore-dev",
        
        [Parameter()]
        [string[]]$DnsNames,
        
        [Parameter()]
        [string[]]$IpAddresses = @("127.0.0.1", "::1"),
        
        [Parameter()]
        [ValidateRange(1, 825)]
        [int]$ValidityDays = 825,  # Max validity for browser acceptance
        
        [Parameter()]
        [string]$OutputDirectory,
        
        [Parameter()]
        [ValidateSet(2048, 3072, 4096)]
        [int]$KeySize = 2048,
        
        [Parameter()]
        [string]$Password,
        
        [Parameter()]
        [bool]$TrustCertificate = $true,
        
        [Parameter()]
        [bool]$UpdateHostsFile = $false,
        
        [Parameter()]
        [bool]$CleanExisting = $true
    )

    # Detect Operating System
    $IsWindows = $PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows
    $IsMacOS = $PSVersionTable.OS -match "Darwin" -or $IsMacOS
    $IsLinux = $PSVersionTable.OS -match "Linux" -or $IsLinux
    
    if ($IsWindows) {
        $Platform = "Windows"
        $DefaultOutputDir = Join-Path $env:USERPROFILE ".aspnet\https"
        $HostsFile = "C:\Windows\System32\drivers\etc\hosts"
        $PathSeparator = "\"
    } elseif ($IsMacOS) {
        $Platform = "macOS"
        $DefaultOutputDir = Join-Path $HOME ".aspnet/https"
        $HostsFile = "/etc/hosts"
        $PathSeparator = "/"
    } else {
        $Platform = "Linux"
        $DefaultOutputDir = Join-Path $HOME ".aspnet/https"
        $HostsFile = "/etc/hosts"
        $PathSeparator = "/"
    }

    Write-Host "`n=====================================" -ForegroundColor Cyan
    Write-Host "ASP.NET Core Developer Certificate" -ForegroundColor Cyan
    Write-Host "Platform: $Platform" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan

    # Set default DNS names based on platform
    if (-not $DnsNames) {
        $DnsNames = @("localhost")
        if ($IsWindows) {
            $DnsNames += $env:COMPUTERNAME.ToLower() + ".local"
        } elseif ($IsMacOS) {
            $DnsNames += "mac.local", "*.mac.local"
        } else {
            $hostname = hostname
            if ($hostname) {
                $DnsNames += "$hostname.local"
            }
        }
    }

    # Check prerequisites
    Write-Host "`nChecking prerequisites..." -ForegroundColor Yellow
    
    # Check for dotnet CLI
    try {
        $dotnetVersion = & dotnet --version 2>$null
        if ($dotnetVersion) {
            Write-Host "✓ .NET SDK found: $dotnetVersion" -ForegroundColor Green
        } else {
            throw ".NET SDK not found"
        }
    }
    catch {
        Write-Error ".NET SDK is not installed. Please install from https://dotnet.microsoft.com/download"
        return
    }

    # Check for OpenSSL
    try {
        $opensslCmd = Get-Command openssl -ErrorAction Stop
        $opensslVersion = & openssl version 2>$null
        Write-Host "✓ OpenSSL found: $opensslVersion" -ForegroundColor Green
    }
    catch {
        Write-Error @"
OpenSSL is not installed or not in PATH. Please install:
  Windows: winget install OpenSSL or https://slproweb.com/products/Win32OpenSSL.html
  macOS:   brew install openssl
  Linux:   apt-get install openssl or yum install openssl
"@
        return
    }

    # Set output directory
    if ([string]::IsNullOrEmpty($OutputDirectory)) {
        $OutputDirectory = $DefaultOutputDir
    } else {
        # Expand path for cross-platform compatibility
        if ($OutputDirectory.StartsWith("~")) {
            $OutputDirectory = $OutputDirectory.Replace("~", $HOME)
        }
        $OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
    }

    # Create output directory if it doesn't exist
    if (!(Test-Path $OutputDirectory)) {
        New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
        Write-Host "✓ Created output directory: $OutputDirectory" -ForegroundColor Green
    }

    # Generate password if not provided
    if ([string]::IsNullOrEmpty($Password)) {
        # Generate a secure random password (no special chars for better compatibility)
        $chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
        $Password = -join ((1..16) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
        Write-Host "`nGenerated password: $Password" -ForegroundColor Yellow
        Write-Host "⚠ Save this password for your configuration!" -ForegroundColor Yellow
    }

    # Define file paths
    $keyFile = Join-Path $OutputDirectory "$CertificateName.key"
    $csrFile = Join-Path $OutputDirectory "$CertificateName.csr"
    $certFile = Join-Path $OutputDirectory "$CertificateName.crt"
    $pemFile = Join-Path $OutputDirectory "$CertificateName.pem"
    $pfxFile = Join-Path $OutputDirectory "$CertificateName.pfx"
    $p12File = Join-Path $OutputDirectory "$CertificateName.p12"
    $configFile = Join-Path $OutputDirectory "$CertificateName.conf"

    Write-Host "`nCertificate Configuration:" -ForegroundColor White
    Write-Host "  Name: $CertificateName" -ForegroundColor Gray
    Write-Host "  DNS Names: $($DnsNames -join ', ')" -ForegroundColor Gray
    Write-Host "  IP Addresses: $($IpAddresses -join ', ')" -ForegroundColor Gray
    Write-Host "  Validity: $ValidityDays days" -ForegroundColor Gray
    Write-Host "  Output: $OutputDirectory" -ForegroundColor Gray

    # Clean existing certificates if requested
    if ($CleanExisting) {
        Write-Host "`nCleaning existing developer certificates..." -ForegroundColor Yellow
        & dotnet dev-certs https --clean 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Existing certificates cleaned" -ForegroundColor Green
        }
    }

    # Create OpenSSL configuration
    Write-Host "`nCreating OpenSSL configuration..." -ForegroundColor Yellow
    
    # Build Subject Alternative Names section
    $altNames = @()
    for ($i = 0; $i -lt $DnsNames.Count; $i++) {
        $altNames += "DNS.$($i+1) = $($DnsNames[$i])"
    }
    for ($i = 0; $i -lt $IpAddresses.Count; $i++) {
        $altNames += "IP.$($i+1) = $($IpAddresses[$i])"
    }
    $altNamesSection = $altNames -join "`n"

    # Create config content with Windows/Unix line endings
    $newLine = if ($IsWindows) { "`r`n" } else { "`n" }
    $configContent = @"
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
ST = State
L = City
O = ASP.NET Core Development
OU = Development
CN = $($DnsNames[0])
emailAddress = developer@localhost

[v3_req]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
$altNamesSection

[v3_cert]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
"@
    $configContent = $configContent -replace "`r`n", $newLine
    Set-Content -Path $configFile -Value $configContent -NoNewline

    # Generate Private Key
    Write-Host "Generating RSA private key ($KeySize bits)..." -ForegroundColor Yellow
    $genKeyCmd = "openssl genrsa -out `"$keyFile`" $KeySize 2>&1"
    $genKeyResult = Invoke-Expression $genKeyCmd
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to generate private key: $genKeyResult"
        return
    }
    Write-Host "✓ Private key generated" -ForegroundColor Green

    # Create Certificate Signing Request
    Write-Host "Creating certificate signing request..." -ForegroundColor Yellow
    $csrCmd = "openssl req -new -key `"$keyFile`" -out `"$csrFile`" -config `"$configFile`" 2>&1"
    $csrResult = Invoke-Expression $csrCmd
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create CSR: $csrResult"
        return
    }
    Write-Host "✓ CSR created" -ForegroundColor Green

    # Create Self-Signed Certificate
    Write-Host "Creating self-signed certificate..." -ForegroundColor Yellow
    $certCmd = "openssl x509 -req -in `"$csrFile`" -signkey `"$keyFile`" -out `"$certFile`" -days $ValidityDays -extensions v3_cert -extfile `"$configFile`" -sha256 2>&1"
    $certResult = Invoke-Expression $certCmd
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create certificate: $certResult"
        return
    }
    Write-Host "✓ Certificate created" -ForegroundColor Green

    # Create PEM file (combined)
    Write-Host "Creating PEM bundle..." -ForegroundColor Yellow
    $keyContent = Get-Content $keyFile -Raw
    $certContent = Get-Content $certFile -Raw
    "$certContent$newLine$keyContent" | Set-Content -Path $pemFile -NoNewline
    Write-Host "✓ PEM bundle created" -ForegroundColor Green

    # Export as PFX/P12 with compatibility options
    Write-Host "Exporting as PFX/P12..." -ForegroundColor Yellow
    
    if ($IsMacOS) {
        # For macOS, create both PFX and P12 with maximum compatibility
        # Use legacy algorithms for better compatibility
        $p12Cmd = "openssl pkcs12 -export -legacy -out `"$p12File`" -inkey `"$keyFile`" -in `"$certFile`" -password `"pass:$Password`" -name `"$CertificateName`" 2>&1"
        $p12Result = Invoke-Expression $p12Cmd
        
        if ($LASTEXITCODE -ne 0) {
            # Try without -legacy flag for older OpenSSL versions
            $p12Cmd = "openssl pkcs12 -export -out `"$p12File`" -inkey `"$keyFile`" -in `"$certFile`" -password `"pass:$Password`" -name `"$CertificateName`" -macalg sha1 2>&1"
            $p12Result = Invoke-Expression $p12Cmd
        }
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ P12 file created for macOS" -ForegroundColor Green
            # Copy P12 to PFX for consistency
            Copy-Item $p12File $pfxFile -Force
        } else {
            Write-Warning "Failed to create P12 with legacy format, trying standard format"
            $pfxCmd = "openssl pkcs12 -export -out `"$pfxFile`" -inkey `"$keyFile`" -in `"$certFile`" -password `"pass:$Password`" 2>&1"
            $pfxResult = Invoke-Expression $pfxCmd
        }
    } else {
        # For Windows/Linux, create standard PFX
        $pfxCmd = "openssl pkcs12 -export -out `"$pfxFile`" -inkey `"$keyFile`" -in `"$certFile`" -password `"pass:$Password`" 2>&1"
        $pfxResult = Invoke-Expression $pfxCmd
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create PFX: $pfxResult"
            return
        }
    }
    
    Write-Host "✓ PFX file created" -ForegroundColor Green

    # Clean up temporary files
    Remove-Item $csrFile -Force -ErrorAction SilentlyContinue
    Remove-Item $configFile -Force -ErrorAction SilentlyContinue

    # Trust certificate - Platform specific
    if ($TrustCertificate) {
        if ($IsMacOS) {
            Write-Host "`n=====================================" -ForegroundColor Yellow
            Write-Host "macOS Certificate Trust Process" -ForegroundColor Yellow
            Write-Host "=====================================" -ForegroundColor Yellow
            
            # Method 1: Direct Keychain import
            Write-Host "Importing certificate to Keychain..." -ForegroundColor Yellow
            Write-Host "You will be prompted for your password" -ForegroundColor Yellow
            
            # Import the P12/PFX to login keychain
            $certToImport = if (Test-Path $p12File) { $p12File } else { $pfxFile }
            
            # First, import the certificate
            $importCmd = "security import `"$certToImport`" -k ~/Library/Keychains/login.keychain-db -P `"$Password`" -T /usr/bin/codesign -T /usr/bin/security 2>&1"
            Write-Host "Importing certificate..." -ForegroundColor Gray
            $importResult = Invoke-Expression $importCmd
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Certificate imported to Keychain" -ForegroundColor Green
                
                # Now trust the certificate
                Write-Host "Setting certificate trust..." -ForegroundColor Yellow
                
                # Add certificate to trusted certificates
                $trustCmd = "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain `"$certFile`" 2>&1"
                Write-Host "Setting trust (requires sudo)..." -ForegroundColor Gray
                $trustResult = Invoke-Expression $trustCmd
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✓ Certificate trusted in System Keychain" -ForegroundColor Green
                } else {
                    # Alternative: Add to login keychain
                    $trustCmd2 = "security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db `"$certFile`" 2>&1"
                    $trustResult2 = Invoke-Expression $trustCmd2
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "✓ Certificate trusted in Login Keychain" -ForegroundColor Green
                    } else {
                        Write-Host "`n⚠ Automatic trust failed. Please trust manually:" -ForegroundColor Yellow
                        Write-Host @"
                        
Manual Trust Instructions:
1. Open Keychain Access (Cmd+Space, type "Keychain Access")
2. Select 'login' keychain on the left
3. Select 'Certificates' category
4. Find '$CertificateName' certificate
5. Double-click the certificate
6. Expand the 'Trust' section
7. Set 'When using this certificate' to 'Always Trust'
8. Close the window and enter your password when prompted
"@ -ForegroundColor Cyan
                    }
                }
            } else {
                Write-Warning "Failed to import certificate automatically"
                Write-Host "Error: $importResult" -ForegroundColor Red
                
                Write-Host "`nManual import instructions:" -ForegroundColor Yellow
                Write-Host "1. Double-click: $certToImport" -ForegroundColor Cyan
                Write-Host "2. Enter password: $Password" -ForegroundColor Cyan
                Write-Host "3. Choose 'login' keychain" -ForegroundColor Cyan
                Write-Host "4. Click 'Add'" -ForegroundColor Cyan
                Write-Host "5. Open Keychain Access and trust the certificate" -ForegroundColor Cyan
            }
            
            # For localhost support, also create/trust with dotnet dev-certs
            if ($DnsNames -contains "localhost") {
                Write-Host "`nEnsuring localhost support with dotnet dev-certs..." -ForegroundColor Yellow
                $tempPfx = Join-Path $OutputDirectory "temp-localhost.pfx"
                & dotnet dev-certs https -ep "$tempPfx" -p "$Password" --trust 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✓ localhost certificate trusted via dotnet dev-certs" -ForegroundColor Green
                }
                Remove-Item $tempPfx -Force -ErrorAction SilentlyContinue
            }
            
        } elseif ($IsWindows) {
            Write-Host "`nTrusting certificate on Windows..." -ForegroundColor Yellow
            
            # Try dotnet dev-certs import for Windows (usually works)
            $importCmd = "dotnet dev-certs https --clean --import `"$pfxFile`" -p `"$Password`""
            Write-Host "Importing with dotnet dev-certs..." -ForegroundColor Gray
            $importResult = Invoke-Expression $importCmd 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Certificate imported and trusted" -ForegroundColor Green
            } else {
                # Fallback to certutil
                Write-Host "Using certutil as fallback..." -ForegroundColor Yellow
                $certUtilCmd = "certutil -f -user -p `"$Password`" -importpfx `"$pfxFile`" 2>&1"
                $certUtilResult = Invoke-Expression $certUtilCmd
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✓ Certificate imported to Windows Certificate Store" -ForegroundColor Green
                } else {
                    Write-Warning "Failed to import certificate. Run as Administrator or import manually."
                }
            }
        } else {
            # Linux
            Write-Host "`nTrusting certificate on Linux..." -ForegroundColor Yellow
            
            # Try dotnet dev-certs import (might work on some Linux distros)
            $importCmd = "dotnet dev-certs https --clean --import `"$pfxFile`" -p `"$Password`" 2>&1"
            $importResult = Invoke-Expression $importCmd
            
            if ($LASTEXITCODE -ne 0) {
                # Fallback to system certificate store
                Write-Host "Adding to system certificate store..." -ForegroundColor Yellow
                
                if (Test-Path "/usr/local/share/ca-certificates") {
                    $copyCmd = "sudo cp `"$certFile`" /usr/local/share/ca-certificates/$CertificateName.crt"
                    Invoke-Expression $copyCmd
                    & sudo update-ca-certificates
                } elseif (Test-Path "/etc/pki/ca-trust/source/anchors") {
                    $copyCmd = "sudo cp `"$certFile`" /etc/pki/ca-trust/source/anchors/$CertificateName.crt"
                    Invoke-Expression $copyCmd
                    & sudo update-ca-trust
                }
            }
        }
    }

    # Update hosts file if requested
    if ($UpdateHostsFile) {
        Write-Host "`nUpdating hosts file..." -ForegroundColor Yellow
        $hostsToAdd = $DnsNames | Where-Object { 
            $_ -ne "localhost" -and 
            $_ -notmatch "\*" -and 
            $_ -ne "127.0.0.1" -and 
            $_ -ne "::1" 
        }
        
        if ($hostsToAdd.Count -gt 0) {
            Write-Host "Adding entries for: $($hostsToAdd -join ', ')" -ForegroundColor Yellow
            
            foreach ($hostname in $hostsToAdd) {
                if ($IsWindows) {
                    $hostsContent = Get-Content $HostsFile -ErrorAction SilentlyContinue
                    if ($hostsContent -notmatch "127\.0\.0\.1\s+$hostname") {
                        try {
                            Add-Content -Path $HostsFile -Value "127.0.0.1       $hostname" -ErrorAction Stop
                            Write-Host "✓ Added: 127.0.0.1 $hostname" -ForegroundColor Green
                        } catch {
                            Write-Warning "Failed to update hosts file. Run as Administrator or add manually:"
                            Write-Host "  127.0.0.1       $hostname" -ForegroundColor Yellow
                        }
                    }
                } else {
                    $checkCmd = "grep -q '127.0.0.1.*$hostname' $HostsFile 2>/dev/null"
                    Invoke-Expression $checkCmd
                    if ($LASTEXITCODE -ne 0) {
                        $addCmd = "echo '127.0.0.1       $hostname' | sudo tee -a $HostsFile > /dev/null"
                        Invoke-Expression $addCmd
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "✓ Added: 127.0.0.1 $hostname" -ForegroundColor Green
                        }
                    } else {
                        Write-Host "  Entry already exists for $hostname" -ForegroundColor Gray
                    }
                }
            }
        }
    }

    # Display summary
    Write-Host "`n=====================================" -ForegroundColor Green
    Write-Host "Certificate created successfully!" -ForegroundColor Green
    Write-Host "=====================================" -ForegroundColor Green
    
    Write-Host "`nGenerated files:" -ForegroundColor Cyan
    Write-Host "  Private Key:  $keyFile" -ForegroundColor White
    Write-Host "  Certificate:  $certFile" -ForegroundColor White
    Write-Host "  PEM Bundle:   $pemFile" -ForegroundColor White
    Write-Host "  PFX File:     $pfxFile" -ForegroundColor White
    if ($IsMacOS -and (Test-Path $p12File)) {
        Write-Host "  P12 File:     $p12File" -ForegroundColor White
    }
    Write-Host "  Password:     $Password" -ForegroundColor Yellow

    # Show certificate details
    Write-Host "`nCertificate Details:" -ForegroundColor Cyan
    $certInfoCmd = "openssl x509 -in `"$certFile`" -text -noout 2>&1"
    $certInfo = Invoke-Expression $certInfoCmd
    $certInfo | Select-String "Subject:|Issuer:|Not Before|Not After|DNS:|IP Address:" | ForEach-Object {
        Write-Host "  $_" -ForegroundColor Gray
    }

    # Configuration examples
    Write-Host "`n=====================================" -ForegroundColor Blue
    Write-Host "Configuration Examples" -ForegroundColor Blue
    Write-Host "=====================================" -ForegroundColor Blue
    
    Write-Host "`n1. Environment Variables:" -ForegroundColor Yellow
    if ($IsWindows) {
        Write-Host @"
  set ASPNETCORE_Kestrel__Certificates__Default__Path=$pfxFile
  set ASPNETCORE_Kestrel__Certificates__Default__Password=$Password
  set ASPNETCORE_URLS=https://localhost:5001
"@ -ForegroundColor Gray
    } else {
        Write-Host @"
  export ASPNETCORE_Kestrel__Certificates__Default__Path='$pfxFile'
  export ASPNETCORE_Kestrel__Certificates__Default__Password='$Password'
  export ASPNETCORE_URLS='https://localhost:5001'
"@ -ForegroundColor Gray
    }

    Write-Host "`n2. appsettings.Development.json:" -ForegroundColor Yellow
    $jsonPath = $pfxFile -replace '\\', '\\'
    Write-Host @"
  {
    "Kestrel": {
      "Endpoints": {
        "Https": {
          "Url": "https://*:5001",
          "Certificate": {
            "Path": "$jsonPath",
            "Password": "$Password"
          }
        }
      }
    }
  }
"@ -ForegroundColor Gray

    Write-Host "`n3. User Secrets (Recommended):" -ForegroundColor Yellow
    Write-Host @"
  dotnet user-secrets init
  dotnet user-secrets set "Kestrel:Certificates:Development:Path" "$pfxFile"
  dotnet user-secrets set "Kestrel:Certificates:Development:Password" "$Password"
"@ -ForegroundColor Gray

    # Testing instructions
    Write-Host "`n=====================================" -ForegroundColor Magenta
    Write-Host "Testing Your Certificate" -ForegroundColor Magenta
    Write-Host "=====================================" -ForegroundColor Magenta
    
    Write-Host "`nTest with:" -ForegroundColor Yellow
    Write-Host "  dotnet run" -ForegroundColor Gray
    Write-Host "`nThen visit:" -ForegroundColor Yellow
    foreach ($dns in $DnsNames | Where-Object { $_ -notmatch "\*" }) {
        Write-Host "  https://$dns`:5001" -ForegroundColor Gray
    }

    if ($IsMacOS) {
        Write-Host "`n=====================================" -ForegroundColor Yellow
        Write-Host "macOS Specific Notes" -ForegroundColor Yellow
        Write-Host "=====================================" -ForegroundColor Yellow
        Write-Host @"
Due to a known issue with dotnet dev-certs on macOS (.NET 8+),
the certificate has been directly imported to Keychain instead.

If you see certificate warnings in your browser:
1. Open Keychain Access
2. Find '$CertificateName' in the 'login' keychain
3. Double-click and set Trust to 'Always Trust'
4. Restart your browser

The certificate will work with Kestrel using the configuration above.
"@ -ForegroundColor Cyan
    }

    Write-Host "`n✅ Setup complete!" -ForegroundColor Green
}

function Remove-AspNetDeveloperCertificate {
    <#
    .SYNOPSIS
    Removes ASP.NET Core developer certificates (Cross-Platform).
    
    .DESCRIPTION
    Cleans up developer certificates from the file system and certificate stores.
    
    .PARAMETER CertificateName
    The name of the certificate to remove. Default is "aspnetcore-dev".
    
    .PARAMETER Directory
    The directory containing the certificate files.
    
    .PARAMETER CleanTrusted
    Also remove trusted certificates using dotnet dev-certs. Default is $true.
    
    .EXAMPLE
    Remove-AspNetDeveloperCertificate
    
    Removes the default developer certificate.
    
    .EXAMPLE
    Remove-AspNetDeveloperCertificate -CertificateName "my-app" -Directory "C:\Certs"
    
    Removes a specific certificate from a custom directory.
    #>
    param(
        [Parameter()]
        [string]$CertificateName = "aspnetcore-dev",
        
        [Parameter()]
        [string]$Directory,
        
        [Parameter()]
        [bool]$CleanTrusted = $true
    )

    # Detect OS and set default directory
    $IsWindows = $PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows
    $IsMacOS = $PSVersionTable.OS -match "Darwin" -or $IsMacOS
    
    if ([string]::IsNullOrEmpty($Directory)) {
        if ($IsWindows) {
            $Directory = Join-Path $env:USERPROFILE ".aspnet\https"
        } else {
            $Directory = Join-Path $HOME ".aspnet/https"
        }
    }
    
    # Expand path
    if ($Directory.StartsWith("~")) {
        $Directory = $Directory.Replace("~", $HOME)
    }
    $Directory = [System.IO.Path]::GetFullPath($Directory)
    
    Write-Host "`nRemoving certificate: $CertificateName" -ForegroundColor Yellow
    Write-Host "Directory: $Directory" -ForegroundColor Gray
    
    # Remove certificate files
    $extensions = @(".key", ".crt", ".pem", ".pfx", ".p12", ".csr", ".conf")
    $removedCount = 0
    
    foreach ($ext in $extensions) {
        $file = Join-Path $Directory "$CertificateName$ext"
        if (Test-Path $file) {
            Remove-Item $file -Force
            Write-Host "✓ Removed: $file" -ForegroundColor Green
            $removedCount++
        }
    }
    
    if ($removedCount -eq 0) {
        Write-Host "No certificate files found to remove" -ForegroundColor Yellow
    }
    
    # Clean trusted certificates
    if ($CleanTrusted) {
        Write-Host "`nCleaning trusted certificates..." -ForegroundColor Yellow
        & dotnet dev-certs https --clean 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Trusted certificates cleaned" -ForegroundColor Green
        }
        
        # macOS specific cleanup
        if ($IsMacOS) {
            Write-Host "Removing from macOS Keychain..." -ForegroundColor Yellow
            # Try to delete from keychain
            $deleteCmd = "security delete-certificate -c `"$CertificateName`" 2>&1"
            $deleteResult = Invoke-Expression $deleteCmd
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Removed from Keychain" -ForegroundColor Green
            }
        }
    }
    
    Write-Host "`n✅ Cleanup complete!" -ForegroundColor Green
}

function Test-AspNetDeveloperCertificate {
    <#
    .SYNOPSIS
    Tests an ASP.NET Core developer certificate (Cross-Platform).
    
    .DESCRIPTION
    Verifies that a developer certificate is properly configured and trusted.
    
    .PARAMETER CertificatePath
    Path to the certificate file to test.
    
    .PARAMETER PfxPath
    Path to the PFX file to test.
    
    .PARAMETER Password
    Password for the PFX file.
    
    .PARAMETER TestUrl
    URL to test. Default is "https://localhost:5001".
    
    .EXAMPLE
    Test-AspNetDeveloperCertificate -PfxPath "~/.aspnet/https/aspnetcore-dev.pfx" -Password "MyPassword"
    
    Tests a PFX certificate file.
    
    .EXAMPLE
    Test-AspNetDeveloperCertificate -TestUrl "https://myapp.local:5001"
    
    Tests a running ASP.NET Core application.
    #>
    param(
        [Parameter()]
        [string]$CertificatePath,
        
        [Parameter()]
        [string]$PfxPath,
        
        [Parameter()]
        [string]$Password,
        
        [Parameter()]
        [string]$TestUrl = "https://localhost:5001"
    )

    $IsMacOS = $PSVersionTable.OS -match "Darwin" -or $IsMacOS

    Write-Host "`n=====================================" -ForegroundColor Cyan
    Write-Host "Testing ASP.NET Developer Certificate" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    
    # Test certificate file if provided
    if ($CertificatePath -or $PfxPath) {
        $testPath = if ($PfxPath) { $PfxPath } else { $CertificatePath }
        
        # Expand path
        if ($testPath.StartsWith("~")) {
            $testPath = $testPath.Replace("~", $HOME)
        }
        $testPath = [System.IO.Path]::GetFullPath($testPath)
        
        if (Test-Path $testPath) {
            Write-Host "`nCertificate file: $testPath" -ForegroundColor Yellow
            
            if ($PfxPath -and $Password) {
                # Test PFX file
                $pfxInfoCmd = "openssl pkcs12 -in `"$testPath`" -passin `"pass:$Password`" -info -nokeys 2>&1"
                $pfxInfo = Invoke-Expression $pfxInfoCmd
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✓ PFX file is valid" -ForegroundColor Green
                    
                    # Extract and display certificate info
                    $certInfoCmd = "openssl pkcs12 -in `"$testPath`" -passin `"pass:$Password`" -nokeys 2>/dev/null | openssl x509 -text -noout"
                    $certInfo = Invoke-Expression $certInfoCmd
                    
                    $certInfo | Select-String "Subject:|Not After|DNS:" | ForEach-Object {
                        Write-Host "  $_" -ForegroundColor Gray
                    }
                } else {
                    Write-Error "Failed to read PFX file. Check the password."
                }
            } elseif ($CertificatePath) {
                # Test CRT file
                $certInfoCmd = "openssl x509 -in `"$testPath`" -text -noout"
                $certInfo = Invoke-Expression $certInfoCmd 2>&1
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✓ Certificate file is valid" -ForegroundColor Green
                    
                    $certInfo | Select-String "Subject:|Not After|DNS:" | ForEach-Object {
                        Write-Host "  $_" -ForegroundColor Gray
                    }
                    
                    # Check expiration
                    $checkCmd = "openssl x509 -in `"$testPath`" -noout -checkend 86400"
                    Invoke-Expression $checkCmd 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "✓ Certificate is valid for at least 24 hours" -ForegroundColor Green
                    } else {
                        Write-Warning "⚠ Certificate expires within 24 hours"
                    }
                } else {
                    Write-Error "Invalid certificate file"
                }
            }
        } else {
            Write-Error "Certificate file not found: $testPath"
        }
    }
    
    # Check dotnet dev-certs status (might not work correctly on macOS)
    if (-not $IsMacOS) {
        Write-Host "`nChecking dotnet dev-certs status..." -ForegroundColor Yellow
        $checkResult = & dotnet dev-certs https --check --trust 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ A trusted developer certificate is installed" -ForegroundColor Green
        } else {
            Write-Warning "⚠ No trusted developer certificate found via dotnet dev-certs"
        }
    } else {
        Write-Host "`nChecking Keychain for certificates..." -ForegroundColor Yellow
        $keychainCheck = & security find-certificate -c "localhost" ~/Library/Keychains/login.keychain-db 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Found certificate in Keychain" -ForegroundColor Green
        } else {
            Write-Warning "⚠ No certificate found in Keychain"
        }
    }
    
    # Test HTTPS connection
    Write-Host "`nTesting HTTPS connection to $TestUrl..." -ForegroundColor Yellow
    
    try {
        $response = Invoke-WebRequest -Uri $TestUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-Host "✓ HTTPS connection successful" -ForegroundColor Green
        Write-Host "  Status: $($response.StatusCode)" -ForegroundColor Gray
    } catch {
        if ($_.Exception.Message -match "Connection refused" -or $_.Exception.Message -match "Unable to connect") {
            Write-Warning "No application running on $TestUrl"
            Write-Host "  Start your ASP.NET Core application: dotnet run" -ForegroundColor Yellow
        } elseif ($_.Exception.Message -match "certificate") {
            Write-Warning "Certificate issue detected"
            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
            if ($IsMacOS) {
                Write-Host "  Try trusting the certificate in Keychain Access" -ForegroundColor Yellow
            } else {
                Write-Host "  Try trusting the certificate: dotnet dev-certs https --trust" -ForegroundColor Yellow
            }
        } else {
            Write-Warning "Connection failed"
            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    Write-Host "`n✅ Test complete!" -ForegroundColor Green
}

# Export all functions
Export-ModuleMember -Function @(
    'New-AspNetDeveloperCertificate',
    'Remove-AspNetDeveloperCertificate', 
    'Test-AspNetDeveloperCertificate'
)
