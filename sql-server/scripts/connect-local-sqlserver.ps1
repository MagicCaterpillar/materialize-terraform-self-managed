[CmdletBinding()]
param(
    [string]$TerraformDir = "../examples/azure",
    [string]$Namespace = "sql-server",
    [string]$ServiceName = "mssql",
    [int]$LocalPort = 11433,
    [switch]$SkipSqlLoginTest,
    [switch]$ShowConnectionPassword
)

$ErrorActionPreference = "Stop"

function Assert-Command {
    param([string]$Command)

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Required command '$Command' was not found in PATH."
    }
}

Assert-Command -Command "terraform"
Assert-Command -Command "kubectl"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$terraformDirFullPath = Resolve-Path (Join-Path $scriptRoot $TerraformDir)

Push-Location $terraformDirFullPath
try {
    $saPassword = (terraform output -raw sa_password).Trim()
}
finally {
    Pop-Location
}

$serviceType = (kubectl get svc $ServiceName -n $Namespace -o jsonpath='{.spec.type}').Trim()
if ($serviceType -ne "ClusterIP") {
    Write-Warning "Service '$ServiceName' in namespace '$Namespace' is '$serviceType'. For private local access, ClusterIP is recommended."
}

Write-Host "Starting port-forward: 127.0.0.1:$LocalPort -> ${ServiceName}.${Namespace}:1433" -ForegroundColor Cyan
$job = Start-Job -ScriptBlock {
    kubectl port-forward "svc/$using:ServiceName" -n "$using:Namespace" "$using:LocalPort`:1433" --address 127.0.0.1
}

$portForwardReady = $false
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
while ($stopwatch.Elapsed.TotalSeconds -lt 20) {
    $result = Test-NetConnection -ComputerName "127.0.0.1" -Port $LocalPort -WarningAction SilentlyContinue
    if ($result.TcpTestSucceeded) {
        $portForwardReady = $true
        break
    }

    Start-Sleep -Milliseconds 500
}

if (-not $portForwardReady) {
    try {
        Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    throw "Port-forward did not become ready on 127.0.0.1:$LocalPort within timeout."
}

Write-Host "Local tunnel is ready." -ForegroundColor Green

if (-not $SkipSqlLoginTest) {
    Add-Type -AssemblyName System.Data
    $connectionString = "Server=127.0.0.1,$LocalPort;User ID=SA;Password=$saPassword;Encrypt=True;TrustServerCertificate=True;Connection Timeout=8;"
    $conn = New-Object System.Data.SqlClient.SqlConnection $connectionString

    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT @@SERVERNAME AS server_name, DB_NAME() AS db_name"
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            Write-Host ("SQL login test OK: server=" + $reader[0] + ", db=" + $reader[1]) -ForegroundColor Green
        }
        $reader.Close()
    }
    catch {
        Write-Warning ("SQL login test failed: " + $_.Exception.Message)
    }
    finally {
        if ($conn.State -ne [System.Data.ConnectionState]::Closed) {
            $conn.Close()
        }
    }
}

Write-Host ""
Write-Host "Use these settings in SSMS or HammerDB:" -ForegroundColor Cyan
Write-Host "  Server: 127.0.0.1,$LocalPort"
Write-Host "  Login: SA"
if ($ShowConnectionPassword) {
    Write-Host "  Password: $saPassword"
}
else {
    Write-Host "  Password: <use terraform output -raw sa_password>"
}
Write-Host "  Encrypt: True"
Write-Host "  Trust Server Certificate: True"
Write-Host ""
Write-Host "Press Enter to stop port-forward and exit." -ForegroundColor Yellow
[void](Read-Host)

Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

Write-Host "Port-forward stopped." -ForegroundColor Green
