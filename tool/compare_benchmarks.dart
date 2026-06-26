import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      'Usage: dart run tool/compare_benchmarks.dart <benchmark1.json> <benchmark2.json> [benchmark3.json ...]',
    );
    exitCode = 64;
    return;
  }

  final benchmarks = <Map<String, dynamic>>[
    for (final path in args)
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>,
  ];

  stdout.writeln(_environmentSummary(benchmarks));
  stdout.writeln();
  stdout.writeln(_scalarTable(benchmarks));
  stdout.writeln();
  stdout.writeln(_resultSetTable(benchmarks));
}

String _environmentSummary(List<Map<String, dynamic>> benchmarks) {
  final first = benchmarks.first;
  return [
    'Environment:',
    '- host: `${first['host']}`',
    '- port: `${first['port']}`',
    '- database: `${first['database']}`',
    '- secure: `${first['secure']}`',
    '- server: `${(first['server'] as Map<String, dynamic>)['version']}`',
    '- connect_mode: `${first['connect_mode']}`',
  ].join('\n');
}

String _scalarTable(List<Map<String, dynamic>> benchmarks) {
  final rows = <String>[
    '| Metric | ${benchmarks.map((b) => b['driver']).join(' | ')} |',
    '|---|${List.filled(benchmarks.length, '---:').join('|')}|',
  ];

  final metrics = <MapEntry<String, String>>[
    const MapEntry('connect_avg_ms', 'Connect avg ms'),
    const MapEntry(
        'connect_median_with_charset_ms', 'Connect median ms (with charset)'),
    const MapEntry(
        'connect_p95_with_charset_ms', 'Connect p95 ms (with charset)'),
    const MapEntry(
        'connect_p99_with_charset_ms', 'Connect p99 ms (with charset)'),
    const MapEntry('connect_median_without_charset_ms',
        'Connect median ms (without charset)'),
    const MapEntry(
        'connect_p95_without_charset_ms', 'Connect p95 ms (without charset)'),
    const MapEntry(
        'connect_p99_without_charset_ms', 'Connect p99 ms (without charset)'),
    const MapEntry('text_avg_ms', 'Text avg ms'),
    const MapEntry('text_ops_per_sec', 'Text ops/s'),
    const MapEntry('auto_prepared_avg_ms', 'Auto prepared avg ms'),
    const MapEntry('auto_prepared_ops_per_sec', 'Auto prepared ops/s'),
    const MapEntry('prepared_array_avg_ms', 'PDO prepared array avg ms'),
    const MapEntry('prepared_array_ops_per_sec', 'PDO prepared array ops/s'),
    const MapEntry('prepared_avg_ms', 'Prepared avg ms'),
    const MapEntry('prepared_ops_per_sec', 'Prepared ops/s'),
  ];

  for (final metric in metrics) {
    final values = benchmarks
        .map((b) => _formatMetric(_lookupScalarMetric(b, metric.key)))
        .join(' | ');
    rows.add('| ${metric.value} | $values |');
  }

  return rows.join('\n');
}

dynamic _lookupScalarMetric(Map<String, dynamic> benchmark, String key) {
  final connectScenarios =
      benchmark['connect_scenarios'] as Map<String, dynamic>?;
  final withCharset =
      connectScenarios?['with_charset'] as Map<String, dynamic>?;
  final withoutCharset =
      connectScenarios?['without_charset'] as Map<String, dynamic>?;

  switch (key) {
    case 'connect_median_with_charset_ms':
      return withCharset?['median_ms'];
    case 'connect_p95_with_charset_ms':
      return withCharset?['p95_ms'];
    case 'connect_p99_with_charset_ms':
      return withCharset?['p99_ms'];
    case 'connect_median_without_charset_ms':
      return withoutCharset?['median_ms'];
    case 'connect_p95_without_charset_ms':
      return withoutCharset?['p95_ms'];
    case 'connect_p99_without_charset_ms':
      return withoutCharset?['p99_ms'];
    default:
      return benchmark[key];
  }
}

String _resultSetTable(List<Map<String, dynamic>> benchmarks) {
  final rows = <String>[
    '| Result set metric | ${benchmarks.map((b) => b['driver']).join(' | ')} |',
    '|---|${List.filled(benchmarks.length, '---:').join('|')}|',
  ];

  for (final size in const <int>[10, 1000, 10000]) {
    for (final metric in const <MapEntry<String, String>>[
      MapEntry('avg_ms', 'avg ms'),
      MapEntry('first_row_avg_ms', 'first row avg ms'),
      MapEntry('queries_per_sec', 'queries/s'),
      MapEntry('rows_per_sec', 'rows/s'),
      MapEntry('streaming_avg_ms', 'streaming avg ms'),
      MapEntry('streaming_first_row_avg_ms', 'streaming first row avg ms'),
      MapEntry('streaming_queries_per_sec', 'streaming queries/s'),
      MapEntry('streaming_rows_per_sec', 'streaming rows/s'),
    ]) {
      final values = benchmarks.map((b) {
        final resultSets = b['result_sets'] as Map<String, dynamic>?;
        final entry = resultSets?['rows_$size'] as Map<String, dynamic>?;
        return _formatMetric(entry?[metric.key]);
      }).join(' | ');
      rows.add('| rows_$size ${metric.value} | $values |');
    }
  }

  return rows.join('\n');
}

String _formatMetric(dynamic value) {
  if (value == null) {
    return '-';
  }
  if (value is num) {
    return value.toStringAsFixed(3);
  }
  return '$value';
}
