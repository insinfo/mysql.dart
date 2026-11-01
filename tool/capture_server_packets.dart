// Captures the packets a real server sends, as seeds for
// test/fuzz_decoders_test.dart.
//
// A TCP proxy sits between the driver and the server, runs a fixed set of
// statements through it (handshake, text and binary result sets with every
// column type, OK and ERR responses) and writes each exchange to JSON:
//
//   dart run tool/capture_server_packets.dart \
//     --port 3308 --out test/fixtures/server_packets_mysql97.json
//
// Plain TCP only (the proxy has to read the bytes); for caching_sha2_password
// run `FLUSH PRIVILEGES` first so the login does the full RSA exchange.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_dart.dart';

Future<void> main(List<String> args) async {
  String arg(String name, String fallback) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
  }

  final host = arg('host', '127.0.0.1');
  final port = int.parse(arg('port', '3306'));
  final user = arg('user', 'dart');
  final password = arg('password', 'dart');
  final database = arg('database', 'banco_teste');
  final out = arg('out', 'server_packets.json');

  final exchanges = <Map<String, Object?>>[];
  final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  proxy.listen((client) async {
    final server = await Socket.connect(host, port);
    var current = <String, Object?>{'command': 'handshake', 'packets': []};
    exchanges.add(current);

    _Splitter(onPacket: (seq, payload) {
      if (seq != 0 || payload.isEmpty) return;
      current = {
        'command': _commandName(payload[0]),
        if (payload[0] == 0x03 || payload[0] == 0x16)
          'sql': utf8.decode(payload.sublist(1), allowMalformed: true),
        'packets': [],
      };
      exchanges.add(current);
    }).attach(client, server);

    _Splitter(onPacket: (seq, payload) {
      (current['packets'] as List).add(_hex(_frame(seq, payload)));
    }).attach(server, client);
  });

  final conn = await MySQLConnection.createConnection(
    host: InternetAddress.loopbackIPv4,
    port: proxy.port,
    userName: user,
    password: password,
    databaseName: database,
    secure: false,
    allowPublicKeyRetrieval: true,
  );
  await conn.connect();

  final version =
      (await conn.execute('SELECT VERSION() AS v')).rows.first.colByName('v')!;
  // MySQL has JSON from 5.7 on; MariaDB maps it to LONGTEXT.
  final hasJson = version.contains('MariaDB') ||
      !(version.startsWith('5.5') || version.startsWith('5.6'));

  await conn.execute('DROP TABLE IF EXISTS fuzz_seed');
  await conn.execute('''
    CREATE TABLE fuzz_seed (
      id INT PRIMARY KEY,
      t TINYINT, s SMALLINT UNSIGNED, m MEDIUMINT, b BIGINT UNSIGNED,
      f FLOAT, d DOUBLE, dec_ DECIMAL(12,3),
      dt DATE, dtm DATETIME(6), ts TIMESTAMP(3) NULL, tm TIME(6), yr YEAR,
      c CHAR(4), vc VARCHAR(64), tx TEXT, bl BLOB, vb VARBINARY(16),
      bt BIT(12), en ENUM('a','b'), st SET('x','y','z'),
      ${hasJson ? 'js JSON,' : ''}
      geo GEOMETRY
    ) DEFAULT CHARSET=utf8mb4''');
  await conn.execute('''
    INSERT INTO fuzz_seed VALUES
      (1, -128, 65535, -8388608, 18446744073709551615, 1.5, -2.25e300,
       -123456789.125, '2024-02-29', '2024-02-29 23:59:59.123456',
       '2024-02-29 01:02:03.456', '-838:59:59.000000', 2024, 'ab',
       'ção 😀', REPEAT('t', 300), x'00ff10', x'0102', b'101010101010',
       'b', 'x,z', ${hasJson ? "'{\"k\": [1, null, \"ç\"]}'," : ''}
       ST_GeomFromText('POINT(1 2)')),
      (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       ${hasJson ? 'NULL,' : ''} NULL),
      (3, 0, 0, 0, 0, 0, 0, 0, '1000-01-01', '1000-01-01 00:00:00',
       NULL, '00:00:00', 1901, '', '', '', '', '', b'0', 'a', '',
       ${hasJson ? "'[]'," : ''} ST_GeomFromText('POINT(0 0)'))''');

  await conn.execute('SELECT * FROM fuzz_seed ORDER BY id');
  await conn.execute('SELECT * FROM fuzz_seed WHERE id < 0');
  await conn.execute('UPDATE fuzz_seed SET t = t WHERE id = 1');
  try {
    await conn.execute('SELECT * FROM no_such_table_fuzz');
  } on MySQLServerException {
    // The ERR packet is the point.
  }
  final stmt = await conn.prepare('SELECT * FROM fuzz_seed WHERE id >= ?');
  await stmt.execute([1]);
  await stmt.deallocate();
  final empty = await conn.prepare('SELECT * FROM fuzz_seed WHERE id < ?');
  await empty.execute([0]);
  await empty.deallocate();
  final dml = await conn.prepare('UPDATE fuzz_seed SET t = ? WHERE id = ?');
  await dml.execute([1, 3]);
  await dml.deallocate();
  await conn.execute('DROP TABLE fuzz_seed');
  await conn.close();
  await proxy.close();

  // Commands without a response (COM_STMT_CLOSE, COM_QUIT) carry nothing.
  exchanges.removeWhere((e) => (e['packets'] as List).isEmpty);
  await File(out).writeAsString(const JsonEncoder.withIndent(' ')
      .convert({'server': version, 'exchanges': exchanges}));
  stdout.writeln('$version: ${exchanges.length} exchanges -> $out');
}

/// Forwards bytes from [from] to [to] and reports each complete packet.
class _Splitter {
  _Splitter({required this.onPacket});

  final void Function(int seq, Uint8List payload) onPacket;
  final _buffer = BytesBuilder(copy: false);

  void attach(Socket from, Socket to) {
    from.listen(
      (data) {
        to.add(data);
        _buffer.add(data);
        var bytes = _buffer.takeBytes();
        var offset = 0;
        while (bytes.length - offset >= 4) {
          final len =
              bytes[offset] | bytes[offset + 1] << 8 | bytes[offset + 2] << 16;
          if (bytes.length - offset < 4 + len) break;
          onPacket(bytes[offset + 3],
              Uint8List.sublistView(bytes, offset + 4, offset + 4 + len));
          offset += 4 + len;
        }
        _buffer.add(Uint8List.sublistView(bytes, offset));
      },
      onDone: () => to.destroy(),
      onError: (_) => to.destroy(),
    );
  }
}

String _commandName(int code) => switch (code) {
      0x01 => 'quit',
      0x03 => 'query',
      0x16 => 'prepare',
      0x17 => 'execute',
      0x19 => 'stmt_close',
      _ => 'command_0x${code.toRadixString(16)}',
    };

Uint8List _frame(int seq, Uint8List payload) => Uint8List.fromList([
      payload.length & 0xff,
      (payload.length >> 8) & 0xff,
      (payload.length >> 16) & 0xff,
      seq,
      ...payload,
    ]);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
