<#
.SYNOPSIS
    Smoke-test the M1 operational unification: both Octo encryption env vars
    are set and carry byte-identical values, so cross-service ciphertext round-trips.
    Also checks the SECRET attribute key ring (AB#5536): OCTO_SECRETENCRYPTION__KEYS__k1
    equals the instance key, OCTO_SECRETENCRYPTION__ACTIVEKEYID names a present key and
    OCTO_SECRETENCRYPTION__LEGACYV1KEY equals the instance key.

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
    param([switch]$Json)

    $ai = $env:OCTO_AIENCRYPTION__INSTANCESECRETKEY
    $cc = $env:OCTO_COMMUNICATIONCONTROLLER__INSTANCESECRETKEY

    $aiKeySet = -not [string]::IsNullOrEmpty($ai)
    $ccKeySet = -not [string]::IsNullOrEmpty($cc)

    if (-not $aiKeySet) {
        if ($Json) {
            Write-OctoJson -Command 'Test-OctoEncryption' -Data ([ordered]@{
                passed      = $false
                aiKeySet    = $false
                ccKeySet    = [bool]$ccKeySet
                keysMatch   = $false
                validBase64 = $false
                keyLength   = [int]0
                message     = 'OCTO_AIENCRYPTION__INSTANCESECRETKEY is not set. Run Start-Octo first.'
            })
            return
        }
        Write-Host "FAIL  OCTO_AIENCRYPTION__INSTANCESECRETKEY is not set. Run Start-Octo first." -ForegroundColor Red
        return $false
    }
    if (-not $ccKeySet) {
        if ($Json) {
            Write-OctoJson -Command 'Test-OctoEncryption' -Data ([ordered]@{
                passed      = $false
                aiKeySet    = $true
                ccKeySet    = $false
                keysMatch   = $false
                validBase64 = $false
                keyLength   = [int]0
                message     = 'OCTO_COMMUNICATIONCONTROLLER__INSTANCESECRETKEY is not set. Run Start-Octo first.'
            })
            return
        }
        Write-Host "FAIL  OCTO_COMMUNICATIONCONTROLLER__INSTANCESECRETKEY is not set. Run Start-Octo first." -ForegroundColor Red
        return $false
    }
    if ($ai -ne $cc) {
        if ($Json) {
            Write-OctoJson -Command 'Test-OctoEncryption' -Data ([ordered]@{
                passed      = $false
                aiKeySet    = $true
                ccKeySet    = $true
                keysMatch   = $false
                validBase64 = $false
                keyLength   = [int]0
                message     = 'Env vars hold DIFFERENT values - cross-service decrypt will fail.'
            })
            return
        }
        Write-Host "FAIL  Env vars hold DIFFERENT values — cross-service decrypt will fail." -ForegroundColor Red
        Write-Host "  AI:  $($ai.Substring(0, [Math]::Min(16, $ai.Length)))..."
        Write-Host "  CC:  $($cc.Substring(0, [Math]::Min(16, $cc.Length)))..."
        return $false
    }

    try {
        $bytes = [Convert]::FromBase64String($ai)
    } catch {
        if ($Json) {
            Write-OctoJson -Command 'Test-OctoEncryption' -Data ([ordered]@{
                passed      = $false
                aiKeySet    = $true
                ccKeySet    = $true
                keysMatch   = $true
                validBase64 = $false
                keyLength   = [int]0
                message     = 'Env var value is not valid base64.'
            })
            return
        }
        Write-Host "FAIL  Env var value is not valid base64." -ForegroundColor Red
        return $false
    }
    if ($bytes.Length -ne 32) {
        if ($Json) {
            Write-OctoJson -Command 'Test-OctoEncryption' -Data ([ordered]@{
                passed      = $false
                aiKeySet    = $true
                ccKeySet    = $true
                keysMatch   = $true
                validBase64 = $true
                keyLength   = [int]$bytes.Length
                message     = "Decoded key is $($bytes.Length) bytes; AES-256 requires 32."
            })
            return
        }
        Write-Host "FAIL  Decoded key is $($bytes.Length) bytes; AES-256 requires 32." -ForegroundColor Red
        return $false
    }

    # SECRET attribute key ring (AB#5536, concept AB#5528 decision 3): k1 must be present,
    # be the instance key, be (or another present key must be) the active key, and the
    # legacy enc:v1 key must be the instance key too. Values are compared, never printed.
    # GetEnvironmentVariable rather than $env: — the kid keeps its case in the name.
    $ringK1     = [Environment]::GetEnvironmentVariable('OCTO_SECRETENCRYPTION__KEYS__k1')
    $ringActive = [Environment]::GetEnvironmentVariable('OCTO_SECRETENCRYPTION__ACTIVEKEYID')
    $ringLegacy = [Environment]::GetEnvironmentVariable('OCTO_SECRETENCRYPTION__LEGACYV1KEY')
    $ringPresent      = -not [string]::IsNullOrEmpty($ringK1)
    $k1MatchesInstance = $ringPresent -and ($ringK1 -ceq $cc)
    $activeKeyPresent = (-not [string]::IsNullOrEmpty($ringActive)) -and `
        (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable("OCTO_SECRETENCRYPTION__KEYS__$ringActive")))
    $legacyMatches    = (-not [string]::IsNullOrEmpty($ringLegacy)) -and ($ringLegacy -ceq $cc)

    $ringFailure = $null
    if (-not $ringPresent) {
        $ringFailure = 'OCTO_SECRETENCRYPTION__KEYS__k1 is not set (SECRET key ring missing). Run Start-Octo first.'
    } elseif (-not $k1MatchesInstance) {
        $ringFailure = 'OCTO_SECRETENCRYPTION__KEYS__k1 differs from the instance key - k1 must be the instance secret (AB#5528 decision 3).'
    } elseif (-not $activeKeyPresent) {
        $ringFailure = 'OCTO_SECRETENCRYPTION__ACTIVEKEYID is not set or names a key id without an OCTO_SECRETENCRYPTION__KEYS__<kid> variable.'
    } elseif (-not $legacyMatches) {
        $ringFailure = 'OCTO_SECRETENCRYPTION__LEGACYV1KEY is not set or differs from the instance key - enc:v1 values would not decrypt.'
    }

    if ($ringFailure) {
        if ($Json) {
            Write-OctoJson -Command 'Test-OctoEncryption' -Data ([ordered]@{
                passed               = $false
                aiKeySet             = $true
                ccKeySet             = $true
                keysMatch            = $true
                validBase64          = $true
                keyLength            = [int]$bytes.Length
                keyRingPresent       = [bool]$ringPresent
                k1MatchesInstanceKey = [bool]$k1MatchesInstance
                activeKeyId          = $ringActive
                activeKeyPresent     = [bool]$activeKeyPresent
                legacyV1KeyMatches   = [bool]$legacyMatches
                message              = $ringFailure
            })
            return
        }
        Write-Host "FAIL  $ringFailure" -ForegroundColor Red
        return $false
    }

    if ($Json) {
        Write-OctoJson -Command 'Test-OctoEncryption' -Data ([ordered]@{
            keyRingPresent       = $true
            k1MatchesInstanceKey = $true
            activeKeyId          = $ringActive
            activeKeyPresent     = $true
            legacyV1KeyMatches   = $true
            passed      = $true
            aiKeySet    = $true
            ccKeySet    = $true
            keysMatch   = $true
            validBase64 = $true
            keyLength   = [int]$bytes.Length
            message     = 'Both env vars set, byte-identical, decoded length 32; SECRET key ring k1 = instance key, active and legacy keys set. Cross-service decrypt will work.'
        })
        return
    }

    Write-Host "PASS  Both env vars set, byte-identical, decoded length 32. Cross-service decrypt will work." -ForegroundColor Green
    Write-Host "PASS  SECRET key ring: k1 = instance key, active key '$ringActive' present, LegacyV1Key = instance key." -ForegroundColor Green
    Write-Host "  Key (truncated): $($ai.Substring(0, 16))..."
    Write-Host ""
    Write-Host "Run the canonical cross-replica wire-format round-trip test:" -ForegroundColor DarkGray
    Write-Host "  cd /Users/gerald/RiderProjects/meshmakers/main/octo-sdk" -ForegroundColor DarkGray
    Write-Host "  dotnet test tests/Sdk.Common.Tests/Sdk.Common.Tests.csproj --filter `"FullyQualifiedName~CrossReplicaRoundTrip`"" -ForegroundColor DarkGray
    return $true
}

Export-ModuleMember -Function Test-OctoEncryption
