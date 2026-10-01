[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$BackupPath,
  [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9]{20}$')][string]$TargetProjectRef,
  [securestring]$TargetDbPassword,
  [switch]$VerifyBackupOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'transfer-common.ps1')

$BackupPath = (Resolve-Path -LiteralPath $BackupPath).Path

function Invoke-Supabase {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & supabase @Arguments
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($exitCode -ne 0) { throw 'A Supabase CLI command failed. See the preceding command output.' }
}

function Test-HostResolvesOverIpv4 {
  param([Parameter(Mandatory = $true)][string]$HostName)

  try { $addresses = [System.Net.Dns]::GetHostAddresses($HostName) }
  catch { return $false }
  return @($addresses | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }).Count -gt 0
}

function Get-PoolerDatabaseConnection {
  param([Parameter(Mandatory = $true)][string]$ProjectRef)

  # 'supabase link' ran in this temporary stage directory, so the recorded pooler
  # belongs to the target project.
  $poolerPath = Join-Path (Get-Location).Path 'supabase\.temp\pooler-url'
  if (-not (Test-Path -LiteralPath $poolerPath -PathType Leaf)) { return $null }

  $uri = $null
  $poolerUrl = (Get-Content -LiteralPath $poolerPath -Raw).Trim()
  if (-not [uri]::TryCreate($poolerUrl, [UriKind]::Absolute, [ref]$uri)) { return $null }
  if ($uri.Scheme -notmatch '^postgres(ql)?$') { return $null }
  # Transaction mode (6543) would not keep session_replication_role for the data import.
  if ($uri.Port -ne 5432) { return $null }

  $user = ([uri]::UnescapeDataString($uri.UserInfo) -split ':')[0]
  $database = $uri.AbsolutePath.TrimStart('/')
  if ([string]::IsNullOrWhiteSpace($uri.Host) -or [string]::IsNullOrWhiteSpace($user) -or
      [string]::IsNullOrWhiteSpace($database)) { return $null }
  if ($user -match '^postgres\.([a-z0-9]{20})$' -and $Matches[1] -ne $ProjectRef) { return $null }

  return @{ Host = $uri.Host; Port = [string]$uri.Port; User = $user; Database = $database }
}

function Get-LinkedDatabaseConnection {
  param(
    [Parameter(Mandatory = $true)][string]$Password,
    [Parameter(Mandatory = $true)][string]$ProjectRef
  )
  $dryRun = Invoke-SupabaseQuiet @('db', 'dump', '--linked', '--password', $Password, '--data-only', '--dry-run')
  if (-not $dryRun.Succeeded) { throw 'Unable to resolve the linked target database connection.' }
  $text = $dryRun.Output
  $dbHost = [regex]::Match($text, 'export PGHOST="([^"]+)"').Groups[1].Value
  $port = [regex]::Match($text, 'export PGPORT="([^"]+)"').Groups[1].Value
  $user = [regex]::Match($text, 'export PGUSER="([^"]+)"').Groups[1].Value
  $database = [regex]::Match($text, 'export PGDATABASE="([^"]+)"').Groups[1].Value
  if ([string]::IsNullOrWhiteSpace($dbHost) -or $port -notmatch '^\d+$' -or
      [string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($database)) {
    throw 'Unable to parse the target database connection.'
  }
  $connection = @{ Host = $dbHost; Port = $port; User = $user; Database = $database }

  # Newer projects publish only an AAAA record for the direct database host, and
  # Docker Desktop containers have no IPv6 route, so connect through the IPv4 pooler.
  if (Test-HostResolvesOverIpv4 -HostName $dbHost) { return $connection }
  $pooler = Get-PoolerDatabaseConnection -ProjectRef $ProjectRef
  if (-not $pooler) {
    Write-Warning "The direct database host '$dbHost' has no IPv4 address and no session pooler was recorded; the restore may fail to connect."
    return $connection
  }
  Write-Host "Direct database host is IPv6-only; connecting through the IPv4 pooler $($pooler.Host)..."
  return $pooler
}

function Test-DockerReady {
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & docker version --format '{{.Server.Version}}' *> $null
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
  }
  return ($exitCode -eq 0)
}

