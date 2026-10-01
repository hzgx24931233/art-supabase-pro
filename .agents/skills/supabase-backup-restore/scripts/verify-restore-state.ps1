[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$BackupPath,
  [ValidatePattern('^[a-z0-9]{20}$')][string]$TargetProjectRef,
  [string]$LocalRoot,
  [string]$PasswordEnvVar = 'RESTORE_DB_PASSWORD',
  [int]$ByteSampleCount = 2
)

# Read-only acceptance check for a restored Supabase snapshot. It never writes to the
# target; it compares the live database and Storage against the backup's own metadata.
# Pass exactly one of -TargetProjectRef (remote project) or -LocalRoot (local stack).

$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$common = Join-Path $repoRoot 'supabase\transfer-common.ps1'
if (-not (Test-Path -LiteralPath $common -PathType Leaf)) {
  throw "Cannot find supabase/transfer-common.ps1 above this script; run it from the art-supabase-pro checkout."
}
. $common

if ([bool]$TargetProjectRef -eq [bool]$LocalRoot) {
  throw 'Pass exactly one of -TargetProjectRef (remote project) or -LocalRoot (local stack).'
}

$BackupPath = (Resolve-Path -LiteralPath $BackupPath).Path
$manifest = Get-Content -LiteralPath (Join-Path $BackupPath 'manifest.json') -Raw | ConvertFrom-Json
Assert-BackupManifest -Root $BackupPath -Manifest $manifest -TargetProjectRef $TargetProjectRef
Write-Host "Backup verified: $BackupPath"

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
  param([string]$Name, [bool]$Passed, [string]$Detail)
  $results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail })
  $colour = if ($Passed) { 'Green' } else { 'Red' }
  $label = if ($Passed) { 'PASS' } else { 'FAIL' }
  Write-Host ("[{0}] {1} - {2}" -f $label, $Name, $Detail) -ForegroundColor $colour
}
function Add-Note {
  param([string]$Name, [string]$Detail)
  Write-Host ("[INFO] {0} - {1}" -f $Name, $Detail)
}

$stage = $null
$pushedLocation = $false
$localMode = [bool]$LocalRoot
$apiUrl = $null
$serviceRoleKey = $null
$targetConnection = $null
$effectivePassword = $null

