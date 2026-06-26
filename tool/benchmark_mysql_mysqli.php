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

function mysqli_connect_bench(
    string $host,
    int $port,
    string $user,
    string $password,
    string $database,
    bool $secure
): mysqli {
    $mysqli = mysqli_init();
    $flags = 0;

    if ($secure) {
        $flags |= MYSQLI_CLIENT_SSL;

        $ca = getenv('MYSQL_SSL_CA');
        if ($ca !== false && trim($ca) !== '') {
            $mysqli->ssl_set(null, null, trim($ca), null, null);
        }
    }

    $mysqli->real_connect($host, $user, $password, $database, $port, null, $flags);
    return $mysqli;
}

function ensure_benchmark_rows(mysqli $mysqli, int $targetRows, string $tableName): void
{
    $mysqli->query("
        CREATE TABLE IF NOT EXISTS $tableName (
            id INT PRIMARY KEY,
            name VARCHAR(64) NOT NULL,
            amount DECIMAL(10, 2) NOT NULL,
            created_at DATETIME NOT NULL,
            payload TEXT NOT NULL
        )
    ");

    $result = $mysqli->query("SELECT COUNT(*) FROM $tableName");
    $existingRows = (int)$result->fetch_row()[0];
    $result->free();
    if ($existingRows >= $targetRows) {
        return;
    }

    $mysqli->query("TRUNCATE TABLE $tableName");

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

        $mysqli->query(
            "INSERT INTO $tableName (id, name, amount, created_at, payload) VALUES " . implode(',', $values)
        );
    }
}

function benchmark_result_set(
    mysqli $mysqli,
    string $tableName,
    int $size,
    int $warmupIterations,
    int $iterations
): array {
    $query = "SELECT id, name, amount, created_at, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        $result = $mysqli->query($query);
        while (($row = $result->fetch_row()) !== null) {
            $checksum += (int)$row[0]
                + strlen((string)$row[1])
                + strlen((string)$row[2])
                + strlen((string)$row[3])
                + strlen((string)$row[4]);
        }
        $result->free();
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        $result = $mysqli->query($query);
        while (($row = $result->fetch_row()) !== null) {
            $checksum += (int)$row[0]
                + strlen((string)$row[1])
                + strlen((string)$row[2])
                + strlen((string)$row[3])
                + strlen((string)$row[4]);
            $rowCount++;
        }
        $result->free();
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
$benchTable = env_or_default('BENCH_TABLE', 'bench_rows_mysqli');
$secure = env_bool('MYSQL_SECURE', false);
$iterations = env_int('BENCH_ITERATIONS', 2000);
$connectIterations = env_int('BENCH_CONNECT_ITERATIONS', 25);
$warmupIterations = env_int('BENCH_WARMUP_ITERATIONS', 200);
$resultSetIterations = env_int('BENCH_RESULTSET_ITERATIONS', 20);
$resultSetWarmupIterations = env_int('BENCH_RESULTSET_WARMUP_ITERATIONS', 5);

mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);

$mysqli = mysqli_connect_bench($host, $port, $user, $password, $database, $secure);
$server = $mysqli->query('SELECT VERSION() AS version, @@version_comment AS comment, @@port AS port')->fetch_assoc();
$mysqli->close();

$connectStart = hrtime(true);
for ($i = 0; $i < $connectIterations; $i++) {
    $mysqli = mysqli_connect_bench($host, $port, $user, $password, $database, $secure);
    $mysqli->close();
}
$connectElapsedNs = hrtime(true) - $connectStart;

$mysqli = mysqli_connect_bench($host, $port, $user, $password, $database, $secure);
ensure_benchmark_rows($mysqli, 10000, $benchTable);

$textChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    $result = $mysqli->query('SELECT 1');
    $row = $result->fetch_row();
    $textChecksum += (int)$row[0];
    $result->free();
}

$textStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    $result = $mysqli->query('SELECT 1');
    $row = $result->fetch_row();
    $textChecksum += (int)$row[0];
    $result->free();
}
$textElapsedNs = hrtime(true) - $textStart;

$autoPreparedChecksum = 0;
if (method_exists($mysqli, 'execute_query')) {
    for ($i = 0; $i < $warmupIterations; $i++) {
        $result = $mysqli->execute_query('SELECT ? + ?', [40, 2]);
        $row = $result->fetch_row();
        $autoPreparedChecksum += (int)$row[0];
        $result->free();
    }

    $autoPreparedStart = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        $result = $mysqli->execute_query('SELECT ? + ?', [40, 2]);
        $row = $result->fetch_row();
        $autoPreparedChecksum += (int)$row[0];
        $result->free();
    }
    $autoPreparedElapsedNs = hrtime(true) - $autoPreparedStart;
} else {
    $autoPreparedElapsedNs = 0;
}

$stmt = $mysqli->prepare('SELECT ? + ?');
$a = 40;
$b = 2;
$stmt->bind_param('ii', $a, $b);

$preparedChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    $stmt->execute();
    $result = $stmt->get_result();
    $row = $result->fetch_row();
    $preparedChecksum += (int)$row[0];
    $result->free();
}

$preparedStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    $stmt->execute();
    $result = $stmt->get_result();
    $row = $result->fetch_row();
    $preparedChecksum += (int)$row[0];
    $result->free();
}
$preparedElapsedNs = hrtime(true) - $preparedStart;

$resultSets = [
    'rows_10' => benchmark_result_set($mysqli, $benchTable, 10, $resultSetWarmupIterations, $resultSetIterations),
    'rows_1000' => benchmark_result_set($mysqli, $benchTable, 1000, $resultSetWarmupIterations, $resultSetIterations),
    'rows_10000' => benchmark_result_set($mysqli, $benchTable, 10000, $resultSetWarmupIterations, $resultSetIterations),
];

$stmt->close();
$mysqli->close();

$connectTotalMs = $connectElapsedNs / 1000000;
$textTotalMs = $textElapsedNs / 1000000;
$autoPreparedTotalMs = $autoPreparedElapsedNs / 1000000;
$preparedTotalMs = $preparedElapsedNs / 1000000;

echo json_encode([
    'driver' => 'php_mysqli',
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
    'auto_prepared_total_ms' => $autoPreparedTotalMs,
    'auto_prepared_avg_ms' => $autoPreparedElapsedNs > 0 ? $autoPreparedTotalMs / $iterations : null,
    'auto_prepared_ops_per_sec' => $autoPreparedElapsedNs > 0 ? $iterations / ($autoPreparedElapsedNs / 1000000000) : null,
    'auto_prepared_checksum' => $autoPreparedChecksum,
    'prepared_total_ms' => $preparedTotalMs,
    'prepared_avg_ms' => $preparedTotalMs / $iterations,
    'prepared_ops_per_sec' => $iterations / ($preparedElapsedNs / 1000000000),
    'prepared_checksum' => $preparedChecksum,
    'result_sets' => $resultSets,
], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), PHP_EOL;
