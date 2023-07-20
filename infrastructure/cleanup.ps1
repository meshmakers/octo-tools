#!/usr/bin/env pwsh

if (Test-Path -Path "file.key") {
    Write-Host "Deleting key file";
    Remove-Item -Force -Path "file.key"
}

Write-Host "Stopping containers and cleaning up volumes";
docker-compose down -v