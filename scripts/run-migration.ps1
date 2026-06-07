# run-migration.ps1
# Oracle データ移行実行スクリプト
# 役割: コンテナ起動確認 / SQL*Plus 呼び出し / 外部ログ保存 / 終了コード判定
# 移行ロジック・例外処理・DBログは PL/SQL (pkg_migration) が担当する

param(
    [string]$RunName   = ("RUN_" + (Get-Date -Format "yyyyMMdd_HHmmss")),
    [int]$BatchSize    = 10000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- .env 読み込み ---
$envFile = Join-Path $PSScriptRoot ".." ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match "^([^=]+)=(.*)$") {
            [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), "Process")
        }
    }
}

$OraclePassword  = $env:ORACLE_PASSWORD
$LogSchemaPass   = $env:LOG_SCHEMA_PASS
$OracleHost      = if ($env:ORACLE_HOST)    { $env:ORACLE_HOST }    else { "localhost" }
$OraclePort      = if ($env:ORACLE_PORT)    { $env:ORACLE_PORT }    else { "1521" }
$OracleService   = if ($env:ORACLE_SERVICE) { $env:ORACLE_SERVICE } else { "XEPDB1" }

if (-not $OraclePassword) {
    Write-Error "ORACLE_PASSWORD が設定されていません。.env ファイルを確認してください。"
    exit 1
}
if (-not $LogSchemaPass) {
    Write-Error "LOG_SCHEMA_PASS が設定されていません。.env ファイルを確認してください。"
    exit 1
}

# RunName に英数字・アンダースコア・ハイフン以外が含まれる場合は拒否 (L-4: SQLインジェクション対策)
if ($RunName -notmatch '^[A-Za-z0-9_\-]+$') {
    Write-Error "RunName に使用できない文字が含まれています。英数字・_・- のみ使用可能です: $RunName"
    exit 1
}

# --- ログ設定 ---
$LogDir  = Join-Path $PSScriptRoot ".." "logs"
$LogFile = Join-Path $LogDir ("migration_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

$StartTime = Get-Date

Write-Log "========================================================"
Write-Log "Migration started. RunName: $RunName  BatchSize: $BatchSize"
Write-Log "========================================================"

# --- コンテナ起動確認 ---
Write-Log "Checking Oracle container health..."
$containerStatus = docker inspect --format='{{.State.Health.Status}}' oracle-migration-db 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: oracle-migration-db コンテナが見つかりません。"
    Write-Log "       docker compose up -d を実行してください。"
    exit 1
}
if ($containerStatus -ne "healthy") {
    Write-Log "ERROR: コンテナがまだ準備できていません。Status: $containerStatus"
    Write-Log "       docker compose ps で状態を確認してください。"
    exit 1
}
Write-Log "Oracle container is healthy."

# --- 移行実行 ---
$ConnStr = "log_schema/${LogSchemaPass}@//${OracleHost}:${OraclePort}/${OracleService}"
Write-Log "Executing migration package (pkg_migration.migrate_all)..."

$sqlInput = @"
SET ECHO OFF
SET FEEDBACK ON
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT SQL.SQLCODE
EXECUTE log_schema.pkg_migration.migrate_all('$RunName', $BatchSize);
EXIT 0;
"@

$sqlOutput = $sqlInput | sqlplus -s $ConnStr 2>&1
$exitCode  = $LASTEXITCODE

$sqlOutput | ForEach-Object { Write-Log $_ }

Write-Log "========================================================"
if ($exitCode -eq 0) {
    Write-Log "Migration completed successfully. RunName: $RunName"
} else {
    Write-Log "Migration FAILED. ExitCode: $exitCode  RunName: $RunName"
    Write-Log "DBログを確認: SELECT * FROM log_schema.migration_error_log ORDER BY occurred_at DESC;"
}
$elapsed = [int](((Get-Date) - $StartTime).TotalSeconds)
Write-Log "Elapsed: $elapsed seconds."
Write-Log "Log file: $LogFile"
Write-Log "========================================================"

exit $exitCode
