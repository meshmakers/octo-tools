function Invoke-OctoCliReconfigureLogLevel
{
    param(
        [Parameter(Mandatory=$true)]
        [string]$loggerName,    
        [Parameter(Mandatory=$true)]
        [string]$minLogLevel,
        [Parameter(Mandatory=$true)]
        [string]$maxLogLevel,
        [switch]$Json
    )

    if ($Json) {
        $services = @('Identity', 'AssetRepository', 'Bot', 'CommunicationController', 'PlatformServices')
        $exitCode = 0
        foreach ($svc in $services) {
            octo-cli -c ReconfigureLogLevel -n $svc -loggerName "*" -minL $minLogLevel -maxL $maxLogLevel | Out-Null
            if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }
        }
        Write-OctoJson -Command 'Invoke-OctoCliReconfigureLogLevel' -Data (New-OctoActionResult -Success ($exitCode -eq 0) -ExitCode $exitCode)
        return
    }

    octo-cli -c ReconfigureLogLevel -n "Identity" -loggerName "*" -minL $minLogLevel -maxL $maxLogLevel
    octo-cli -c ReconfigureLogLevel -n "AssetRepository" -loggerName "*" -minL $minLogLevel -maxL $maxLogLevel
    octo-cli -c ReconfigureLogLevel -n "Bot" -loggerName "*" -minL $minLogLevel -maxL $maxLogLevel
    octo-cli -c ReconfigureLogLevel -n "CommunicationController" -loggerName "*" -minL $minLogLevel -maxL $maxLogLevel
    octo-cli -c ReconfigureLogLevel -n "PlatformServices" -loggerName "*" -minL $minLogLevel -maxL $maxLogLevel
}

Export-ModuleMember -Function @('Invoke-OctoCliReconfigureLogLevel')

