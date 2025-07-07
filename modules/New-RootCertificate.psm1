function New-RootCertificate {
    <#
    .SYNOPSIS
    Creates a root certificate for a Certificate Authority.
    
    .DESCRIPTION
    The New-RootCertificate function creates a self-signed root certificate that can be used as a Certificate Authority (CA) 
    to sign other certificates. It generates a private key, creates the root certificate, and outputs both individual files 
    and a combined PEM file. The certificate is created with proper CA extensions for Chrome compatibility.
    
    .PARAMETER CertificateName
    The name of the certificate. This will be used as the Common Name (CN) and as the base filename for all generated files.
    
    .PARAMETER ValidityDays
    The validity period of the certificate in days. Default is 3650 days (10 years), which is standard for root CA certificates.
    
    .PARAMETER OutputDirectory
    The directory where the certificate files will be created. Default is the current directory.
    
    .PARAMETER KeySize
    The RSA key size in bits. Default is 4096 bits for enhanced security on root certificates.
    
    .EXAMPLE
    New-RootCertificate -CertificateName "meshmakers-root-ca"
    
    Creates a root certificate named "meshmakers-root-ca" in the current directory with default settings.
    
    .EXAMPLE
    New-RootCertificate -CertificateName "meshmakers-root-ca" -OutputDirectory "./certs" -ValidityDays 7300
    
    Creates a root certificate with 20 years validity in the "./certs" directory.
    
    .EXAMPLE
    New-RootCertificate -CertificateName "test-ca" -KeySize 2048 -ValidityDays 1825
    
    Creates a root certificate with 2048-bit key and 5 years validity.
    
    .NOTES
    Prerequisites:
    - OpenSSL must be installed and available in PATH
    - Windows: https://slproweb.com/products/Win32OpenSSL.html
    - macOS: brew install openssl
    - Linux: apt-get install openssl or yum install openssl
    
    Output Files:
    - [CertificateName].key - Private key
    - [CertificateName].crt - Certificate
    - [CertificateName].pem - Combined private key and certificate
    
    The certificate is created with meshmakers.io organization details and Vienna, AT location.
    The root CA includes proper CA extensions for Chrome compatibility.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$CertificateName,
        
        [Parameter()]
        [int]$ValidityDays = 3650,  # 10 years standard for Root CA
        
        [Parameter()]
        [string]$OutputDirectory = ".",
        
        [Parameter()]
        [int]$KeySize = 4096
    )

    # Check if OpenSSL is available
    try {
        $null = Get-Command openssl -ErrorAction Stop
        Write-Host "OpenSSL found" -ForegroundColor Green
    }
    catch {
        Write-Error "OpenSSL is not installed or not in PATH. Please install OpenSSL first."
        return
    }

    # Create output directory if it doesn't exist
    $OutputDirectory = $(Resolve-Path -Path $OutputDirectory -ErrorAction SilentlyContinue).Path
    if (-not $OutputDirectory) {
        $OutputDirectory = $PWD.Path
    }
    
    if (!(Test-Path $OutputDirectory)) {
        New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
        Write-Host "Created output directory: $OutputDirectory" -ForegroundColor Yellow
    }

    $keyFile = Join-Path $OutputDirectory "$CertificateName.key"
    $certFile = Join-Path $OutputDirectory "$CertificateName.crt"
    $pemFile = Join-Path $OutputDirectory "$CertificateName.pem"
    $configFile = Join-Path $OutputDirectory "$CertificateName-ca.conf"

    Write-Host "Creating root certificate '$CertificateName' with validity of $ValidityDays days" -ForegroundColor Green
    Write-Host "Output directory: $OutputDirectory" -ForegroundColor Green

    # Create OpenSSL config for CA certificate
    Write-Host "Creating CA configuration..." -ForegroundColor Yellow
    $configContent = @"
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_ca
prompt = no

[req_distinguished_name]
C=AT
ST=Vienna
L=Vienna
O=meshmakers.io
OU=IT
CN=$CertificateName

[v3_ca]
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
"@
    $configContent | Out-File $configFile -Encoding ASCII

    # Generate Private Key
    Write-Host "Generating private key..." -ForegroundColor Yellow
    $genRsaResult = & openssl genrsa -out $keyFile $KeySize
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to generate private key"
        return
    }

    # Generate Root Certificate with CA extensions
    Write-Host "Creating root certificate with CA extensions..." -ForegroundColor Yellow
    $reqResult = & openssl req -new -x509 -key $keyFile -sha256 -days $ValidityDays -out $certFile -config $configFile -extensions v3_ca
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create root certificate"
        return
    }

    # Create PEM File (Key + Cert combined)
    Write-Host "Creating combined PEM file..." -ForegroundColor Yellow
    $keyContent = Get-Content $keyFile -Raw
    $certContent = Get-Content $certFile -Raw
    "$keyContent$certContent" | Out-File $pemFile -Encoding ASCII

    # Cleanup config file
    Remove-Item $configFile -Force -ErrorAction SilentlyContinue

    Write-Host "Root certificate created successfully!" -ForegroundColor Green
    Write-Host "Files created:" -ForegroundColor Green
    Write-Host "  Private Key: $keyFile" -ForegroundColor Cyan
    Write-Host "  Certificate: $certFile" -ForegroundColor Cyan
    Write-Host "  Combined PEM: $pemFile" -ForegroundColor Cyan
    
    # Show Certificate Info
    Write-Host "`nCertificate Information:" -ForegroundColor Yellow
    & openssl x509 -in $certFile -text -noout | Select-String "Subject:|Not Before|Not After|CA:TRUE|Key Usage"
}

Export-ModuleMember -Function @('New-RootCertificate')
