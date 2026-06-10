<#
.SYNOPSIS
    Smoke-test the M1 operational unification: both Octo encryption env vars
    are set and carry byte-identical values, so cross-service ciphertext round-trips.

.DESCRIPTION
    Per implementation-m1.md §3.5: OCTO_AIENCRYPTION__INSTANCESECRETKEY and
    OCTO_COMMUNICATIONCONTROLLER__INSTANCESECRETKEY must be set to the same
    base64-encoded 32-byte AES-256 key value. With both services delegating
    their crypto to Meshmakers.Octo.Sdk.Common.Encryption.InstanceSecretCrypto
    and holding the same key, either service can decrypt ciphertext written
    by the other.

    Run after Start-Octo to verify the dev env is properly configured. For
    the actual cross-replica wire-format round-trip, the canonical proof is
    InstanceSecretCryptoTests.CrossReplicaRoundTrip_TwoServiceInstancesWithSameKey_DecryptEachOther
    in octo-sdk/tests/Sdk.Common.Tests/Encryption.

.EXAMPLE
    Test-OctoEncryption
#>
function Test-OctoEncryption {
    [CmdletBinding()]
    param()

    $ai = $env:OCTO_AIENCRYPTION__INSTANCESECRETKEY
    $cc = $env:OCTO_COMMUNICATIONCONTROLLER__INSTANCESECRETKEY

    if ([string]::IsNullOrEmpty($ai)) {
        Write-Host "FAIL  OCTO_AIENCRYPTION__INSTANCESECRETKEY is not set. Run Start-Octo first." -ForegroundColor Red
        return $false
    }
    if ([string]::IsNullOrEmpty($cc)) {
        Write-Host "FAIL  OCTO_COMMUNICATIONCONTROLLER__INSTANCESECRETKEY is not set. Run Start-Octo first." -ForegroundColor Red
        return $false
    }
    if ($ai -ne $cc) {
        Write-Host "FAIL  Env vars hold DIFFERENT values — cross-service decrypt will fail." -ForegroundColor Red
        Write-Host "  AI:  $($ai.Substring(0, [Math]::Min(16, $ai.Length)))..."
        Write-Host "  CC:  $($cc.Substring(0, [Math]::Min(16, $cc.Length)))..."
        return $false
    }

    try {
        $bytes = [Convert]::FromBase64String($ai)
    } catch {
        Write-Host "FAIL  Env var value is not valid base64." -ForegroundColor Red
        return $false
    }
    if ($bytes.Length -ne 32) {
        Write-Host "FAIL  Decoded key is $($bytes.Length) bytes; AES-256 requires 32." -ForegroundColor Red
        return $false
    }

    Write-Host "PASS  Both env vars set, byte-identical, decoded length 32. Cross-service decrypt will work." -ForegroundColor Green
    Write-Host "  Key (truncated): $($ai.Substring(0, 16))..."
    Write-Host ""
    Write-Host "Run the canonical cross-replica wire-format round-trip test:" -ForegroundColor DarkGray
    Write-Host "  cd /Users/gerald/RiderProjects/meshmakers/main/octo-sdk" -ForegroundColor DarkGray
    Write-Host "  dotnet test tests/Sdk.Common.Tests/Sdk.Common.Tests.csproj --filter `"FullyQualifiedName~CrossReplicaRoundTrip`"" -ForegroundColor DarkGray
    return $true
}

Export-ModuleMember -Function Test-OctoEncryption
