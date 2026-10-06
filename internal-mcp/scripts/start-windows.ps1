param([string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'LabApp\internal-mcp'))
$ErrorActionPreference = 'Stop'
$appDirectory = Split-Path $PSScriptRoot -Parent
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutex = New-Object Threading.Mutex($false, "Local\LabAppInternalMcp-$sid")
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit 0 }
try {
    $env:MCP_TOKEN_FILE = Join-Path $StateDirectory 'secrets\mcp_token'
    $env:LINEAR_API_KEY_FILE = Join-Path $StateDirectory 'secrets\linear_api_key'
    $env:DATABASE_URL_FILE = Join-Path $StateDirectory 'secrets\database_url'
    $env:UPLOAD_DIRECTORY = Join-Path $StateDirectory 'uploads'
    $env:BIND_ADDRESS = '127.0.0.1'
    $env:PORT = '3100'
    $log = Join-Path $StateDirectory 'server.log'
    if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 5MB) {
        Move-Item -LiteralPath $log -Destination (Join-Path $StateDirectory 'server.previous.log') -Force
    }
    Set-Location -LiteralPath $appDirectory
    & (Get-Command node.exe -ErrorAction Stop).Source (Join-Path $appDirectory 'dist\index.js') >> $log 2>&1
    exit $LASTEXITCODE
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
