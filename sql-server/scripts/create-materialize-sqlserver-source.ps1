[CmdletBinding()]
param(
    [string]$MaterializeTerraformDir = "../../azure/examples/simple",
    [string]$SqlServerTerraformDir = "../examples/azure",
    [string]$MaterializeNamespace,
    [string]$BalancerdServiceHost,
    [int]$BalancerdPort = 6875,
    [string]$MaterializeUser = "mz_system",
    [string]$MaterializePassword,
    [string]$MaterializeDatabase = "materialize",
    [string]$MaterializeCluster = "quickstart",
    [string]$SqlServerHost,
    [int]$SqlServerPort,
    [string]$SqlServerDatabase = "materialize_source",
    [string]$SqlServerSchema = "dbo",
    [string]$SqlServerTable = "orders",
    [string]$SqlServerUser = "materialize_ingest",
    [string]$SqlServerPassword,
    [string]$MaterializeSecretName = "sqlserver_password",
    [string]$MaterializeConnectionName = "sqlserver_conn",
    [string]$MaterializeSourceName = "sqlserver_source",
    [switch]$ForceRecreate,
    [string]$TemplateSqlPath = "./materialize-sqlserver-source.sql",
    [string]$ClientPodNamespace,
    [int]$ClientPodTimeoutSeconds = 120
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
$templateSqlFullPath = Resolve-Path (Join-Path $scriptRoot $TemplateSqlPath)
$materializeTfFullPath = Resolve-Path (Join-Path $scriptRoot $MaterializeTerraformDir)
$sqlServerTfFullPath = Resolve-Path (Join-Path $scriptRoot $SqlServerTerraformDir)

if (-not $MaterializeNamespace) {
    Push-Location $materializeTfFullPath
    try {
        $MaterializeNamespace = (terraform output -raw materialize_instance_namespace).Trim()
    }
    finally {
        Pop-Location
    }
}

if (-not $ClientPodNamespace) {
    $ClientPodNamespace = $MaterializeNamespace
}

if (-not $BalancerdServiceHost) {
    $balancerdSvc = kubectl get svc -n $MaterializeNamespace -o name |
        ForEach-Object { ($_ -split '/')[1] } |
        Where-Object { $_ -like "*-balancerd" } |
        Select-Object -First 1
    if (-not $balancerdSvc) {
        throw "Could not resolve balancerd service name in namespace '$MaterializeNamespace'."
    }
    $BalancerdServiceHost = "$balancerdSvc.$MaterializeNamespace.svc.cluster.local"
}

$materializeResourceId = ""
if ($BalancerdServiceHost -match '^([^.]+)\.') {
    $balancerdServiceName = $Matches[1]
    $materializeResourceId = (kubectl get svc $balancerdServiceName -n $MaterializeNamespace -o jsonpath='{.metadata.labels.materialize\.cloud/mz-resource-id}' 2>$null).Trim()
}

if (-not $MaterializePassword) {
    Push-Location $materializeTfFullPath
    try {
        $MaterializePassword = (terraform output -raw external_login_password_mz_system).Trim()
    }
    finally {
        Pop-Location
    }
}

Push-Location $sqlServerTfFullPath
try {
    if (-not $SqlServerHost) {
        $sqlServiceName = (terraform output -raw service_name).Trim()
        $sqlServiceNamespace = (terraform output -raw namespace).Trim()

        $lbIp = kubectl get svc $sqlServiceName -n $sqlServiceNamespace -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
        $lbHost = kubectl get svc $sqlServiceName -n $sqlServiceNamespace -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null

        if ($lbIp) {
            $SqlServerHost = $lbIp.Trim()
        }
        elseif ($lbHost) {
            $SqlServerHost = $lbHost.Trim()
        }
        else {
            $SqlServerHost = (terraform output -raw service_fqdn).Trim()
        }
    }

    if (-not $SqlServerPort) {
        $SqlServerPort = [int](terraform output -raw port).Trim()
    }
}
finally {
    Pop-Location
}

if (-not $SqlServerPassword) {
    throw "SqlServerPassword is required. Pass the same login password configured by bootstrap-materialize-source.ps1 for user '$SqlServerUser'."
}

$sqlServerPasswordSql = $SqlServerPassword.Replace("'", "''")
$sqlServerHostSql = $SqlServerHost.Replace("'", "''")
$sqlServerDatabaseSql = $SqlServerDatabase.Replace("'", "''")
$sqlServerSchemaSql = $SqlServerSchema.Replace("'", "''")
$sqlServerTableSql = $SqlServerTable.Replace("'", "''")
$sqlServerUserSql = $SqlServerUser.Replace("'", "''")
$materializeClusterSql = $MaterializeCluster.Replace('"', '""')
$secretNameSql = $MaterializeSecretName.Replace("'", "''")
$connectionNameSql = $MaterializeConnectionName.Replace("'", "''")
$sourceNameSql = $MaterializeSourceName.Replace("'", "''")

$sqlTemplate = Get-Content -Raw -Path $templateSqlFullPath
$sqlContent = $sqlTemplate
$sqlContent = $sqlContent.Replace('$(MZ_CLUSTER_NAME)', $materializeClusterSql)
$sqlContent = $sqlContent.Replace('$(MZ_SECRET_NAME)', $secretNameSql)
$sqlContent = $sqlContent.Replace('$(MZ_CONNECTION_NAME)', $connectionNameSql)
$sqlContent = $sqlContent.Replace('$(MZ_SOURCE_NAME)', $sourceNameSql)
$sqlContent = $sqlContent.Replace('$(SQLSERVER_HOST)', $sqlServerHostSql)
$sqlContent = $sqlContent.Replace('$(SQLSERVER_PORT)', $SqlServerPort.ToString())
$sqlContent = $sqlContent.Replace('$(SQLSERVER_DATABASE)', $sqlServerDatabaseSql)
$sqlContent = $sqlContent.Replace('$(SQLSERVER_USER)', $sqlServerUserSql)
$sqlContent = $sqlContent.Replace('$(SQLSERVER_PASSWORD)', $sqlServerPasswordSql)
$sqlContent = $sqlContent.Replace('$(SQLSERVER_SCHEMA)', $sqlServerSchemaSql)
$sqlContent = $sqlContent.Replace('$(SQLSERVER_TABLE)', $sqlServerTableSql)

$normalizedSql = (($sqlContent -split "`r?`n") | Where-Object { $_ -notmatch '^\s*--' }) -join "`n"

$sqlStatements = @()
foreach ($statement in ($normalizedSql -split ';')) {
    $trimmed = $statement.Trim()
    if (-not $trimmed) {
        continue
    }
    $sqlStatements += $trimmed
}

if ($sqlStatements.Count -eq 0) {
    throw "No SQL statements were generated from template '$templateSqlFullPath'."
}

if ($ForceRecreate) {
    $quotedSourceName = '"' + $MaterializeSourceName.Replace('"', '""') + '"'
    $quotedConnectionName = '"' + $MaterializeConnectionName.Replace('"', '""') + '"'
    $quotedSecretName = '"' + $MaterializeSecretName.Replace('"', '""') + '"'

    $dropStatements = @(
        "DROP SOURCE IF EXISTS $quotedSourceName CASCADE",
        "DROP CONNECTION IF EXISTS $quotedConnectionName",
        "DROP SECRET IF EXISTS $quotedSecretName"
    )

    $sqlStatements = $dropStatements + $sqlStatements
}

$clientPodName = "mz-psql-client-$(Get-Random -Minimum 1000 -Maximum 9999)"
$timeout = "${ClientPodTimeoutSeconds}s"

try {
    $runArgs = @(
        "run", $clientPodName,
        "-n", $ClientPodNamespace,
        "--restart=Never",
        "--image=postgres:16",
        "--env=PGPASSWORD=$MaterializePassword",
        "--env=PGSSLMODE=require",
        "--command", "--",
        "psql",
        "-h", $BalancerdServiceHost,
        "-p", $BalancerdPort,
        "-U", $MaterializeUser,
        "-d", $MaterializeDatabase,
        "-v", "ON_ERROR_STOP=1"
    )

    if ($materializeResourceId) {
        $runArgs = @(
            "run", $clientPodName,
            "-n", $ClientPodNamespace,
            "--restart=Never",
            "--labels=materialize.cloud/mz-resource-id=$materializeResourceId",
            "--image=postgres:16",
            "--env=PGPASSWORD=$MaterializePassword",
            "--env=PGSSLMODE=require",
            "--command", "--",
            "psql",
            "-h", $BalancerdServiceHost,
            "-p", $BalancerdPort,
            "-U", $MaterializeUser,
            "-d", $MaterializeDatabase,
            "-v", "ON_ERROR_STOP=1"
        )
    }

    foreach ($statement in $sqlStatements) {
        $runArgs += @("-c", $statement)
    }

    & kubectl @runArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start Materialize SQL client pod (exit code $LASTEXITCODE)."
    }

    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/$clientPodName -n $ClientPodNamespace --timeout=$timeout | Out-Null
    if ($LASTEXITCODE -ne 0) {
        kubectl logs $clientPodName -n $ClientPodNamespace 2>$null
        throw "Materialize SQL client pod did not reach Succeeded within $timeout."
    }

    kubectl logs $clientPodName -n $ClientPodNamespace

    if ($LASTEXITCODE -ne 0) {
        throw "Materialize source bootstrap failed with exit code $LASTEXITCODE."
    }
}
finally {
    kubectl delete pod $clientPodName -n $ClientPodNamespace --ignore-not-found | Out-Null
}

Write-Host ""
Write-Host "Materialize SQL Server source setup complete." -ForegroundColor Green
Write-Host ("Materialize endpoint: {0}:{1}" -f $BalancerdServiceHost, $BalancerdPort)
Write-Host "Materialize source: $MaterializeSourceName"
Write-Host ("SQL Server upstream: {0}:{1} ({2}.{3}.{4})" -f $SqlServerHost, $SqlServerPort, $SqlServerDatabase, $SqlServerSchema, $SqlServerTable)
