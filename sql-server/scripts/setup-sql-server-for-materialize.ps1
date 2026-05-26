[CmdletBinding()]
param(
    [string]$TerraformDir = "../examples/azure",
    [switch]$SkipTerraformApply,
    [switch]$NoAutoApprove,
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
    [bool]$CreateMaterializeSource = $true,
    [string]$MaterializeSourceName = "sqlserver_source",
    [string]$MaterializeConnectionName = "sqlserver_conn",
    [string]$MaterializeSecretName = "sqlserver_password"
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
$bootstrapScript = Join-Path $scriptRoot "bootstrap-materialize-source.ps1"
$materializeSourceScript = Join-Path $scriptRoot "create-materialize-sqlserver-source.ps1"

if (-not $SkipTerraformApply) {
    Push-Location $terraformDirFullPath
    try {
        terraform init

        if ($NoAutoApprove) {
            terraform apply
        }
        else {
            terraform apply -auto-approve
        }
    }
    finally {
        Pop-Location
    }
}

$bootstrapParams = @{
    TerraformDir      = $TerraformDir
    DatabaseName      = $DatabaseName
    SourceSchema      = $SourceSchema
    SourceTable       = $SourceTable
    MaterializeLogin  = $MaterializeLogin
    RotateMaterializePassword = $RotateMaterializePassword
    EnableCdc         = $EnableCdc
    CreateSampleData  = $CreateSampleData
}

if ($Namespace) {
    $bootstrapParams.Namespace = $Namespace
}
if ($DeploymentName) {
    $bootstrapParams.DeploymentName = $DeploymentName
}
if ($MaterializePassword) {
    $bootstrapParams.MaterializePassword = $MaterializePassword
}

& $bootstrapScript @bootstrapParams

if ($CreateMaterializeSource) {
    if (-not $MaterializePassword) {
        throw "MaterializePassword is required when CreateMaterializeSource is enabled. Pass a deterministic password so both SQL bootstrap and Materialize connection use the same credentials."
    }

    $sourceParams = @{
        SqlServerTerraformDir      = $TerraformDir
        SqlServerDatabase          = $DatabaseName
        SqlServerSchema            = $SourceSchema
        SqlServerTable             = $SourceTable
        SqlServerUser              = $MaterializeLogin
        SqlServerPassword          = $MaterializePassword
        MaterializeSourceName      = $MaterializeSourceName
        MaterializeConnectionName  = $MaterializeConnectionName
        MaterializeSecretName      = $MaterializeSecretName
    }

    & $materializeSourceScript @sourceParams
}
