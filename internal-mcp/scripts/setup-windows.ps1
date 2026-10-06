param(
    [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'LabApp\internal-mcp'),
    [switch]$InitializeOnly,
    [switch]$NoPrompt
)
$ErrorActionPreference = 'Stop'
$appDirectory = Split-Path $PSScriptRoot -Parent
$StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
$checkout = [IO.Path]::GetFullPath((Split-Path $appDirectory -Parent)).TrimEnd('\')
if ($StateDirectory.StartsWith($checkout + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose a private state directory outside the checkout.'
}
$node = (Get-Command node.exe -ErrorAction Stop).Source
$nodeVersion = (& $node --version).Trim()
if ([int]($nodeVersion.TrimStart('v').Split('.')[0]) -lt 22) { throw 'Node.js 22 or newer is required.' }
if (-not (Test-Path -LiteralPath (Join-Path $appDirectory 'dist\index.js'))) { throw 'Run npm ci and npm run build first.' }
New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetOwner($identity.User)
$acl.SetAccessRuleProtection($true, $false)
foreach ($trustee in @($identity.User, (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'))) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($trustee, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $StateDirectory -AclObject $acl
foreach ($folder in @('secrets', 'uploads')) {
    New-Item -ItemType Directory -Path (Join-Path $StateDirectory $folder) -Force | Out-Null
}
$utf8 = New-Object Text.UTF8Encoding($false)
$tokenFile = Join-Path $StateDirectory 'secrets\mcp_token'
if (-not (Test-Path -LiteralPath $tokenFile)) {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    [IO.File]::WriteAllText($tokenFile, ([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant() + "`n"), $utf8)
}
foreach ($name in @('database_url', 'linear_api_key')) {
    $file = Join-Path $StateDirectory "secrets\$name"
    if (-not (Test-Path -LiteralPath $file)) { [IO.File]::WriteAllText($file, '', $utf8) }
}
if ($InitializeOnly) { Write-Host 'Private credential directory initialized.'; exit 0 }
if (-not $NoPrompt) {
    Write-Host 'Pega la clave de Linear. La entrada permanece oculta; Enter conserva la clave existente.'
    $secure = Read-Host 'Clave de Linear' -AsSecureString
    if ($secure.Length -gt 0) {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer).Trim()
            if ($plain.Length -eq 0) { throw 'The key is empty.' }
            [IO.File]::WriteAllText((Join-Path $StateDirectory 'secrets\linear_api_key'), $plain + "`n", $utf8)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
            $plain = $null
            $secure.Dispose()
        }
    }
}
$token = [IO.File]::ReadAllText($tokenFile).Trim()
if ($token.Length -lt 32) { throw 'Invalid server token.' }
[Environment]::SetEnvironmentVariable('LABAPP_MCP_TOKEN', $token, 'User')
$env:LABAPP_MCP_TOKEN = $token
$codex = (Get-Command codex.exe -ErrorAction Stop).Source
& $codex mcp add labapp-internal --url http://127.0.0.1:3100/mcp --bearer-token-env-var LABAPP_MCP_TOKEN
if ($LASTEXITCODE -ne 0) { throw 'Codex configuration failed.' }
$runtime = Join-Path $StateDirectory 'runtime'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $appDirectory 'package.json') -Destination $runtime -Force
foreach ($folder in @('dist', 'node_modules')) {
    Copy-Item -LiteralPath (Join-Path $appDirectory $folder) -Destination $runtime -Recurse -Force
}
New-Item -ItemType Directory -Path (Join-Path $runtime 'scripts') -Force | Out-Null
foreach ($script in @('start-windows.ps1', 'check-live.mjs')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $script) -Destination (Join-Path $runtime 'scripts') -Force
}
$launcher = Join-Path $runtime 'scripts\start-windows.ps1'
$powershell = Join-Path $PSHOME 'powershell.exe'
$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '" -StateDirectory "' + $StateDirectory + '"'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-Item -Path $runKey -Force | Out-Null
New-ItemProperty -Path $runKey -Name 'LabAppInternalMcp' -Value ('"' + $powershell + '" ' + $arguments) -PropertyType String -Force | Out-Null
Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden
Start-Sleep -Seconds 2
& $node (Join-Path $PSScriptRoot 'check-live.mjs') $StateDirectory
if ($LASTEXITCODE -ne 0) { throw 'Live verification failed. Review the private server log; no credentials are printed.' }
Write-Host 'Servicio iniciado. Reinicia Codex para cargar la conexion y la variable de autenticacion.'
