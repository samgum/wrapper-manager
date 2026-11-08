$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../account-login.ps1')
$script:Responses = @()
$script:Requests = @()
function Invoke-RestMethod {
    param($Method,$Uri,$ContentType,$Body,$MaximumRedirection,$TimeoutSec)
    if ($Uri -notin @('http://127.0.0.1:12340/login','http://127.0.0.1:12340/select-account') -or $MaximumRedirection -ne 0) { throw 'Unexpected credential destination or redirect policy' }
    $script:Requests += ([Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json)
    if ($Uri.EndsWith('/select-account') -and $script:Requests[-1].PSObject.Properties['password']) { throw 'Account switch unnecessarily sent a password' }
    $response = $script:Responses[0]
    $script:Responses = @($script:Responses | Select-Object -Skip 1)
    return $response
}
function Read-Host { param($Prompt) return '012345' }
$credential = [Management.Automation.PSCredential]::new('test@example.invalid',(ConvertTo-SecureString 'synthetic-test-only' -AsPlainText -Force))
$script:Responses = @([pscustomobject]@{code=0;msg='SUCCESS'})
if (-not (Invoke-AccountLogin $credential)) { throw 'Fresh login failed' }
$script:Responses = @([pscustomobject]@{code=-1;msg='already login'})
if (-not (Invoke-AccountLogin $credential)) { throw 'Cached login failed' }
$script:Requests = @()
$script:Responses = @([pscustomobject]@{code=2;msg='2fa code require'},[pscustomobject]@{code=0;msg='SUCCESS'})
if (-not (Invoke-AccountLogin $credential)) { throw '2FA login failed' }
if ($script:Requests.Count -ne 2 -or $script:Requests[1].code -ne '012345') { throw '2FA did not preserve leading zero' }
foreach ($response in @([pscustomobject]@{code=-1;msg='bad password'},[pscustomobject]@{unexpected='shape'})) {
    $script:Responses = @($response)
    $rejected = $false
    try { $null = Invoke-AccountLogin $credential } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid response was accepted' }
}
$script:Responses = @([pscustomobject]@{code=0;data=[pscustomobject]@{selected=$true;region='jp'}})
if ((Select-LocalAccount 'test@example.invalid').region -ne 'jp') { throw 'Account selection failed' }
$script:Responses = @([pscustomobject]@{code=-1;msg='account is not logged in'})
if ($null -ne (Select-LocalAccount 'test@example.invalid')) { throw 'Missing session must require login' }
$script:Responses = @([pscustomobject]@{code=-1;msg='cannot save account selection'})
$rejected = $false
try { $null = Select-LocalAccount 'test@example.invalid' } catch { $rejected = $true }
if (-not $rejected) { throw 'Failed selection incorrectly reported success' }
$temporary = Join-Path $PSScriptRoot 'synthetic-credential.xml'
try {
    $credential | Export-Clixml -LiteralPath $temporary -Encoding UTF8
    $xml = [IO.File]::ReadAllText($temporary)
    if ($xml.Contains('synthetic-test-only')) { throw 'Password written without DPAPI protection' }
    $restored = Import-Clixml -LiteralPath $temporary
    if ($restored.GetNetworkCredential().Password -ne 'synthetic-test-only') { throw 'DPAPI round trip failed' }
} finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
Write-Output 'PASS: login, cached session, 2FA, failed/malformed response, account selection without password, missing session, rejected switch, loopback-only destination, no redirects, DPAPI round trip. No real account or network request was used.'
