# wobby_put_env.ps1 -- PUT a prepared environment JSON to the Wobby public API.
# Usage: powershell -File scripts\pos_perf\wobby_put_env.ps1 [-BodyFile <path>]
# Reads credentials from .claude\skills\wobby\wobby.config.json (gitignored).
# Rate limit is 2 requests per 5 seconds per IP (violations = 1-hour ban),
# so this script makes exactly one call and never retries.
param(
    [string]$BodyFile = "out\pos_perf\wobby_env_put_body.json"
)
$ErrorActionPreference = "Stop"
$cfg = Get-Content ".claude\skills\wobby\wobby.config.json" -Raw | ConvertFrom-Json
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$body = [IO.File]::ReadAllBytes((Resolve-Path $BodyFile))
$null = (Get-Content $BodyFile -Raw | ConvertFrom-Json)  # refuse to send unparseable JSON
$resp = Invoke-WebRequest -Uri "$($cfg.baseUrl)/api/public/v1/environment" `
    -Headers @{ Authorization = "Bearer $($cfg.apiKey)" } `
    -Method Put -Body $body -ContentType "application/json" -UseBasicParsing
Write-Host "PUT status: $($resp.StatusCode)"
$max = [Math]::Min(500, $resp.Content.Length)
Write-Host "response: $($resp.Content.Substring(0, $max))"
