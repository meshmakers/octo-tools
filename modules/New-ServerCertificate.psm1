function New-ServerCertificate {
    <#
    .SYNOPSIS
    Creates a server certificate signed by a root certificate.
    
    .DESCRIPTION
    The New-ServerCertificate function creates a server certificate signed by an existing root CA certificate. 
    It supports multiple DNS names through Subject Alternative Names (SAN) extension, making it suitable for 
    server applications that need to be accessible via different hostnames. Creates Chrome-compatible certificates.
    
    .PARAMETER CertificateName
    The name of the server certificate. This will be used as the base filename for all generated files.
    
    .PARAMETER RootCertificatePath
    The path to the root CA certificate file (.crt) that will be used to sign this server certificate.
    
    .PARAMETER RootKeyPath
    The path to the root CA private key file (.key) that will be used to sign this server certificate.
    
    .PARAMETER DnsNames
    An array of DNS names that this certificate should be valid for. The first DNS name will be used as the 
    Common Name (CN). All DNS names will be included in the Subject Alternative Names (SAN) extension.
    
    .PARAMETER ValidityDays
    The validity period of the certificate in days. Default is 365 days (1 year), which is standard for server certificates.
    
    .PARAMETER OutputDirectory
    The directory where the certificate files will be created. Default is the current directory.
    
    .PARAMETER KeySize
    The RSA key size in bits. Default is 2048 bits, which is sufficient for server certificates.
    
    .EXAMPLE
    New-ServerCertificate -CertificateName "api-server" `
        -RootCertificatePath "./certs/meshmakers-root-ca.crt" `
        -RootKeyPath "./certs/meshmakers-root-ca.key" `
        -DnsNames @("api.meshmakers.io", "localhost")
    
    Creates a server certificate for API server with support for both api.meshmakers.io and localhost.
    
    .EXAMPLE
    New-ServerCertificate -CertificateName "web-server" `
        -RootCertificatePath "./certs/meshmakers-root-ca.crt" `
        -RootKeyPath "./certs/meshmakers-root-ca.key" `
        -DnsNames @("www.meshmakers.io", "meshmakers.io", "localhost", "127.0.0.1") `
        -OutputDirectory "./certs" `
        -ValidityDays 730
    
    Creates a web server certificate with 2 years validity supporting multiple domains and IP addresses.
    
    .EXAMPLE
    # Complete workflow: Create root CA and server certificate
    New-RootCertificate -CertificateName "meshmakers-root-ca" -OutputDirectory "./certs"
    New-ServerCertificate -CertificateName "api-server" `
        -RootCertificatePath "./certs/meshmakers-root-ca.crt" `
        -RootKeyPath "./certs/meshmakers-root-ca.key" `
        -DnsNames @("api.meshmakers.io", "localhost") `
        -OutputDirectory "./certs"
    
    Complete example showing how to create a root CA and then a server certificate.
    
    .NOTES
    Prerequisites:
    - OpenSSL must be installed and available in PATH
    - Root CA certificate and key files must exist and be properly configured as CA
    - Windows: https://slproweb.com/products/Win32OpenSSL.html
    - macOS: brew install openssl
    - Linux: apt-get install openssl or yum install openssl
    
    Output Files:
    - [CertificateName].key - Private key
    - [CertificateName].crt - Certificate
    - [CertificateName].pem - Combined private key and certificate
    
    The certificate includes Chrome-compatible extensions:
    - Subject Alternative Names (SAN) for all specified DNS names
    - Extended Key Usage for server authentication
    - Proper Key Usage for TLS server certificates
    - Basic Constraints marking it as non-CA certificate
    
    The function automatically verifies the certificate chain after creation.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$CertificateName,
        
        [Parameter(Mandatory = $true)]
        [string]$RootCertificatePath,
        
        [Parameter(Mandatory = $true)]
        [string]$RootKeyPath,
        
        [Parameter(Mandatory = $true)]
        [string[]]$DnsNames,
        
        [Parameter()]
        [int]$ValidityDays = 365,  # 1 year standard for Server Certs
        
        [Parameter()]
        [string]$OutputDirectory = ".",
        
        [Parameter()]
        [int]$KeySize = 2048
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

    # Check if Root Certificate and Key exist
    if (!(Test-Path $RootCertificatePath)) {
        Write-Error "Root certificate not found: $RootCertificatePath"
        return
    }
    if (!(Test-Path $RootKeyPath)) {
        Write-Error "Root key not found: $RootKeyPath"
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
    $csrFile = Join-Path $OutputDirectory "$CertificateName.csr"
    $certFile = Join-Path $OutputDirectory "$CertificateName.crt"
    $pemFile = Join-Path $OutputDirectory "$CertificateName.pem"
    $configFile = Join-Path $OutputDirectory "$CertificateName.conf"

    Write-Host "Creating server certificate '$CertificateName' signed by root CA" -ForegroundColor Green
    Write-Host "DNS Names: $($DnsNames -join ', ')" -ForegroundColor Green
    Write-Host "Validity: $ValidityDays days" -ForegroundColor Green
    Write-Host "Output directory: $OutputDirectory" -ForegroundColor Green

    # Create OpenSSL Config for Chrome-compatible server certificate
    Write-Host "Creating OpenSSL configuration..." -ForegroundColor Yellow
    $sanList = ($DnsNames | ForEach-Object { "DNS:$_" }) -join ","
    $configContent = @"
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C=AT
ST=Vienna
L=Vienna
O=meshmakers.io
OU=IT
CN=$($DnsNames[0])

[v3_req]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $sanList
subjectKeyIdentifier = hash

[v3_server]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $sanList
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
"@
    $configContent | Out-File $configFile -Encoding ASCII

    # Generate Private Key
    Write-Host "Generating private key..." -ForegroundColor Yellow
    $genRsaResult = & openssl genrsa -out $keyFile $KeySize
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to generate private key"
        return
    }

    # Create Certificate Signing Request (CSR)
    Write-Host "Creating certificate signing request..." -ForegroundColor Yellow
    $reqResult = & openssl req -new -key $keyFile -out $csrFile -config $configFile -extensions v3_req
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create CSR"
        return
    }

    # Sign Certificate with Root CA using proper server extensions
    Write-Host "Signing certificate with root CA..." -ForegroundColor Yellow
    $signResult = & openssl x509 -req -in $csrFile -CA $RootCertificatePath -CAkey $RootKeyPath -CAcreateserial -out $certFile -days $ValidityDays -extensions v3_server -extfile $configFile -sha256
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to sign certificate"
        return
    }

    # Create PEM File (Key + Cert combined)
    Write-Host "Creating combined PEM file..." -ForegroundColor Yellow
    $keyContent = Get-Content $keyFile -Raw
    $certContent = Get-Content $certFile -Raw
    "$keyContent$certContent" | Out-File $pemFile -Encoding ASCII

    # Cleanup temporary files
    Remove-Item $csrFile -Force -ErrorAction SilentlyContinue
    Remove-Item $configFile -Force -ErrorAction SilentlyContinue

    Write-Host "Server certificate created successfully!" -ForegroundColor Green
    Write-Host "Files created:" -ForegroundColor Green
    Write-Host "  Private Key: $keyFile" -ForegroundColor Cyan
    Write-Host "  Certificate: $certFile" -ForegroundColor Cyan
    Write-Host "  Combined PEM: $pemFile" -ForegroundColor Cyan
    
    # Show Certificate Info with Chrome-relevant details
    Write-Host "`nCertificate Information:" -ForegroundColor Yellow
    & openssl x509 -in $certFile -text -noout | Select-String "Subject:|Not Before|Not After|DNS:|CA:FALSE|Digital Signature|Key Encipherment|TLS Web Server"
    
    # Verify Certificate Chain
    Write-Host "`nVerifying certificate chain..." -ForegroundColor Yellow
    $verifyResult = & openssl verify -CAfile $RootCertificatePath $certFile
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Certificate chain verification: OK" -ForegroundColor Green
    } else {
        Write-Warning "Certificate chain verification failed"
    }

    # Additional Chrome compatibility check
    Write-Host "`nChrome Compatibility Check:" -ForegroundColor Yellow
    $certText = & openssl x509 -in $certFile -text -noout
    $hasDigitalSignature = $certText -match "Digital Signature"
    $hasKeyEncipherment = $certText -match "Key Encipherment"
    $hasServerAuth = $certText -match "TLS Web Server Authentication"
    $hasCAFalse = $certText -match "CA:FALSE"
    
    if ($hasDigitalSignature -and $hasKeyEncipherment -and $hasServerAuth -and $hasCAFalse) {
        Write-Host "✓ Certificate appears Chrome-compatible" -ForegroundColor Green
    } else {
        Write-Warning "⚠ Certificate may have compatibility issues with Chrome"
        if (-not $hasDigitalSignature) { Write-Warning "  Missing: Digital Signature" }
        if (-not $hasKeyEncipherment) { Write-Warning "  Missing: Key Encipherment" }
        if (-not $hasServerAuth) { Write-Warning "  Missing: Server Auth" }
        if (-not $hasCAFalse) { Write-Warning "  Missing: CA:FALSE" }
    }
}

Export-ModuleMember -Function @('New-ServerCertificate')