function Invoke-PsqlRestore {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Connection,
    [Parameter(Mandatory = $true)][string]$Password
  )

  # A NOT VALID CHECK constraint was never verified against the source rows, so the
  # backup's own data can violate it and COPY would still reject those rows. Defer the
  # constraints this session may drop to after the data import, then add them back
  # NOT VALID, which is the state the source database was in.
  $deferNotValidConstraints = @'
create temp table _restore_not_valid_checks as
select format('alter table %I.%I add constraint %I %s', n.nspname, c.relname, con.conname, pg_get_constraintdef(con.oid)) as readd,
       format('alter table %I.%I drop constraint %I', n.nspname, c.relname, con.conname) as drop_stmt
from pg_constraint con
join pg_class c on c.oid = con.conrelid
join pg_namespace n on n.oid = c.relnamespace
where con.contype = 'c' and not con.convalidated
  and pg_catalog.pg_get_userbyid(c.relowner) = current_user;
do $$ declare r record; begin
  for r in select drop_stmt from _restore_not_valid_checks loop execute r.drop_stmt; end loop;
end $$;
'@

  $restoreNotValidConstraints = @'
do $$ declare r record; begin
  for r in select readd from _restore_not_valid_checks loop execute r.readd; end loop;
end $$;
drop table _restore_not_valid_checks;
'@

  # Keep the SQL files in the order specified by Supabase's logical restore guide.
  # One psql session makes session_replication_role and the deferred constraints apply
  # to the data import. schema.sql must commit per statement: hosted projects cap
  # max_locks_per_transaction well below what a schema of this size needs, and one
  # wrapping transaction exhausts the shared lock table. Only the data import keeps a
  # transaction of its own.
  $previousPassword = [Environment]::GetEnvironmentVariable('PGPASSWORD', 'Process')
  $previousPreference = $ErrorActionPreference
  try {
    $env:PGPASSWORD = $Password
    $ErrorActionPreference = 'Continue'
    & docker run --rm -v "${BackupPath}:/backup:ro" -e PGPASSWORD postgres:17-alpine `
      psql "host=$($Connection.Host) port=$($Connection.Port) dbname=$($Connection.Database) user=$($Connection.User) sslmode=require" `
      --variable ON_ERROR_STOP=1 `
      --file /backup/database/roles.sql `
      --file /backup/database/schema.sql `
      --command $deferNotValidConstraints `
      --command 'SET session_replication_role = replica' `
      --command 'BEGIN' `
      --file /backup/database/data.sql `
      --command 'COMMIT' `
      --command $restoreNotValidConstraints `
      --file /backup/database/migration-history-schema.sql `
      --file /backup/database/migration-history-data.sql
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
    [Environment]::SetEnvironmentVariable('PGPASSWORD', $previousPassword, 'Process')
  }
  if ($exitCode -ne 0) { throw 'Database restore failed; Storage and Functions were not imported.' }
}

$manifestPath = Join-Path $BackupPath 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Invalid backup: manifest.json is missing.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Assert-BackupManifest -Root $BackupPath -Manifest $manifest -TargetProjectRef $TargetProjectRef
if ($VerifyBackupOnly) {
  Write-Host "Backup verified: $BackupPath" -ForegroundColor Green
  return
}

if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) { throw 'Supabase CLI is required.' }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  $dockerBin = 'C:\Program Files\Docker\Docker\resources\bin'
  if (Test-Path (Join-Path $dockerBin 'docker.exe')) { $env:Path = "$dockerBin;$env:Path" }
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker Desktop is required for the database restore.' }
if (-not (Test-DockerReady)) { throw 'Docker Desktop is installed but not running.' }
Enable-SystemProxyForSupabaseCli

