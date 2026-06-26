<?php

function env_or_default(string $key, string $fallback): string
{
    $value = getenv($key);
    if ($value === false) {
        return $fallback;
    }

    $value = trim($value);
    return $value === '' ? $fallback : $value;
}

function env_int(string $key, int $fallback): int
{
    $value = getenv($key);
    if ($value === false || trim($value) === '') {
        return $fallback;
    }

    $parsed = filter_var($value, FILTER_VALIDATE_INT);
    return $parsed === false ? $fallback : $parsed;
}

function env_bool(string $key, bool $fallback): bool
{
    $value = getenv($key);
    if ($value === false || trim($value) === '') {
        return $fallback;
    }

    return in_array(strtolower(trim($value)), ['1', 'true', 'yes', 'on'], true);
}

function ensure_benchmark_rows(PDO $pdo, int $targetRows, string $tableName): void
{
    $pdo->exec("
        CREATE TABLE IF NOT EXISTS $tableName (
            id INT PRIMARY KEY,
            name VARCHAR(64) NOT NULL,
            amount DECIMAL(10, 2) NOT NULL,
            created_at DATETIME NOT NULL,
            payload TEXT NOT NULL
        )
    ");

    $existingRows = (int)$pdo->query("SELECT COUNT(*) FROM $tableName")->fetchColumn();
    if ($existingRows >= $targetRows) {
        return;
    }

    $pdo->exec("TRUNCATE TABLE $tableName");

    $batchSize = 500;
    for ($start = 1; $start <= $targetRows; $start += $batchSize) {
        $end = min($targetRows, $start + $batchSize - 1);
        $values = [];

        for ($id = $start; $id <= $end; $id++) {
            $cents = str_pad((string)($id % 100), 2, '0', STR_PAD_LEFT);
            $second = str_pad((string)($id % 60), 2, '0', STR_PAD_LEFT);
            $payloadId = str_pad((string)$id, 5, '0', STR_PAD_LEFT);
            $values[] = sprintf(
                "(%d,'name_%d',%d.%s,'2024-01-01 12:34:%s','payload_%s_abcdefghijklmnopqrstuvwxyz')",
                $id,
                $id,
                $id,
                $cents,
                $second,
                $payloadId
            );
        }

        $pdo->exec(
            "INSERT INTO $tableName (id, name, amount, created_at, payload) VALUES " . implode(',', $values)
        );
    }
}

function benchmark_result_set(
    PDO $pdo,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    $query = "SELECT id, name, amount, created_at, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        $stmt = $pdo->query($query);
        while (($row = $stmt->fetch(PDO::FETCH_NUM)) !== false) {
            $checksum += (int)$row[0]
                + strlen((string)$row[1])
                + strlen((string)$row[2])
                + strlen((string)$row[3])
                + strlen((string)$row[4]);
        }
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        $stmt = $pdo->query($query);
        while (($row = $stmt->fetch(PDO::FETCH_NUM)) !== false) {
            $checksum += (int)$row[0]
                + strlen((string)$row[1])
                + strlen((string)$row[2])
                + strlen((string)$row[3])
                + strlen((string)$row[4]);
            $rowCount++;
        }
    }
    $elapsedNs = hrtime(true) - $start;
    $elapsedSeconds = $elapsedNs / 1000000000;

    return [
        'rows_per_query' => $size,
        'iterations' => $iterations,
        'warmup_iterations' => $warmupIterations,
        'total_ms' => $elapsedNs / 1000000,
        'avg_ms' => ($elapsedNs / 1000000) / $iterations,
        'queries_per_sec' => $iterations / $elapsedSeconds,
        'rows_per_sec' => $rowCount / $elapsedSeconds,
        'checksum' => $checksum,
    ];
}

$host = env_or_default('MYSQL_HOST', '127.0.0.1');
$port = env_int('MYSQL_PORT', 3306);
$user = env_or_default('MYSQL_USER', 'dart');
$password = env_or_default('MYSQL_PASSWORD', 'dart');
$database = env_or_default('MYSQL_DATABASE', 'banco_teste');
$benchTable = env_or_default('BENCH_TABLE', 'bench_rows_pdo');
$secure = env_bool('MYSQL_SECURE', false);
$iterations = env_int('BENCH_ITERATIONS', 2000);
$connectIterations = env_int('BENCH_CONNECT_ITERATIONS', 25);
$warmupIterations = env_int('BENCH_WARMUP_ITERATIONS', 200);
$resultSetIterations = env_int('BENCH_RESULTSET_ITERATIONS', 20);
$resultSetWarmupIterations = env_int('BENCH_RESULTSET_WARMUP_ITERATIONS', 5);

$dsn = sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4', $host, $port, $database);
$options = [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_NUM,
    PDO::ATTR_EMULATE_PREPARES => false,
];

