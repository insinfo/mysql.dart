<?php

require __DIR__ . '/php_benchmark/vendor/autoload.php';

use React\EventLoop\Loop;
use React\MySQL\Factory;

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

function await_promise($promise)
{
    $done = false;
    $result = null;
    $error = null;

    $promise->then(
        function ($value) use (&$done, &$result): void {
            $result = $value;
            $done = true;
            Loop::stop();
        },
        function ($reason) use (&$done, &$error): void {
            $error = $reason;
            $done = true;
            Loop::stop();
        }
    );

    while (!$done) {
        Loop::run();
    }

    if ($error !== null) {
        if ($error instanceof Throwable) {
            throw $error;
        }
        throw new RuntimeException((string)$error);
    }

    return $result;
}

function make_react_url(string $host, int $port, string $user, string $password, string $database): string
{
    return rawurlencode($user) . ':' . rawurlencode($password) . '@' . $host . ':' . $port . '/' . rawurlencode($database) . '?charset=utf8mb4';
}

function connect_react(string $url)
{
    $factory = new Factory();
    return await_promise($factory->createConnection($url));
}

function row_values(array $row): array
{
    return array_values($row);
}

function row_int_value($queryResult): int
{
    $row = row_values($queryResult->resultRows[0]);
    return (int)$row[0];
}

function row_checksum(array $row): int
{
    $values = row_values($row);
    return (int)$values[0]
        + strlen((string)$values[1])
        + strlen((string)$values[2])
        + strlen((string)$values[3])
        + strlen((string)$values[4]);
}

function query($connection, string $sql, array $params = [])
{
    return await_promise($connection->query($sql, $params));
}

function ensure_benchmark_rows($connection, int $targetRows, string $tableName): void
{
    query($connection, "
        CREATE TABLE IF NOT EXISTS $tableName (
            id INT PRIMARY KEY,
            name VARCHAR(64) NOT NULL,
            amount DECIMAL(10, 2) NOT NULL,
            created_at DATETIME NOT NULL,
            payload TEXT NOT NULL
        )
    ");

    $existingRows = row_int_value(query($connection, "SELECT COUNT(*) FROM $tableName"));
    if ($existingRows >= $targetRows) {
        return;
    }

    query($connection, "TRUNCATE TABLE $tableName");

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

        query(
            $connection,
            "INSERT INTO $tableName (id, name, amount, created_at, payload) VALUES " . implode(',', $values)
        );
    }
}

function benchmark_result_set($connection, string $tableName, int $size, int $warmupIterations, int $iterations): array
{
    $sql = "SELECT id, name, amount, created_at, payload FROM $tableName ORDER BY id LIMIT $size";
    $checksum = 0;

    for ($i = 0; $i < $warmupIterations; $i++) {
        $result = query($connection, $sql);
        foreach ($result->resultRows as $row) {
            $checksum += row_checksum($row);
        }
    }

    $rowCount = 0;
    $start = hrtime(true);
    for ($i = 0; $i < $iterations; $i++) {
        $result = query($connection, $sql);
        foreach ($result->resultRows as $row) {
            $checksum += row_checksum($row);
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
$benchTable = env_or_default('BENCH_TABLE', 'bench_rows_reactphp');
$secure = env_bool('MYSQL_SECURE', false);
$iterations = env_int('BENCH_ITERATIONS', 2000);
$connectIterations = env_int('BENCH_CONNECT_ITERATIONS', 25);
$warmupIterations = env_int('BENCH_WARMUP_ITERATIONS', 200);
$resultSetIterations = env_int('BENCH_RESULTSET_ITERATIONS', 20);
$resultSetWarmupIterations = env_int('BENCH_RESULTSET_WARMUP_ITERATIONS', 5);

if ($secure) {
    fwrite(STDERR, "react/mysql benchmark currently runs plain TCP only; set MYSQL_SECURE=false.\n");
    exit(64);
}

$url = make_react_url($host, $port, $user, $password, $database);

$connection = connect_react($url);
$server = query($connection, 'SELECT VERSION() AS version, @@version_comment AS comment, @@port AS port')->resultRows[0];
await_promise($connection->quit());

$connectStart = hrtime(true);
for ($i = 0; $i < $connectIterations; $i++) {
    $connection = connect_react($url);
    await_promise($connection->quit());
}
$connectElapsedNs = hrtime(true) - $connectStart;

$connection = connect_react($url);
ensure_benchmark_rows($connection, 10000, $benchTable);

$textChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    $textChecksum += row_int_value(query($connection, 'SELECT 1'));
}

$textStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    $textChecksum += row_int_value(query($connection, 'SELECT 1'));
}
$textElapsedNs = hrtime(true) - $textStart;

$autoPreparedChecksum = 0;
for ($i = 0; $i < $warmupIterations; $i++) {
    $autoPreparedChecksum += row_int_value(query($connection, 'SELECT ? + ?', [40, 2]));
}

$autoPreparedStart = hrtime(true);
for ($i = 0; $i < $iterations; $i++) {
    $autoPreparedChecksum += row_int_value(query($connection, 'SELECT ? + ?', [40, 2]));
}
$autoPreparedElapsedNs = hrtime(true) - $autoPreparedStart;

$resultSets = [
    'rows_10' => benchmark_result_set($connection, $benchTable, 10, $resultSetWarmupIterations, $resultSetIterations),
    'rows_1000' => benchmark_result_set($connection, $benchTable, 1000, $resultSetWarmupIterations, $resultSetIterations),
    'rows_10000' => benchmark_result_set($connection, $benchTable, 10000, $resultSetWarmupIterations, $resultSetIterations),
];

await_promise($connection->quit());

$connectTotalMs = $connectElapsedNs / 1000000;
$textTotalMs = $textElapsedNs / 1000000;
$autoPreparedTotalMs = $autoPreparedElapsedNs / 1000000;

echo json_encode([
    'driver' => 'php_react_mysql',
    'package' => 'react/mysql',
    'repository' => 'friends-of-reactphp/mysql',
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
    'auto_prepared_avg_ms' => $autoPreparedTotalMs / $iterations,
    'auto_prepared_ops_per_sec' => $iterations / ($autoPreparedElapsedNs / 1000000000),
    'auto_prepared_checksum' => $autoPreparedChecksum,
    'prepared_total_ms' => null,
    'prepared_avg_ms' => null,
    'prepared_ops_per_sec' => null,
    'prepared_checksum' => null,
    'result_sets' => $resultSets,
], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), PHP_EOL;
