// Type round-trips: each value is written through the text protocol (SQL
// literal) and the binary protocol (parameter), then read back through both
// protocols (plain query and prepared statement). NULL is checked in every
// type.

import 'dart:convert';
import 'dart:typed_data';

import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_dart.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:test/test.dart';

import 'test_config.dart';

const _table = 'cov_types';

Future<MySQLConnection> _open() async {
  final connection = await MySQLConnection.createConnection(
    host: mysqlTestHost,
    port: mysqlTestPort,
    userName: mysqlTestUser,
    password: mysqlTestPassword,
    databaseName: mysqlTestDatabase,
    secure: mysqlTestSecure,
  );
  await connection.connect();
  return connection;
}

/// The value of `v` read back, per protocol.
class _Read {
  final dynamic textRaw;
  final dynamic textTyped;
  final dynamic binaryRaw;
  final dynamic binaryTyped;

  _Read(this.textRaw, this.textTyped, this.binaryRaw, this.binaryTyped);

  @override
  String toString() => 'text: $textRaw / $textTyped, '
      'binary: $binaryRaw / $binaryTyped';
}

void main() {
  late MySQLConnection conn;

  setUpAll(() async {
    conn = await _open();
    // Fixed session settings: zero dates allowed, UTC timestamps.
    await conn.execute("set session sql_mode = '', time_zone = '+00:00'");
  });

  tearDownAll(() async {
    await conn.execute('drop table if exists $_table');
    await conn.close();
  });

  Future<List<_Read>> readAll() async {
    final text = await conn.execute('select v from $_table order by id');
    final binary = await conn
        .execute('select v from $_table where id > ? order by id', [0]);
    final t = text.rows.toList();
    final b = binary.rows.toList();
    expect(b.length, t.length);
    return [
      for (var i = 0; i < t.length; i++)
        _Read(t[i].colAt(0), t[i].typedAssoc()['v'], b[i].colAt(0),
            b[i].typedAssoc()['v']),
    ];
  }

  /// Creates `v [columnType]`, writes each of [literals] as SQL and each of
  /// [params] as a binary parameter, plus a NULL each way, and returns the
  /// values read back (literals first, then params; the NULLs are checked
  /// here).
  Future<List<_Read>> roundTrip(
    String columnType, {
    List<String> literals = const [],
    List<Object?> params = const [],
  }) async {
    await conn.execute('drop table if exists $_table');
    await conn.execute('create table $_table '
        '(id int auto_increment primary key, v $columnType) '
        'default charset utf8mb4');
    for (final literal in literals) {
      await conn.execute('insert into $_table (v) values ($literal)');
    }
    for (final param in params) {
      await conn.execute('insert into $_table (v) values (?)', [param]);
    }
    await conn.execute('insert into $_table (v) values (NULL)');
    await conn.execute('insert into $_table (v) values (?)', [null]);
    final reads = await readAll();
    for (final nullRead in reads.sublist(reads.length - 2)) {
      expect(nullRead.textRaw, isNull, reason: '$columnType NULL (text)');
      expect(nullRead.textTyped, isNull);
      expect(nullRead.binaryRaw, isNull, reason: '$columnType NULL (binary)');
      expect(nullRead.binaryTyped, isNull);
    }
    return reads.sublist(0, reads.length - 2);
  }

  /// Every read has typed value [typed] (a value or a matcher) and the raw
  /// value is the same through both protocols.
  void expectTyped(List<_Read> reads, List<Object?> typed,
      {bool sameRaw = true}) {
    expect(reads, hasLength(typed.length));
    for (var i = 0; i < reads.length; i++) {
      expect(reads[i].textTyped, typed[i], reason: 'text #$i ${reads[i]}');
      expect(reads[i].binaryTyped, typed[i], reason: 'binary #$i ${reads[i]}');
      if (sameRaw) {
        expect(reads[i].binaryRaw, reads[i].textRaw,
            reason: 'raw #$i ${reads[i]}');
      }
    }
  }

  group('integers', () {
    const minInt64 = -9223372036854775807 - 1;
    const maxInt64 = 9223372036854775807;
    final cases = <String, List<Object>>{
      'tinyint': [-128, 0, 127],
      'tinyint unsigned': [0, 200, 255],
      'smallint': [-32768, 32767],
      'smallint unsigned': [0, 65535],
      'mediumint': [-8388608, 8388607],
      'mediumint unsigned': [0, 16777215],
      'int': [-2147483648, 2147483647],
      'int unsigned': [0, 4294967295],
      'bigint': [minInt64, -1, maxInt64],
      'bigint unsigned': [0, maxInt64],
    };
    cases.forEach((type, values) {
      test(type, () async {
        final reads = await roundTrip(type,
            literals: [for (final v in values) '$v'], params: values);
        expectTyped(reads, [...values, ...values]);
      });
    });

    test('bigint unsigned above 2^63 - 1', () async {
      final max = BigInt.parse('18446744073709551615');
      final big = BigInt.parse('9223372036854775808');
      final reads = await roundTrip('bigint unsigned',
          literals: ['$max', '$big'], params: [max, big]);
      expectTyped(reads, [max, big, max, big]);
    });

    test('integer limits as parameters of a bare SELECT', () async {
      for (final v in [
        -128,
        127,
        128,
        -32769,
        2147483648,
        minInt64,
        maxInt64
      ]) {
        final r = await conn.execute('select ? as v', [v]);
        expect(r.rows.single.typedAssoc()['v'], v);
      }
    });

    test('bool and tinyint(1)', () async {
      final reads = await roundTrip('tinyint(1)',
          literals: ['true', 'false', '5'], params: [true, false, 1]);
      expectTyped(reads, [true, false, true, true, false, true]);
      final boolReads =
          await roundTrip('bool', literals: ['1'], params: [false]);
      expectTyped(boolReads, [true, false]);
    });

    test('year', () async {
      final reads = await roundTrip('year',
          literals: ['1901', '2155', '0', "'2024'"], params: [2024, 1999]);
      // Raw: '0000' (text) and '0' (binary).
      expectTyped(reads, [1901, 2155, 0, 2024, 2024, 1999], sameRaw: false);
    });
  });

  group('decimal and floating point', () {
    test('decimal keeps every digit (text and binary)', () async {
      const values = [
        '12345678901234567890123456789012345.123456789012345678901234567890',
        '-0.000000000000000000000000000001',
        '0.000000000000000000000000000000',
      ];
      final reads =
          await roundTrip('decimal(65,30)', literals: values, params: values);
      expectTyped(reads, [...values, ...values]);
    });

    test('decimal from int and double parameters', () async {
      final reads = await roundTrip('decimal(10,2)',
          literals: ['-0.01', '99999999.99'], params: [42, 0.1, -12.345]);
      expectTyped(reads, ['-0.01', '99999999.99', '42.00', '0.10', '-12.35']);
    });

    test('float', () async {
      final reads = await roundTrip('float',
          literals: ['1.5', '-0.25', '1.1'], params: [1.5, -0.25, 1.1]);
      // The text protocol sends FLOAT rounded to its precision ('1.1'), the
      // binary protocol the float32 itself (1.100000023841858).
      expectTyped(
          reads,
          [
            1.5,
            -0.25,
            closeTo(1.1, 1e-6),
            1.5,
            -0.25,
            closeTo(1.1, 1e-6),
          ],
          sameRaw: false);
    });

    test('double', () async {
      const values = [
        0.1,
        -2.2250738585072014e-308,
        1.7976931348623157e308,
        123456789.123456789,
        0.0,
      ];
      final reads = await roundTrip('double',
          literals: [for (final v in values) '$v'], params: values);
      expectTyped(reads, [...values, ...values], sameRaw: false);
    });
  });

  group('bit', () {
    test('bit(1) and bit(64)', () async {
      final one = await roundTrip('bit(1)', literals: ["b'1'", "b'0'"]);
      expectTyped(one, [
        [1],
        [0]
      ]);
      final wide = await roundTrip('bit(64)',
          literals: ["b'${'1' * 64}'", "b'101'"], params: [5]);
      expectTyped(wide, [
        List.filled(8, 255),
        [0, 0, 0, 0, 0, 0, 0, 5],
        [0, 0, 0, 0, 0, 0, 0, 5],
      ]);
      expect(wide.first.textTyped, isA<Uint8List>());
      expect(wide.first.binaryTyped, isA<Uint8List>());
    });
  });

  group('dates and times', () {
    test('date', () async {
      final reads = await roundTrip('date', literals: [
        "'2024-02-29'",
        "'1000-01-01'",
        "'9999-12-31'",
        "'0999-01-01'"
      ], params: [
        DateTime(2024, 2, 29)
      ]);
      expectTyped(
          reads,
          [
            DateTime(2024, 2, 29),
            DateTime(1000, 1, 1),
            DateTime(9999, 12, 31),
            DateTime(999, 1, 1),
            DateTime(2024, 2, 29),
          ],
          // The binary protocol sends DATE as 'yyyy-mm-dd 00:00:00'.
          sameRaw: false);
      expect(reads.first.textRaw, '2024-02-29');
      expect(reads.first.binaryRaw, '2024-02-29 00:00:00');
    });

    test('datetime(6) keeps microseconds through both protocols', () async {
      if (!await serverHasFractionalSeconds(conn)) {
        markTestSkipped('the server has no fractional seconds');
        return;
      }
      final reads = await roundTrip('datetime(6)', literals: [
        "'2024-01-02 03:04:05.000001'",
        "'2024-01-02 03:04:05.005'",
        "'2024-01-02 03:04:05.5'",
        "'9999-12-31 23:59:59.999999'",
        "'2024-01-02 03:04:05'",
      ], params: [
        DateTime(2024, 1, 2, 3, 4, 5, 0, 1),
        DateTime(2024, 1, 2, 3, 4, 5, 5),
        DateTime(2024, 1, 2, 3, 4, 5),
      ]);
      expectTyped(
          reads,
          [
            DateTime(2024, 1, 2, 3, 4, 5, 0, 1),
            DateTime(2024, 1, 2, 3, 4, 5, 5),
            DateTime(2024, 1, 2, 3, 4, 5, 500),
            DateTime(9999, 12, 31, 23, 59, 59, 999, 999),
            DateTime(2024, 1, 2, 3, 4, 5),
            DateTime(2024, 1, 2, 3, 4, 5, 0, 1),
            DateTime(2024, 1, 2, 3, 4, 5, 5),
            DateTime(2024, 1, 2, 3, 4, 5),
          ],
          sameRaw: false);
      // Same text, except that the binary protocol leaves out a zero
      // fraction.
      for (final r in reads) {
        final text = r.textRaw as String;
        expect(r.binaryRaw,
            text.endsWith('.000000') ? text.substring(0, 19) : text);
      }
    });

    test('datetime(3), datetime and timestamp(3)', () async {
      if (!await serverHasFractionalSeconds(conn)) {
        markTestSkipped('the server has no fractional seconds');
        return;
      }
      final ms = await roundTrip('datetime(3)',
          literals: ["'2024-01-02 03:04:05.120'"],
          params: [DateTime(2024, 1, 2, 3, 4, 5, 120)]);
      expectTyped(
          ms,
          [
            DateTime(2024, 1, 2, 3, 4, 5, 120),
            DateTime(2024, 1, 2, 3, 4, 5, 120),
          ],
          // '.120' (text, the column's precision) and '.120000' (binary).
          sameRaw: false);
      final plain = await roundTrip('datetime',
          literals: ["'1000-01-01 00:00:00'"],
          params: [DateTime(2024, 12, 31, 23, 59, 59)]);
      expectTyped(plain, [
        DateTime(1000, 1, 1),
        DateTime(2024, 12, 31, 23, 59, 59),
      ]);
      final ts = await roundTrip('timestamp(3) null',
          literals: ["'1970-01-01 00:00:01.000'", "'2038-01-19 03:14:07.999'"],
          params: [DateTime(2024, 6, 1, 12, 0, 0, 1)]);
      expectTyped(
          ts,
          [
            DateTime(1970, 1, 1, 0, 0, 1),
            DateTime(2038, 1, 19, 3, 14, 7, 999),
            DateTime(2024, 6, 1, 12, 0, 0, 1),
          ],
          sameRaw: false);
    });

    test('time(6), negative and above 24 hours', () async {
      if (!await serverHasFractionalSeconds(conn)) {
        markTestSkipped('the server has no fractional seconds');
        return;
      }
      final reads = await roundTrip('time(6)', literals: [
        "'838:59:59'",
        "'-838:59:59'",
        "'12:34:56.789012'",
        "'00:00:00.000001'",
        "'-00:00:01.5'",
      ]);
      // TIME is returned as text: '[-]h:mm:ss.ffffff' (text protocol, the
      // column's precision) or without a zero fraction (binary protocol).
      expect([
        for (final r in reads) r.textRaw
      ], [
        '838:59:59.000000',
        '-838:59:59.000000',
        '12:34:56.789012',
        '00:00:00.000001',
        '-00:00:01.500000',
      ]);
      expect([
        for (final r in reads) r.binaryRaw
      ], [
        '838:59:59',
        '-838:59:59',
        '12:34:56.789012',
        '00:00:00.000001',
        '-00:00:01.500000',
      ]);
      for (final r in reads) {
        expect(r.textTyped, r.textRaw);
        expect(r.binaryTyped, r.binaryRaw);
      }
      final plain =
          await roundTrip('time', literals: ["'-01:02:03'", "'100:00:00'"]);
      expectTyped(plain, ['-01:02:03', '100:00:00']);
    });

    test('zero dates', () async {
      if (!await serverHasFractionalSeconds(conn)) {
        markTestSkipped('the server has no fractional seconds');
        return;
      }
      final date = await roundTrip('date', literals: ["'0000-00-00'"]);
      expect(date.single.textRaw, '0000-00-00');
      expect(date.single.binaryRaw, '0000-00-00 00:00:00');
      final dt =
          await roundTrip('datetime(6)', literals: ["'0000-00-00 00:00:00'"]);
      expect(dt.single.textRaw, '0000-00-00 00:00:00.000000');
      expect(dt.single.binaryRaw, '0000-00-00 00:00:00');
      // DateTime cannot represent a zero date: DateTime.parse turned it into
      // -0001-11-30. Typed reads return null; the raw text stays.
      expectTyped(date, [null], sameRaw: false);
      expectTyped(dt, [null], sameRaw: false);
      final ts = await roundTrip('timestamp null',
          literals: ["'0000-00-00 00:00:00'"]);
      expectTyped(ts, [null], sameRaw: false);
    });

    test('dates with a zero month or day are null when typed', () async {
      final reads = await roundTrip('datetime',
          literals: ["'2024-00-00 10:00:00'", "'2024-05-00 10:00:00'"]);
      expect(reads.map((r) => r.textRaw),
          ['2024-00-00 10:00:00', '2024-05-00 10:00:00']);
      // They were read as 2023-11-30 and 2024-04-30.
      expectTyped(reads, [null, null]);
    });

    test('invalid dates (ALLOW_INVALID_DATES) are null when typed', () async {
      await conn.execute("set session sql_mode = 'ALLOW_INVALID_DATES'");
      try {
        final reads = await roundTrip('date', literals: ["'2024-02-30'"]);
        expect(reads.single.textRaw, '2024-02-30');
        // It was read as 2024-03-01.
        expectTyped(reads, [null], sameRaw: false);
      } finally {
        await conn.execute("set session sql_mode = ''");
      }
    });

    test('typedColAt and typedColByName return null for a zero date', () async {
      await roundTrip('datetime',
          literals: ["'0000-00-00 00:00:00'", "'2024-03-10 12:34:56'"]);
      for (final params in [
        null,
        <Object?>[0]
      ]) {
        final result = await conn.execute(
            params == null
                ? 'select v from $_table order by id'
                : 'select v from $_table where id > ? order by id',
            params);
        final rows = result.rows.toList();
        expect(rows[0].typedColAt<DateTime>(0), isNull);
        expect(rows[0].typedColByName<DateTime>('v'), isNull);
        expect(rows[0].colAt(0), '0000-00-00 00:00:00');
        expect(
            rows[1].typedColAt<DateTime>(0), DateTime(2024, 3, 10, 12, 34, 56));
      }
    });

    test('zeroDateBehavior.exception throws in typed reads', () async {
      await roundTrip('datetime',
          literals: ["'0000-00-00 00:00:00'", "'2024-03-10 12:34:56'"]);
      final strict = await MySQLConnection.createConnection(
        host: mysqlTestHost,
        port: mysqlTestPort,
        userName: mysqlTestUser,
        password: mysqlTestPassword,
        databaseName: mysqlTestDatabase,
        secure: mysqlTestSecure,
        zeroDateBehavior: ZeroDateBehavior.exception,
      );
      await strict.connect();
      try {
        for (final params in [
          null,
          <Object?>[0]
        ]) {
          final result = await strict.execute(
              params == null
                  ? 'select v from $_table order by id'
                  : 'select v from $_table where id > ? order by id',
              params);
          final rows = result.rows.toList();
          final zero = rows[0];
          expect(zero.typedAssoc, throwsA(isA<MySQLClientException>()));
          expect(() => zero.typedColAt<DateTime>(0),
              throwsA(isA<MySQLClientException>()));
          expect(() => zero.typedColByName<DateTime>('v'),
              throwsA(isA<MySQLClientException>()));
          expect(zero.colAt(0), '0000-00-00 00:00:00');
          expect(zero.assoc()['v'], '0000-00-00 00:00:00');
          expect(rows[1].typedAssoc()['v'], DateTime(2024, 3, 10, 12, 34, 56));
        }
        // The connection is still usable after the exception.
        final ok = await strict.execute('select 1 as one');
        expect(ok.rows.single.typedAssoc()['one'], 1);
      } finally {
        await strict.close();
      }
    });

    test('the pool passes zeroDateBehavior to its connections', () async {
      await roundTrip('date', literals: ["'0000-00-00'"]);
      Future<Object?> read(ZeroDateBehavior behavior) async {
        final pool = MySQLConnectionPool(
          host: mysqlTestHost,
          port: mysqlTestPort,
          userName: mysqlTestUser,
          password: mysqlTestPassword,
          databaseName: mysqlTestDatabase,
          secure: mysqlTestSecure,
          maxConnections: 1,
          zeroDateBehavior: behavior,
        );
        try {
          final result = await pool.execute('select v from $_table');
          return result.rows.first.typedAssoc()['v'];
        } finally {
          await pool.close();
        }
      }

      expect(await read(ZeroDateBehavior.convertToNull), isNull);
      expect(() => read(ZeroDateBehavior.exception),
          throwsA(isA<MySQLClientException>()));
    });
  });

  group('strings', () {
    const samples = [
      'ação é ü ñ',
      '😀 emoji 🎉 and 中文 字符',
      "quotes ' \" \\ backslash",
      '',
    ];

    for (final type in [
      'varchar(100)',
      'text',
      'mediumtext',
      'varchar(100) collate utf8mb4_bin',
      'text collate utf8mb4_bin',
      'char(40)',
      'char(40) collate utf8mb4_bin',
    ]) {
      test(type, () async {
        final reads = await roundTrip(type,
            literals: [
              for (final s in samples)
                "'${s.replaceAll(r'\', r'\\').replaceAll("'", "''")}'"
            ],
            params: samples);
        expectTyped(reads, [...samples, ...samples]);
        for (final r in reads) {
          expect(r.textRaw, isA<String>());
          expect(r.binaryRaw, isA<String>());
        }
      });
    }

    test('char drops trailing spaces, varchar keeps them', () async {
      final c = await roundTrip('char(10)', params: ['ab  ']);
      expectTyped(c, ['ab']);
      final v = await roundTrip('varchar(10)', params: ['ab  ']);
      expectTyped(v, ['ab  ']);
    });

    test('long text (1 MB, multi-byte)', () async {
      final long = 'ção😀' * 200000;
      final reads = await roundTrip('longtext', params: [long]);
      expectTyped(reads, [long]);
    });

    test('enum and set', () async {
      final e = await roundTrip("enum('a','b','ç')",
          literals: ["'b'", "'ç'"], params: ['a']);
      expectTyped(e, ['b', 'ç', 'a']);
      final s = await roundTrip("set('x','y','z')",
          literals: ["'x,z'", "''"], params: ['y,x']);
      expectTyped(s, ['x,z', '', 'x,y']);
    });

    test('json', () async {
      if (!await serverHasJsonType(conn)) {
        markTestSkipped('the server has no JSON type');
        return;
      }
      const doc = '{"a": [1, 2, {"b": "ção 😀"}], "n": null}';
      final reads = await roundTrip('json', literals: [
        "'$doc'"
      ], params: [
        doc,
        {
          'a': [
            1,
            2,
            {'b': 'ção 😀'}
          ],
          'n': null,
        },
      ]);
      expect(reads, hasLength(3));
      for (final r in reads) {
        for (final v in [r.textRaw, r.binaryRaw, r.textTyped, r.binaryTyped]) {
          expect(v, isA<String>());
          expect(jsonDecode(v as String), jsonDecode(doc));
        }
      }
    });
  });

  group('binary strings', () {
    for (final type in ['tinyblob', 'blob', 'mediumblob', 'longblob']) {
      test('$type keeps every byte value', () async {
        // TINYBLOB holds 255 bytes.
        final allBytes = Uint8List.fromList(
            List.generate(type == 'tinyblob' ? 255 : 256, (i) => 255 - i));
        final reads = await roundTrip(type, literals: [
          "x'${allBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'",
          "''"
        ], params: [
          allBytes,
          Uint8List(0)
        ]);
        expectTyped(reads, [allBytes, <int>[], allBytes, <int>[]]);
        for (final r in reads) {
          expect(r.textRaw, isA<Uint8List>());
          expect(r.binaryRaw, isA<Uint8List>());
        }
      });
    }

    test('binary and varbinary are decoded as UTF-8 text', () async {
      // Documented behavior: BINARY/VARBINARY come back as String (UTF-8
      // decoded); bytes that are not UTF-8 need a BLOB column or HEX().
      final vb = await roundTrip('varbinary(20)',
          literals: ["'abc'", "'ção'"], params: ['xyz', utf8.encode('ü')]);
      expectTyped(vb, ['abc', 'ção', 'xyz', 'ü']);
      final b = await roundTrip('binary(4)', literals: ["'ab'"]);
      expectTyped(b, ['ab\u0000\u0000']);

      await conn.execute('drop table if exists $_table');
      await conn.execute('create table $_table (id int, v varbinary(8))');
      await conn.execute('insert into $_table values (1, ?)', [
        Uint8List.fromList([0, 255, 128])
      ]);
      final hex = await conn.execute('select hex(v) as h from $_table');
      expect(hex.rows.single.colAt(0), '00FF80');
    });

    test('large blob (4 MB)', () async {
      final big =
          Uint8List.fromList(List.generate(4 << 20, (i) => i * 7 & 255));
      final reads = await roundTrip('longblob', params: [big]);
      expectTyped(reads, [big]);
    });
  });

  group('payloads around the 16 MB packet limit', () {
    late MySQLConnection big;
    late int maxAllowedPacket;

    setUp(() async {
      big = await _open();
      final r = await big.execute('select @@max_allowed_packet as m');
      maxAllowedPacket = r.rows.single.typedAssoc()['m'] as int;
    });
    tearDown(() async {
      try {
        await big.close();
      } catch (_) {}
    });

    const limit = mysqlMaxPacketPayloadLength; // 0xffffff

    test('a row of 0xffffff bytes or more is read whole', () async {
      if (maxAllowedPacket < limit + 1) {
        markTestSkipped('max_allowed_packet < 16 MB');
        return;
      }
      // Text row: 4-byte length prefix + value; binary row: header, NULL
      // bitmap and the same prefix. Exactly 0xffffff bytes, then one more.
      for (final length in [limit - 4, limit - 3]) {
        final text = await big.execute("select repeat('a', $length) as v");
        expect((text.rows.single.colAt(0) as String).length, length);
        expect((await big.execute('select 1 as v')).rows.single.colAt(0), '1');
      }
      for (final length in [limit - 6, limit - 5]) {
        final binary =
            await big.execute('select repeat(?, ?) as v', ['b', length]);
        expect((binary.rows.single.colAt(0) as String).length, length);
        expect((await big.execute('select ? as v', [2])).rows.single.colAt(0),
            '2');
      }
    });

    test('a command of 0xffffff bytes or more is split into packets', () async {
      // Exactly 0xffffff bytes (a full packet and an empty one) fits a
      // 16 MB max_allowed_packet; longer payloads need a larger one.
      final payloads = [
        if (maxAllowedPacket >= limit + 1) limit,
        if (maxAllowedPacket >= limit + 4096) ...[limit + 1, limit + 100],
      ];
      if (payloads.isEmpty) {
        markTestSkipped('max_allowed_packet < 16 MB');
        return;
      }
      // COM_QUERY: 1 command byte + the query.
      const prefix = "select length('";
      const suffix = "') as v";
      for (final payload in payloads) {
        final n = payload - 1 - prefix.length - suffix.length;
        final r = await big.execute('$prefix${'x' * n}$suffix');
        expect(r.rows.single.typedAssoc()['v'], n);
      }
      // COM_STMT_EXECUTE: 10 header bytes, NULL bitmap, bound flag, one
      // type (2 bytes), 4-byte length prefix + the value.
      final stmt = await big.prepare('select length(?) as v');
      for (final payload in payloads) {
        final n = payload - 10 - 1 - 1 - 2 - 4;
        final r = await stmt.execute(['y' * n]);
        expect(r.rows.single.typedAssoc()['v'], n);
      }
      await stmt.deallocate();
      expect((await big.execute('select 3 as v')).rows.single.colAt(0), '3');
    });
  });
}