try {
  if ($TargetProjectRef) {
    Enable-SystemProxyForSupabaseCli | Out-Null
    $effectivePassword = [Environment]::GetEnvironmentVariable($PasswordEnvVar, 'Process')
    if ([string]::IsNullOrWhiteSpace($effectivePassword)) {
      throw "$PasswordEnvVar is not set. Set it to the target database password before running this check."
    }
    # Link inside a throwaway stage directory so this check never re-links the repository.
    $stage = Join-Path ([IO.Path]::GetTempPath()) "supabase-verify-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path (Join-Path $stage 'supabase') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $BackupPath 'config.toml') -Destination (Join-Path $stage 'supabase\config.toml')
    # Stay in the stage directory for the whole run so every Supabase CLI call keeps its
    # caches here instead of writing them into the repository checkout.
    Push-Location $stage
    $pushedLocation = $true
    $link = Invoke-SupabaseQuiet @('link', '--project-ref', $TargetProjectRef, '--password', $effectivePassword)
    if (-not $link.Succeeded) { throw "Unable to link $TargetProjectRef. $($link.Error)" }
    $pooler = Get-PoolerDatabaseConnection -ProjectRef $TargetProjectRef
    if (-not $pooler) {
      throw 'No IPv4 connection pooler was recorded for the target. Re-run supabase link and retry.'
    }
    $targetConnection = "host=$($pooler.Host) port=$($pooler.Port) dbname=$($pooler.Database) user=$($pooler.User) sslmode=require"
    $apiUrl = "https://$TargetProjectRef.supabase.co"
  }
  else {
    $LocalRoot = [IO.Path]::GetFullPath($LocalRoot)
    if (-not (Test-Path -LiteralPath $LocalRoot -PathType Container)) { throw "Local stack directory not found: $LocalRoot" }
    Push-Location $LocalRoot
    try {
      $statusResult = Invoke-SupabaseQuiet @('status', '--output', 'json')
      if (-not $statusResult.Succeeded) { throw "supabase status failed; is the local stack running? $($statusResult.Error)" }
      $status = $statusResult.Output | ConvertFrom-Json
    }
    finally { Pop-Location }
    if (-not $status.DB_URL -or -not $status.API_URL -or -not $status.SERVICE_ROLE_KEY) {
      throw 'Local Supabase status is missing DB_URL, API_URL, or SERVICE_ROLE_KEY.'
    }
    $dbUri = [uri]$status.DB_URL
    $userInfo = [uri]::UnescapeDataString($dbUri.UserInfo) -split ':', 2
    if ($userInfo.Count -ne 2) { throw 'The local DB_URL has no database credentials.' }
    $effectivePassword = $userInfo[1]
    # Reaching the host's Postgres from the psql container.
    $targetConnection = "host=host.docker.internal port=$($dbUri.Port) dbname=$($dbUri.AbsolutePath.TrimStart('/')) user=$($userInfo[0]) sslmode=disable"
    $apiUrl = [string]$status.API_URL
    $serviceRoleKey = [string]$status.SERVICE_ROLE_KEY
  }

  function Invoke-CheckQuery {
    param([Parameter(Mandatory = $true)][string]$Sql)
    $dockerArguments = @('run', '--rm')
    if ($localMode) { $dockerArguments += @('--add-host', 'host.docker.internal:host-gateway') }
    $dockerArguments += @('-e', 'PGPASSWORD', '-v', "${BackupPath}:/backup:ro", 'postgres:17-alpine',
      'psql', $targetConnection, '--variable', 'ON_ERROR_STOP=1', '-A', '-t', '--command', $Sql)
    $previousPassword = [Environment]::GetEnvironmentVariable('PGPASSWORD', 'Process')
    $previousPreference = $ErrorActionPreference
    try {
      $env:PGPASSWORD = $effectivePassword
      $ErrorActionPreference = 'Continue'
      $output = & docker @dockerArguments 2>&1
      $exitCode = $LASTEXITCODE
    }
    finally {
      $ErrorActionPreference = $previousPreference
      [Environment]::SetEnvironmentVariable('PGPASSWORD', $previousPassword, 'Process')
    }
    if ($exitCode -ne 0) {
      throw "Database check failed: $(($output | Out-String).Trim())"
    }
    return (($output | Out-String).Trim())
  }

  Write-Host ''
  Write-Host '--- database and Storage state ---'

  $reportSql = @'
select json_build_object(
  'public_tables', (select count(*) from pg_tables where schemaname = 'public'),
  'public_functions', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'),
  'public_policies', (select count(*) from pg_policies where schemaname = 'public'),
  'app_private_policies', (select count(*) from pg_policies where schemaname = 'app_private'),
  'tables_without_rls', (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  'auth_users', case when to_regclass('auth.users') is null then -1 else (select count(*) from auth.users) end,
  'buckets', case when to_regclass('storage.buckets') is null then -1 else (select count(*) from storage.buckets) end,
  'storage_objects', case when to_regclass('storage.objects') is null then -1 else (select count(*) from storage.objects) end,
  'spurious_storage_objects', case when to_regclass('storage.objects') is null then -1 else (select count(*) from storage.objects where name like bucket_id || '/%') end,
  'not_valid_checks', (select count(*) from pg_constraint con join pg_class c on c.oid = con.conrelid where con.contype = 'c' and not con.convalidated and pg_catalog.pg_get_userbyid(c.relowner) = current_user),
  'migration_history_rows', case when to_regclass('supabase_migrations.schema_migrations') is null then -1 else (select count(*) from supabase_migrations.schema_migrations) end
)
'@
  $report = (Invoke-CheckQuery -Sql $reportSql | ConvertFrom-Json)

  $expectedObjects = 0
  $countsPath = Join-Path $BackupPath 'metadata\storage-object-counts.json'
  if (Test-Path -LiteralPath $countsPath -PathType Leaf) {
    # Read the object_count column instead of iterating rows: Windows PowerShell can
    # collapse a JSON top-level array into one object whose properties are arrays.
    $countsJson = Get-Content -LiteralPath $countsPath -Raw | ConvertFrom-Json
    $expectedObjects = [int](@($countsJson.object_count) | Measure-Object -Sum).Sum
  }
  $bucketsJson = Get-Content -LiteralPath (Join-Path $BackupPath 'metadata\storage-buckets.json') -Raw | ConvertFrom-Json
  $expectedBuckets = @($bucketsJson.id).Count

  $schemaPath = Join-Path $BackupPath 'database\schema.sql'
  $expectedPolicies = 0
  $expectedNotValid = 0
  if (Test-Path -LiteralPath $schemaPath -PathType Leaf) {
    $schemaText = [IO.File]::ReadAllText($schemaPath)
    $expectedPolicies = ([regex]::Matches($schemaText, '(?m)^CREATE POLICY ')).Count
    $expectedNotValid = ([regex]::Matches($schemaText, 'NOT VALID')).Count
  }

  Add-Result 'Application schema imported' ([int]$report.public_tables -gt 0) `
    ("public tables = " + $report.public_tables + ", public functions = " + $report.public_functions)
  Add-Result 'RLS enabled on every public table' ([int]$report.tables_without_rls -eq 0) `
    ("public tables without RLS = " + $report.tables_without_rls)
  Add-Result 'RLS policies restored' (([int]$report.public_policies + [int]$report.app_private_policies) -eq $expectedPolicies) `
    ("public = " + $report.public_policies + ", app_private = " + $report.app_private_policies + ", backup CREATE POLICY statements = " + $expectedPolicies)
  Add-Result 'Storage bucket metadata restored' ([int]$report.buckets -eq $expectedBuckets) `
    ("buckets = " + $report.buckets + ", expected = " + $expectedBuckets)
  Add-Result 'Storage object metadata restored' ([int]$report.storage_objects -eq $expectedObjects) `
    ("objects = " + $report.storage_objects + ", expected = " + $expectedObjects)
  Add-Result 'No Storage objects at doubled bucket path' ([int]$report.spurious_storage_objects -eq 0) `
    ("objects whose name starts with the bucket id = " + $report.spurious_storage_objects)
  Add-Result 'Deferred NOT VALID constraints restored' ([int]$report.not_valid_checks -ge $expectedNotValid) `
    ("live NOT VALID checks the restore owns = " + $report.not_valid_checks + ", declared in backup schema = " + $expectedNotValid)

  Add-Note 'Auth users' ("auth.users rows = " + $report.auth_users + " (auth.identities is not part of a snapshot)")
  Add-Note 'Migration history' $(if ([int]$report.migration_history_rows -lt 0) { 'schema_migrations table not present' } else { "rows = " + $report.migration_history_rows + " (recipient packages carry no history rows)" })

  if ($ByteSampleCount -gt 0) {
    Write-Host ''
    Write-Host "--- Storage byte sample (up to $ByteSampleCount per bucket) ---"
    if (-not $serviceRoleKey) { $serviceRoleKey = Get-SupabaseServiceRoleKey -ProjectRef $TargetProjectRef }
    $headers = New-StorageAdminHeaders -Key $serviceRoleKey
    $tempFile = Join-Path ([IO.Path]::GetTempPath()) ("supabase-verify-$([guid]::NewGuid()).bin")
    $checked = 0
    $mismatched = 0
    try {
      foreach ($bucketDir in @(Get-ChildItem -LiteralPath (Join-Path $BackupPath 'storage') -Directory)) {
        $bucketRoot = Get-StorageBucketRoot -BucketDirectory $bucketDir.FullName
        $ordered = @(Get-ChildItem -LiteralPath $bucketRoot -File -Recurse | Sort-Object Length)
        if ($ordered.Count -eq 0) { continue }
        $picks = @($ordered | Select-Object -First 1)
        if ($ordered.Count -gt 1) { $picks += @($ordered | Select-Object -Last 1) }
        if ($ordered.Count -gt 2) {
          $randomCount = [Math]::Min($ByteSampleCount - 2, $ordered.Count - 2)
          if ($randomCount -ge 1) { $picks += @($ordered | Get-Random -Count $randomCount) }
        }
        foreach ($file in @($picks | Sort-Object FullName -Unique)) {
          $objectName = $file.FullName.Substring($bucketRoot.Length + 1).Replace('\', '/')
          $uri = "$($apiUrl.TrimEnd('/'))/storage/v1/object/$([uri]::EscapeDataString($bucketDir.Name))/$(ConvertTo-StorageApiPath $objectName)"
          Invoke-WebRequest -Method Get -Uri $uri -Headers $headers -OutFile $tempFile -UseBasicParsing -TimeoutSec 300 | Out-Null
          $checked++
          if ((Get-FileHash -LiteralPath $tempFile -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
            $mismatched++
            Write-Host ("       mismatch: " + $bucketDir.Name + "/" + $objectName) -ForegroundColor Red
          }
        }
      }
    }
    finally { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
    Add-Result 'Storage bytes match the backup' ($mismatched -eq 0) ("objects compared = " + $checked + ", SHA-256 mismatches = " + $mismatched)
  }

  $failed = @($results | Where-Object { -not $_.Passed })
  Write-Host ''
  if ($failed.Count -eq 0) {
    Write-Host ("Restore accepted: " + $results.Count + " checks passed.") -ForegroundColor Green
  }
  else {
    Write-Host ("Restore NOT accepted: " + $failed.Count + " of " + $results.Count + " checks failed.") -ForegroundColor Red
    foreach ($item in $failed) { Write-Host ("  - " + $item.Name + ": " + $item.Detail) -ForegroundColor Red }
  }
}
finally {
  if ($pushedLocation) { Pop-Location }
  if ($stage -and (Test-Path -LiteralPath $stage -PathType Container)) {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if (@($results | Where-Object { -not $_.Passed }).Count -gt 0) { exit 1 }
exit 0
