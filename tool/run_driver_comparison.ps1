param(
  [string]$PhpPath = "C:\php\php-8.3.11-nts\php.exe",
  [string]$HostName = $(if ($env:MYSQL_HOST) { $env:MYSQL_HOST } else { "127.0.0.1" }),
  [int]$Port = $(if ($env:MYSQL_PORT) { [int]$env:MYSQL_PORT } else { 3308 }),
  [string]$User = $(if ($env:MYSQL_USER) { $env:MYSQL_USER } else { "dart" }),
  [string]$Password = $(if ($env:MYSQL_PASSWORD) { $env:MYSQL_PASSWORD } else { "dart" }),
  [string]$Database = $(if ($env:MYSQL_DATABASE) { $env:MYSQL_DATABASE } else { "banco_teste" }),
  [string]$Secure = $(if ($env:MYSQL_SECURE) { $env:MYSQL_SECURE } else { "false" }),
  [int]$Iterations = $(if ($env:BENCH_ITERATIONS) { [int]$env:BENCH_ITERATIONS } else { 2000 }),
  [int]$ConnectIterations = $(if ($env:BENCH_CONNECT_ITERATIONS) { [int]$env:BENCH_CONNECT_ITERATIONS } else { 25 }),
  [int]$ResultSetIterations = $(if ($env:BENCH_RESULTSET_ITERATIONS) { [int]$env:BENCH_RESULTSET_ITERATIONS } else { 20 }),
  [int]$WarmupIterations = $(if ($env:BENCH_WARMUP_ITERATIONS) { [int]$env:BENCH_WARMUP_ITERATIONS } else { 200 }),
  [int]$ResultSetWarmupIterations = $(if ($env:BENCH_RESULTSET_WARMUP_ITERATIONS) { [int]$env:BENCH_RESULTSET_WARMUP_ITERATIONS } else { 5 })
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$resultsDir = Join-Path $root "benchmark\reports\driver-comparison"
$tmpRoot = Join-Path $root ".benchmark_workspace"
$dart121Dir = Join-Path $tmpRoot "mysql_dart_1_2_1"
$composerPhar = "C:\ProgramData\ComposerSetup\bin\composer.phar"

function Convert-BenchBool([string]$value) {
  switch ($value.Trim().ToLowerInvariant()) {
    "1" { return $true }
    "true" { return $true }
    "yes" { return $true }
    "on" { return $true }
    "0" { return $false }
    "false" { return $false }
    "no" { return $false }
    "off" { return $false }
    default { throw "Invalid boolean value: $value" }
  }
}

$secureBool = Convert-BenchBool $Secure

New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
New-Item -ItemType Directory -Force -Path $dart121Dir | Out-Null

function Set-BenchEnv([string]$driverName, [string]$benchTable) {
  $env:MYSQL_HOST = $HostName
  $env:MYSQL_PORT = "$Port"
  $env:MYSQL_USER = $User
  $env:MYSQL_PASSWORD = $Password
  $env:MYSQL_DATABASE = $Database
  $env:MYSQL_SECURE = if ($secureBool) { "true" } else { "false" }
  $env:BENCH_DRIVER_NAME = $driverName
  $env:BENCH_TABLE = $benchTable
  $env:BENCH_ITERATIONS = "$Iterations"
  $env:BENCH_CONNECT_ITERATIONS = "$ConnectIterations"
  $env:BENCH_RESULTSET_ITERATIONS = "$ResultSetIterations"
  $env:BENCH_WARMUP_ITERATIONS = "$WarmupIterations"
  $env:BENCH_RESULTSET_WARMUP_ITERATIONS = "$ResultSetWarmupIterations"
}

function Run-And-Capture([string]$name, [scriptblock]$command) {
  $outPath = Join-Path $resultsDir "$name.json"
  $errPath = Join-Path $resultsDir "$name.err.txt"
  Write-Host "Running $name..."
  try {
    $output = & $command 2> $errPath
    if ($LASTEXITCODE -ne 0) {
      throw "Command exited with code $LASTEXITCODE"
    }
    $lastLine = ($output | Where-Object { $_ -and $_.Trim() -ne "" } | Select-Object -Last 1)
    if (-not $lastLine) {
      throw "Command produced no JSON output"
    }
    $lastLine | Set-Content -Path $outPath -Encoding UTF8
  } catch {
    $message = $_.Exception.Message
    $payload = [ordered]@{
      driver = $name
      error = $message
      stderr = if (Test-Path $errPath) { (Get-Content $errPath -Raw) } else { "" }
    }
    ($payload | ConvertTo-Json -Depth 4 -Compress) | Set-Content -Path $outPath -Encoding UTF8
    Write-Warning "$name failed: $message"
  }
}

if (-not (Test-Path (Join-Path $root "tool\php_benchmark\vendor\autoload.php"))) {
  Push-Location (Join-Path $root "tool\php_benchmark")
  & $PhpPath $composerPhar require react/mysql amphp/mysql --no-interaction
  Pop-Location
}

Set-BenchEnv "mysql_dart_2_0_0" "bench_rows_dart_200"
Run-And-Capture "mysql_dart_2_0_0" {
  dart run (Join-Path $root "tool\benchmark_mysql_dart_compat.dart")
}

@"
name: mysql_dart_1_2_1_benchmark
publish_to: none
environment:
  sdk: '>=2.16.0 <4.0.0'
dependencies:
  mysql_dart: 1.2.1
"@ | Set-Content -Path (Join-Path $dart121Dir "pubspec.yaml") -Encoding UTF8

Copy-Item -Force (Join-Path $root "tool\benchmark_mysql_dart_compat.dart") (Join-Path $dart121Dir "benchmark_mysql_dart_compat.dart")
Push-Location $dart121Dir
dart pub get
Pop-Location

Set-BenchEnv "mysql_dart_1_2_1" "bench_rows_dart_121"
Run-And-Capture "mysql_dart_1_2_1" {
  Push-Location $dart121Dir
  try {
    dart run .\benchmark_mysql_dart_compat.dart
  } finally {
    Pop-Location
  }
}

Set-BenchEnv "php_pdo_mysql" "bench_rows_pdo"
Run-And-Capture "php_pdo_mysql" {
  & $PhpPath (Join-Path $root "tool\benchmark_mysql_php.php")
}

Set-BenchEnv "php_mysqli" "bench_rows_mysqli"
Run-And-Capture "php_mysqli" {
  & $PhpPath (Join-Path $root "tool\benchmark_mysql_mysqli.php")
}

if (-not $secureBool) {
  Set-BenchEnv "php_react_mysql" "bench_rows_reactphp"
  Run-And-Capture "php_react_mysql" {
    & $PhpPath (Join-Path $root "tool\benchmark_mysql_reactphp.php")
  }

  Set-BenchEnv "php_amphp_mysql" "bench_rows_amphp"
  Run-And-Capture "php_amphp_mysql" {
    & $PhpPath (Join-Path $root "tool\benchmark_mysql_amphp.php")
  }
} else {
  Write-Warning "Skipping react/mysql and amphp/mysql in secure mode; these benchmark scripts are plain TCP only."
}

Write-Host "Results written to $resultsDir"
