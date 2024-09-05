function Invoke-OctoCliReconfigureLogLevel
{
    param($minLogLevel = "Trace")

    octo-cli -c ReconfigureMinLogLevel -l $minLogLevel
}

Export-ModuleMember -Function @('Invoke-OctoCliReconfigureLogLevel')