$sslCa = env_or_default('MYSQL_SSL_CA', '');
if ($secure) {
    if ($sslCa !== '') {
        $options[PDO::MYSQL_ATTR_SSL_CA] = $sslCa;
    }
    $options[PDO::MYSQL_ATTR_SSL_VERIFY_SERVER_CERT] = false;
}

$pdo = new PDO($dsn, $user, $password, $options);
$server = $pdo->query('SELECT VERSION() AS version, @@version_comment AS comment, @@port AS port')
    ->fetch(PDO::FETCH_ASSOC);
$pdo = null;

$connectStart = hrtime(true);
for ($i = 0; $i < $connectIterations; $i++) {
    $pdo = new PDO($dsn, $user, $password, $options);
    $pdo = null;
}
$connectElapsedNs = hrtime(true) - $connectStart;

$pdo = new PDO($dsn, $user, $password, $options);
ensure_benchmark_rows($pdo, 10000, $benchTable);

$textChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    $row = $pdo->query('SELECT 1')->fetch();
    $textChecksum += (int)$row[0];
}

$textStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    $row = $pdo->query('SELECT 1')->fetch();
    $textChecksum += (int)$row[0];
}
$textElapsedNs = hrtime(true) - $textStart;

$arrayStmt = $pdo->prepare('SELECT ? + ?');
$preparedArrayChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    $arrayStmt->execute([40, 2]);
    $row = $arrayStmt->fetch(PDO::FETCH_NUM);
    $preparedArrayChecksum += (int)$row[0];
}

$preparedArrayStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    $arrayStmt->execute([40, 2]);
    $row = $arrayStmt->fetch(PDO::FETCH_NUM);
    $preparedArrayChecksum += (int)$row[0];
}
$preparedArrayElapsedNs = hrtime(true) - $preparedArrayStart;

$stmt = $pdo->prepare('SELECT ? + ?');
$a = 40;
$b = 2;
$stmt->bindParam(1, $a, PDO::PARAM_INT);
$stmt->bindParam(2, $b, PDO::PARAM_INT);

$preparedChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    $stmt->execute();
    $row = $stmt->fetch(PDO::FETCH_NUM);
    $preparedChecksum += (int)$row[0];
}

$preparedStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    $stmt->execute();
    $row = $stmt->fetch(PDO::FETCH_NUM);
    $preparedChecksum += (int)$row[0];
}
$preparedElapsedNs = hrtime(true) - $preparedStart;

$resultSets = [
    'rows_10' => benchmark_result_set($pdo, $benchTable, 10, $resultSetWarmupIterations, $resultSetIterations),
    'rows_1000' => benchmark_result_set($pdo, $benchTable, 1000, $resultSetWarmupIterations, $resultSetIterations),
    'rows_10000' => benchmark_result_set($pdo, $benchTable, 10000, $resultSetWarmupIterations, $resultSetIterations),
];

$pdo = null;

$connectTotalMs = $connectElapsedNs / 1000000;
$textTotalMs = $textElapsedNs / 1000000;
$preparedArrayTotalMs = $preparedArrayElapsedNs / 1000000;
$preparedTotalMs = $preparedElapsedNs / 1000000;

echo json_encode([
    'driver' => 'php_pdo_mysql',
    'host' => $host,
    'port' => $port,
    'database' => $database,
    'secure' => $secure,
    'connect_mode' => 'warm_auth_cache',
    'warmup_iterations' => $warmupIterations,
    'resultset_warmup_iterations' => $resultSetWarmupIterations,
    'server' => $server,
    'connect_iterations' => $connectIterations,
    'connect_total_ms' => $connectTotalMs,
    'connect_avg_ms' => $connectTotalMs / $connectIterations,
    'iterations' => $iterations,
    'text_total_ms' => $textTotalMs,
    'text_avg_ms' => $textTotalMs / $iterations,
    'text_ops_per_sec' => $iterations / ($textElapsedNs / 1000000000),
    'text_checksum' => $textChecksum,
    'prepared_array_total_ms' => $preparedArrayTotalMs,
    'prepared_array_avg_ms' => $preparedArrayTotalMs / $iterations,
    'prepared_array_ops_per_sec' => $iterations / ($preparedArrayElapsedNs / 1000000000),
    'prepared_array_checksum' => $preparedArrayChecksum,
    'prepared_total_ms' => $preparedTotalMs,
    'prepared_avg_ms' => $preparedTotalMs / $iterations,
    'prepared_ops_per_sec' => $iterations / ($preparedElapsedNs / 1000000000),
    'prepared_checksum' => $preparedChecksum,
    'result_sets' => $resultSets,
], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), PHP_EOL;
