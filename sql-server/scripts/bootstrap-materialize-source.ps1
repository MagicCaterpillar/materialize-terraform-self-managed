[CmdletBinding()]
param(
    [string]$TerraformDir = "../examples/azure",
    [string]$Namespace,
    [string]$DeploymentName,
    [string]$DatabaseName = "materialize_source",
    [string]$SourceSchema = "dbo",
    [string]$SourceTable = "orders",
    [string]$MaterializeLogin = "materialize",
    [string]$MaterializePassword,
    [bool]$RotateMaterializePassword = $false,
    [bool]$EnableCdc = $true,
    [bool]$CreateSampleData = $true,
    [string]$TemplateSqlPath = "./bootstrap-materialize-source.sql",
    [int]$RolloutTimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"

function New-StrongPassword {
    param([int]$Length = 24)

    $upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    $lower = "abcdefghijkmnopqrstuvwxyz"
    $digit = "23456789"
    $special = "!@#$%^&*()-_=+"
    $all = ($upper + $lower + $digit + $special).ToCharArray()

    $chars = @(
        $upper[(Get-Random -Minimum 0 -Maximum $upper.Length)]
        $lower[(Get-Random -Minimum 0 -Maximum $lower.Length)]
        $digit[(Get-Random -Minimum 0 -Maximum $digit.Length)]
        $special[(Get-Random -Minimum 0 -Maximum $special.Length)]
    )

    for ($i = $chars.Count; $i -lt $Length; $i++) {
        $chars += $all[(Get-Random -Minimum 0 -Maximum $all.Length)]
    }

    -join ($chars | Sort-Object { Get-Random })
}

function Assert-Command {
    param([string]$Command)

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Required command '$Command' was not found in PATH."
    }
}

Assert-Command -Command "terraform"
Assert-Command -Command "kubectl"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateSqlFullPath = Resolve-Path (Join-Path $scriptRoot $TemplateSqlPath)
$terraformDirFullPath = Resolve-Path (Join-Path $scriptRoot $TerraformDir)

Push-Location $terraformDirFullPath
try {
    if (-not $Namespace) {
        $Namespace = (terraform output -raw namespace).Trim()
    }

    if (-not $DeploymentName) {
        $DeploymentName = (terraform output -raw deployment_name).Trim()
    }

    $serviceFqdn = (terraform output -raw service_fqdn).Trim()
    $saPassword = (terraform output -raw sa_password).Trim()
}
finally {
    Pop-Location
}

$rolloutTimeout = "${RolloutTimeoutSeconds}s"

kubectl rollout status deployment/$DeploymentName -n $Namespace --timeout=$rolloutTimeout | Out-Null

$podName = (kubectl get pod -n $Namespace -l "app.kubernetes.io/instance=$DeploymentName" -o jsonpath='{.items[0].metadata.name}').Trim()
if (-not $podName) {
    throw "Could not resolve SQL Server pod name for deployment '$DeploymentName' in namespace '$Namespace'."
}

$materializeLoginLiteral = $MaterializeLogin.Replace("'", "''")
$loginExistsQuery = @"
SET NOCOUNT ON;
SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'$materializeLoginLiteral') THEN 1 ELSE 0 END;
"@

$loginExistsRaw = $loginExistsQuery | & kubectl exec -i -n $Namespace $podName -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P $saPassword -No -h -1 -W
if ($LASTEXITCODE -ne 0) {
    throw "Failed to check SQL login existence (exit code $LASTEXITCODE)."
}

$loginExists = ($loginExistsRaw -join "`n").Trim() -eq "1"
$passwordGenerated = $false
$passwordUnchanged = $false

if (-not $MaterializePassword) {
    if ($loginExists -and -not $RotateMaterializePassword) {
        $MaterializePassword = "Unused_ExistingPassword"
        $passwordUnchanged = $true
    }
    else {
        $MaterializePassword = New-StrongPassword
        $passwordGenerated = $true
    }
}

$dbNameSql = $DatabaseName.Replace("'", "''")
$sourceSchemaSql = $SourceSchema.Replace("'", "''")
$sourceTableSql = $SourceTable.Replace("'", "''")
$materializeLoginSql = $MaterializeLogin.Replace("'", "''")
$materializePasswordSql = $MaterializePassword.Replace("'", "''")
$rotatePasswordFlag = if ($RotateMaterializePassword) { "1" } else { "0" }
$enableCdcFlag = if ($EnableCdc) { "1" } else { "0" }
$createSampleDataFlag = if ($CreateSampleData) { "1" } else { "0" }

$sqlTemplate = Get-Content -Raw -Path $templateSqlFullPath
$sqlContent = $sqlTemplate
$sqlContent = $sqlContent.Replace('$(DB_NAME)', $dbNameSql)
$sqlContent = $sqlContent.Replace('$(SOURCE_SCHEMA)', $sourceSchemaSql)
$sqlContent = $sqlContent.Replace('$(SOURCE_TABLE)', $sourceTableSql)
$sqlContent = $sqlContent.Replace('$(MZ_LOGIN)', $materializeLoginSql)
$sqlContent = $sqlContent.Replace('$(MZ_PASSWORD)', $materializePasswordSql)
$sqlContent = $sqlContent.Replace('$(ROTATE_LOGIN_PASSWORD)', $rotatePasswordFlag)
$sqlContent = $sqlContent.Replace('$(ENABLE_CDC)', $enableCdcFlag)
$sqlContent = $sqlContent.Replace('$(CREATE_SAMPLE_DATA)', $createSampleDataFlag)

$sqlcmdArgs = @(
    "exec", "-i",
    "-n", $Namespace,
    $podName,
    "--",
    "/opt/mssql-tools18/bin/sqlcmd",
    "-S", "localhost",
    "-U", "SA",
    "-P", $saPassword,
    "-No",
    "-b"
)

$sqlContent | & kubectl @sqlcmdArgs
if ($LASTEXITCODE -ne 0) {
    throw "SQL bootstrap failed with exit code $LASTEXITCODE."
}

Write-Host ""
Write-Host "SQL Server source bootstrap complete." -ForegroundColor Green
Write-Host "Connection host: $serviceFqdn"
Write-Host "Database: $DatabaseName"
Write-Host "Schema.Table: $SourceSchema.$SourceTable"
Write-Host "Materialize SQL login: $MaterializeLogin"
if ($passwordUnchanged) {
    Write-Host "Materialize SQL password: (unchanged existing password)"
}
else {
    Write-Host "Materialize SQL password: $MaterializePassword"
    if ($passwordGenerated) {
        Write-Host "Password was generated for this run; store it securely."
    }
}