if (-not $TargetDbPassword) { $TargetDbPassword = Read-Host 'Target Supabase database password' -AsSecureString }
$plainPassword = Get-PlainText $TargetDbPassword

$stage = Join-Path ([IO.Path]::GetTempPath()) "supabase-restore-$([guid]::NewGuid())"
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
if (-not [IO.Path]::GetFullPath($stage).StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path $stage -Leaf) -notmatch '^supabase-restore-[a-f0-9-]{36}$') {
  throw 'Unexpected temporary restore directory.'
}

try {
  Write-Warning "This writes backup '$($manifest.created_at)' to target project $TargetProjectRef. The target must be a new, empty project."
  $confirmation = Read-Host "Type the target project ref ($TargetProjectRef) to continue"
  if ($confirmation -ne $TargetProjectRef) { throw 'Restore cancelled.' }

  New-Item -ItemType Directory -Path (Join-Path $stage 'supabase') -Force | Out-Null
  $backupConfig = Join-Path $BackupPath 'config.toml'
  if (-not (Test-Path -LiteralPath $backupConfig -PathType Leaf)) { throw 'Backup config.toml is missing.' }
  Copy-Item -LiteralPath $backupConfig -Destination (Join-Path $stage 'supabase\config.toml')
  Push-Location $stage
  try {
    Invoke-Supabase @('link', '--project-ref', $TargetProjectRef, '--password', $plainPassword)
    $connection = Get-LinkedDatabaseConnection -Password $plainPassword -ProjectRef $TargetProjectRef
    $tableCheck = Invoke-SupabaseQuiet @('db', 'query', '--linked', '--agent=no', '--output', 'json', "select (select count(*) from pg_tables where schemaname = 'public') + (select count(*) from auth.users) + (select count(*) from storage.buckets) + (select count(*) from storage.objects) as count")
    if (-not $tableCheck.Succeeded) { throw 'Unable to check whether the target project is empty.' }
    $targetRows = @(ConvertFrom-SupabaseJsonArray `
      -Text $tableCheck.Output `
      -Description 'the target project emptiness check')
    if ($targetRows.Count -ne 1 -or $null -eq $targetRows[0].count -or
        $targetRows[0].count -notmatch '^\d+$') {
      throw 'Invalid target project emptiness check; refusing to restore.'
    }
    if ([long]$targetRows[0].count -gt 0) {
      throw 'Target project already contains application tables, Auth users, or Storage data. Refusing to merge; use a new, empty project.'
    }
    $targetFunctionsResult = Invoke-SupabaseQuietWithRetry `
      -Arguments @('functions', 'list', '--project-ref', $TargetProjectRef, '--output', 'json')
    if (-not $targetFunctionsResult.Succeeded) {
      throw 'Unable to check whether the target project already has Edge Functions.'
    }
    $targetFunctions = @(ConvertFrom-SupabaseJsonArray `
      -Text $targetFunctionsResult.Output `
      -Description 'the target Edge Function list')
    if ($targetFunctions.Count -gt 0) {
      throw 'Target project already has deployed Edge Functions. Refusing to overwrite them.'
    }

    Write-Host 'Restoring database roles, schema, and data...'
    Invoke-PsqlRestore -Connection $connection -Password $plainPassword

    $realtimePath = Join-Path $BackupPath 'metadata\realtime-publication-tables.json'
    if (Test-Path $realtimePath) {
      $realtimeTables = @(ConvertFrom-SupabaseJsonArray `
        -Text (Get-Content -Raw $realtimePath) `
        -Description 'the backed-up Realtime publication list')
      $existingOutput = Invoke-SupabaseQuiet @('db', 'query', '--linked', '--agent=no', '--output', 'json', "select schemaname, tablename from pg_publication_tables where pubname = 'supabase_realtime'")
      if (-not $existingOutput.Succeeded) { throw 'Unable to inspect the target Realtime publication.' }
      $existingTables = @(ConvertFrom-SupabaseJsonArray `
        -Text $existingOutput.Output `
        -Description 'the target Realtime publication list')
      $existingNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      foreach ($table in $existingTables) {
        [void]$existingNames.Add("$($table.schemaname).$($table.tablename)")
      }
      foreach ($table in $realtimeTables) {
        if (($table.schemaname -notmatch '^[A-Za-z_][A-Za-z0-9_$]*$') -or ($table.tablename -notmatch '^[A-Za-z_][A-Za-z0-9_$]*$')) {
          throw 'Invalid Realtime table identifier in the backup metadata.'
        }
        if ($existingNames.Contains("$($table.schemaname).$($table.tablename)")) { continue }
        Invoke-Supabase @('db', 'query', '--linked', "alter publication supabase_realtime add table `"$($table.schemaname)`".`"$($table.tablename)`"")
      }
    }

    $storagePath = Join-Path $BackupPath 'storage'
    if (Test-Path $storagePath) {
      $serviceRoleKey = $null
      foreach ($bucket in @(Get-ChildItem -LiteralPath $storagePath -Directory)) {
        # 'storage cp ss:///<bucket> .' downloads into a directory named after the bucket,
        # so a CLI-made backup stores objects one level below the bucket directory.
        $bucketRoot = Join-Path $bucket.FullName $bucket.Name
        if (-not (Test-Path -LiteralPath $bucketRoot -PathType Container)) { $bucketRoot = $bucket.FullName }
        $bucketFiles = @(Get-ChildItem -LiteralPath $bucketRoot -File -Recurse)
        if ($bucketFiles.Count -eq 0) { continue }
        Write-Host "Uploading Storage bucket '$($bucket.Name)' ($($bucketFiles.Count) files)..."
        $copyResult = Invoke-SupabaseQuiet @('storage', 'cp', $bucketRoot, "ss:///$($bucket.Name)", '--recursive', '--experimental')
        if ($copyResult.Succeeded) { continue }
        Write-Warning "Supabase CLI Storage upload failed for '$($bucket.Name)'; retrying through the Storage API. $($copyResult.Error)"
        if (-not $serviceRoleKey) { $serviceRoleKey = Get-SupabaseServiceRoleKey -ProjectRef $TargetProjectRef }
        foreach ($file in $bucketFiles) {
          $objectName = $file.FullName.Substring($bucketRoot.Length + 1).Replace('\', '/')
          Invoke-StorageObjectUpload `
            -ApiUrl "https://$TargetProjectRef.supabase.co" `
            -ServiceRoleKey $serviceRoleKey `
            -BucketId $bucket.Name `
            -ObjectName $objectName `
            -FilePath $file.FullName
        }
      }
      $serviceRoleKey = $null
    }

    $functionsPath = Join-Path $BackupPath 'functions'
    $functionMetadataPath = Join-Path $BackupPath 'metadata\functions.json'
    if ((Test-Path $functionsPath) -and (Test-Path $functionMetadataPath)) {
      Copy-Item -LiteralPath $functionsPath -Destination (Join-Path $stage 'supabase\functions') -Recurse -Force
      $functions = Get-Content -Raw $functionMetadataPath | ConvertFrom-Json
      foreach ($function in $functions) {
        if ($function.slug -notmatch '^[a-z0-9][a-z0-9_-]*$') { throw 'Invalid Edge Function slug in backup metadata.' }
        $arguments = @('functions', 'deploy', $function.slug, '--project-ref', $TargetProjectRef, '--use-api')
        if ($function.verify_jwt -eq $false) { $arguments += '--no-verify-jwt' }
        Invoke-Supabase $arguments
      }
    }

    Write-Host 'Restore completed.' -ForegroundColor Green
    Write-Warning 'Before using Edge Functions, restore the secret values listed in metadata/edge-function-secret-names.json. Supabase deliberately does not allow existing secret values to be exported.'
  }
  finally {
    Pop-Location
  }
}
finally {
  $plainPassword = $null
  if (Test-Path -LiteralPath $stage -PathType Container) {
    Remove-Item -LiteralPath $stage -Recurse -Force
  }
}
