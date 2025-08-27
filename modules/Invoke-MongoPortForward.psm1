function Invoke-MongoPortForward {
    param(
        [ValidateSet('test-2', 'staging', 'production')]
        [string]$environment = 'test-2'
    )
    
    $service = switch ($environment) {
        'production' { 'octo-production-svc' }
        'staging' { 'octo-staging-svc' }
        'test-2' { 'octo-mongodb-svc' }
    }
    
    if ($environment -eq 'production') {
        Write-Host ""
        Write-Host "╔════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
        Write-Host "║                                                                    ║" -ForegroundColor Red
        Write-Host "║                    ⚠️  PRODUCTION WARNING ⚠️                         ║" -ForegroundColor Red
        Write-Host "║                                                                    ║" -ForegroundColor Red
        Write-Host "║         YOU ARE CONNECTING TO THE PRODUCTION DATABASE!             ║" -ForegroundColor Red
        Write-Host "║                                                                    ║" -ForegroundColor Red
        Write-Host "║     • ALL CHANGES ARE PERMANENT AND AFFECT LIVE SYSTEMS            ║" -ForegroundColor Red
        Write-Host "║     • EXERCISE EXTREME CAUTION WITH ALL OPERATIONS                 ║" -ForegroundColor Red
        Write-Host "║     • CONSIDER USING STAGING OR TEST ENVIRONMENTS FIRST            ║" -ForegroundColor Red
        Write-Host "║                                                                    ║" -ForegroundColor Red
        Write-Host "╚════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
        Write-Host ""
        
        $confirm = Read-Host "Type 'PRODUCTION' to confirm you want to connect to production"
        if ($confirm -ne 'PRODUCTION') {
            Write-Host "Connection cancelled." -ForegroundColor Yellow
            return
        }
    }
    
    Write-Host "Setting up MongoDB port forwarding for $environment environment..." -ForegroundColor Green
    Write-Host "Forwarding localhost:27028 -> $service:27017" -ForegroundColor Cyan
    
    kubectl port-forward "svc/$service" 27028:27017 -n mongodb
}

Export-ModuleMember -Function @('Invoke-MongoPortForward')