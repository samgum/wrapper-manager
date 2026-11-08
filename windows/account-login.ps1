[CmdletBinding()]
param(
    [ValidateSet('jp','secondary')][string]$Profile = 'jp',
    [switch]$Reenter
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Send-LocalLogin {
    param([Management.Automation.PSCredential]$Credential, [string]$Code = '')
    $buffer = [IntPtr]::Zero
    $body = $null
    $json = $null
    try {
        $buffer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
        $body = @{username=$Credential.UserName; password=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($buffer)}
        if ($Code) { $body.code = $Code }
        $json = $body | ConvertTo-Json -Compress
        # Credentials travel only to this installation's loopback backend.
        # Never put them on a process command line, in BAT, or in a log.
        return Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:12340/login' -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -MaximumRedirection 0 -TimeoutSec 180
    } finally {
        if ($body) { $body.password = $null; $body.Clear() }
        $json = $null
        if ($buffer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($buffer) }
    }
}

function Invoke-AccountLogin {
    param([Management.Automation.PSCredential]$Credential)
    $response = Send-LocalLogin -Credential $Credential
    if ($null -eq $response -or $null -eq $response.PSObject.Properties['code']) {
        throw '登录服务返回格式不正确。已保存的账号资料没有改变。'
    }
    if ($response.code -eq 2) {
        $verification = (Read-Host '请输入 Apple 双重验证码').Trim()
        if (-not $verification) { throw '已取消验证码输入，未修改保存的账号资料。' }
        $response = Send-LocalLogin -Credential $Credential -Code $verification
        $verification = $null
    }
    if ($null -eq $response -or $null -eq $response.PSObject.Properties['code']) {
        throw '登录服务返回格式不正确。已保存的账号资料没有改变。'
    }
    if ($response.code -eq 0) { return $true }
    if ($response.code -eq -1 -and $null -ne $response.PSObject.Properties['msg'] -and $response.msg -eq 'already login') {
        return $true
    }
    throw ('登录未完成（返回码 {0}）。请检查账号、订阅或验证码；需要更换已存账号时，可在运行此 BAT 时加 -Reenter。' -f $response.code)
}

function Select-LocalAccount {
    param([string]$Username)
    $body = @{username=$Username} | ConvertTo-Json -Compress
    $response = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:12340/select-account' -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -MaximumRedirection 0 -TimeoutSec 15
    if ($null -eq $response -or $null -eq $response.PSObject.Properties['code']) {
        throw '账号切换服务返回格式不正确，未开始新的登录。'
    }
    if ($response.code -eq 0) { return $response.data }
    if ($response.code -eq -1 -and $response.msg -eq 'account is not logged in') { return $null }
    throw '账号切换未完成，原选择保持不变。'
}

function Set-PrivateAccountDirectory {
    param([string]$Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & "$env:SystemRoot\System32\icacls.exe" $Directory /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '无法保护账号保存目录，已停止登录。' }
}

function Start-AccountEntry {
    $label = if ($Profile -eq 'jp') { '日区账号（原日区入口）' } else { '第二账号（原副本入口）' }
    Write-Host $label
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'backend.ps1') -Action Start
    if ($LASTEXITCODE -ne 0) { throw 'Wrapper 后端未启动。' }

    $accountDir = Join-Path $PSScriptRoot 'accounts'
    Set-PrivateAccountDirectory -Directory $accountDir
    $savedFile = Join-Path $accountDir ($Profile + '.credential.xml')
    $temporaryFile = $savedFile + '.new'
    $credential = $null
    $newCredential = $false
    if ((Test-Path -LiteralPath $savedFile) -and -not $Reenter) {
        try {
            $credential = Import-Clixml -LiteralPath $savedFile
            if ($credential -isnot [Management.Automation.PSCredential]) { throw 'Invalid credential record' }
        } catch {
            throw '已存资料无法由当前 Windows 用户解密。请在运行此 BAT 时加 -Reenter，重新设置该入口。'
        }
    } else {
        Write-Host '首次设置：账号和密码只输入到本窗口，密码用当前 Windows 用户的 DPAPI 加密保存。'
        $username = (Read-Host 'Apple ID').Trim()
        if (-not $username) { throw '已取消账号输入。' }
        $password = Read-Host '密码' -AsSecureString
        if ($password.Length -eq 0) { throw '已取消密码输入。' }
        $credential = [Management.Automation.PSCredential]::new($username, $password)
        $newCredential = $true
    }
    try {
        # A valid cached session only needs selection: no password submission
        # and no account logout, guest restart, or repeated Apple login.
        $selection = if ($Reenter) { $null } else { Select-LocalAccount -Username $credential.UserName }
        if ($null -eq $selection) {
            $null = Invoke-AccountLogin -Credential $credential
            $selection = Select-LocalAccount -Username $credential.UserName
            if ($null -eq $selection) { throw '登录已完成，但账号尚未就绪。请稍后重试；原选择保持不变。' }
        }
        # Do not replace a working saved credential after a failed login.
        if ($newCredential) {
            $credential | Export-Clixml -LiteralPath $temporaryFile -Encoding UTF8
            Move-Item -LiteralPath $temporaryFile -Destination $savedFile -Force
        }
        $profileFile = Join-Path $PSScriptRoot 'active-profile.json'
        [pscustomobject]@{profile=$Profile;label=$label;region=$selection.region} | ConvertTo-Json | Set-Content -LiteralPath ($profileFile + '.new') -Encoding UTF8
        Move-Item -LiteralPath ($profileFile + '.new') -Destination $profileFile -Force
        Write-Host ('已切换到：{0}，地区：{1}。GUI 和 v3 的新请求会使用此账号。' -f $label,$selection.region) -ForegroundColor Green
        Write-Host '切换不会退出已保存的其他账号。以后双击对应入口即可切换；Apple 要求验证时仍需输入验证码。'
    } finally {
        $credential = $null
        if (Test-Path -LiteralPath $temporaryFile) { Remove-Item -LiteralPath $temporaryFile -Force }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $entryLock = $null
    try {
        $entryLock = [IO.File]::Open((Join-Path $PSScriptRoot '.account-entry.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        Start-AccountEntry
    } catch {
        # Exception details from HTTP clients can contain request information.
        # Only show messages raised by our own input/validation functions.
        if ($_.Exception -is [Net.WebException] -or $_.Exception.GetType().FullName -match 'HttpResponseException') {
            Write-Host '无法完成本机登录请求。请检查 Wrapper 状态后重试；已保存的账号资料没有改变。' -ForegroundColor Red
        } else {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }
        exit 1
    } finally {
        if ($entryLock) { $entryLock.Dispose() }
    }
}
