function Invoke-OctoCliReconfigureLogLevel
{
    param(
        [Parameter(Mandatory=$true)]
        [string]$loggerName,    
        [Parameter(Mandatory=$true)]
        [string]$minLogLevel,
        [Parameter(Mandatory=$true)]
        [string]$maxLogLevel
    )

    octo-cli -c ReconfigureLogLevel -n "Identity" -loggerName "*" -minL $minLogLevel -maxL $maxLogLevel
    octo-cli -c ReconfigureLogLevel -n "AssetRepository" -loggerName "*" -minL $minLogLevel -maxL $maxLogLevel
    octo-cli -c ReconfigureLogLevel -n "Bot" -loggerName "*" -minL $minLogLevel -maxL $maxLogLevel
    octo-cli -c ReconfigureLogLevel -n "CommunicationController" -loggerName "*" -minL $minLogLevel -maxL $maxLogLevel
    octo-cli -c ReconfigureLogLevel -n "PlatformServices" -loggerName "*" -minL $minLogLevel -maxL $maxLogLevel
}

Export-ModuleMember -Function @('Invoke-OctoCliReconfigureLogLevel')

