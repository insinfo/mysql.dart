import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mysql_dart/exception.dart' as exc;
import 'package:mysql_dart/mysql_dart.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:test/test.dart';

typedef _FlagAccessor<C> = ({
  String name,
  int mask,
  bool Function(C col) read,
});

final _packetFlags = <_FlagAccessor<MySQLColumnDefinitionPacket>>[
  (
    name: 'isNotNull',
    mask: MySQLColumnDefinitionPacket.flagNotNull,
    read: (c) => c.isNotNull,
  ),
  (
    name: 'isPrimaryKey',
    mask: MySQLColumnDefinitionPacket.flagPrimaryKey,
    read: (c) => c.isPrimaryKey,
  ),
  (
    name: 'isUniqueKey',
    mask: MySQLColumnDefinitionPacket.flagUniqueKey,
    read: (c) => c.isUniqueKey,
  ),
  (
    name: 'isMultipleKey',
    mask: MySQLColumnDefinitionPacket.flagMultipleKey,
    read: (c) => c.isMultipleKey,
  ),
  (
    name: 'isBlob',
    mask: MySQLColumnDefinitionPacket.flagBlob,
    read: (c) => c.isBlob,
  ),
  (
    name: 'isUnsigned',
    mask: MySQLColumnDefinitionPacket.flagUnsigned,
    read: (c) => c.isUnsigned,
  ),
  (
    name: 'isZeroFill',
    mask: MySQLColumnDefinitionPacket.flagZeroFill,
    read: (c) => c.isZeroFill,
  ),
  (
    name: 'isBinary',
    mask: MySQLColumnDefinitionPacket.flagBinary,
    read: (c) => c.isBinary,
  ),
  (
    name: 'isEnum',
    mask: MySQLColumnDefinitionPacket.flagEnum,
    read: (c) => c.isEnum,
  ),
  (
    name: 'isAutoIncrement',
    mask: MySQLColumnDefinitionPacket.flagAutoIncrement,
    read: (c) => c.isAutoIncrement,
  ),
  (
    name: 'isTimestamp',
    mask: MySQLColumnDefinitionPacket.flagTimestamp,
    read: (c) => c.isTimestamp,
  ),
  (
    name: 'isSet',
    mask: MySQLColumnDefinitionPacket.flagSet,
    read: (c) => c.isSet,
  ),
];

final _resultColumnFlags = <_FlagAccessor<ResultSetColumn>>[
  (
    name: 'isNotNull',
    mask: ResultSetColumn.flagNotNull,
    read: (c) => c.isNotNull,
  ),
  (
    name: 'isPrimaryKey',
    mask: ResultSetColumn.flagPrimaryKey,
    read: (c) => c.isPrimaryKey,
  ),
  (
    name: 'isUniqueKey',
    mask: ResultSetColumn.flagUniqueKey,
    read: (c) => c.isUniqueKey,
  ),
  (
    name: 'isMultipleKey',
    mask: ResultSetColumn.flagMultipleKey,
    read: (c) => c.isMultipleKey,
  ),
  (
    name: 'isBlob',
    mask: ResultSetColumn.flagBlob,
    read: (c) => c.isBlob,
  ),
  (
    name: 'isUnsigned',
    mask: ResultSetColumn.flagUnsigned,
    read: (c) => c.isUnsigned,
  ),
  (
    name: 'isZeroFill',
    mask: ResultSetColumn.flagZeroFill,
    read: (c) => c.isZeroFill,
  ),
  (
    name: 'isBinary',
    mask: ResultSetColumn.flagBinary,
    read: (c) => c.isBinary,
  ),
  (
    name: 'isEnum',
    mask: ResultSetColumn.flagEnum,
    read: (c) => c.isEnum,
  ),
  (
    name: 'isAutoIncrement',
    mask: ResultSetColumn.flagAutoIncrement,
    read: (c) => c.isAutoIncrement,
  ),
  (
    name: 'isTimestamp',
    mask: ResultSetColumn.flagTimestamp,
    read: (c) => c.isTimestamp,
  ),
  (
    name: 'isSet',
    mask: ResultSetColumn.flagSet,
    read: (c) => c.isSet,
  ),
];

void main() {
  group('MySQLColumnType.bitType direct conversions', () {
    const bit = MySQLColumnType.bitType;

    test('getBestMatchDartType preserves Uint8List across BIT widths', () {
      expect(bit.getBestMatchDartType(1), Uint8List);
      expect(bit.getBestMatchDartType(16), Uint8List);
      expect(bit.getBestMatchDartType(64), Uint8List);
    });

    test('handles null, nullable targets, Object, dynamic, and sublistView',
        () {
      expect(bit.convertStringValueToProvidedType<bool>(null, 1), isNull);
      expect(bit.convertStringValueToProvidedType<int>(null, 64), isNull);
      expect(bit.convertStringValueToProvidedType<num>(null, 64), isNull);
      expect(bit.convertStringValueToProvidedType<BigInt>(null, 64), isNull);
      expect(bit.convertStringValueToProvidedType<Uint8List>(null, 64), isNull);

      final backing = Uint8List.fromList([0xff, 0x00, 0x2a, 0xff]);
      final slice = Uint8List.sublistView(backing, 1, 3);
      expect(bit.convertStringValueToProvidedType<bool?>(slice, 16), isTrue);
      expect(bit.convertStringValueToProvidedType<int?>(slice, 16), 42);
      expect(bit.convertStringValueToProvidedType<num?>(slice, 16), 42);
      expect(
        bit.convertStringValueToProvidedType<BigInt?>(slice, 16),
        BigInt.from(42),
      );
      expect(
        bit.convertStringValueToProvidedType<Uint8List?>(slice, 16),
        same(slice),
      );
      expect(
        bit.convertStringValueToProvidedType<Object>(slice, 16),
        same(slice),
      );
      expect(
        bit.convertStringValueToProvidedType<dynamic>(slice, 16),
        same(slice),
      );

      final zeroSlice = Uint8List.sublistView(backing, 1, 2);
      expect(
        bit.convertStringValueToProvidedType<bool?>(zeroSlice, 8),
        isFalse,
      );
      expect(bit.convertStringValueToProvidedType<int?>(zeroSlice, 8), 0);
    });

    test('treats MSB on 1..7-byte BIT values as unsigned positive', () {
      expect(
        bit.convertStringValueToProvidedType<int>(Uint8List.fromList([0xff])),
        255,
      );
      expect(
        bit.convertStringValueToProvidedType<int>(
          Uint8List.fromList([0xff, 0xff]),
        ),
        65535,
      );
      final sevenBytesMax = Uint8List.fromList(List<int>.filled(7, 0xff));
      expect(
        bit.convertStringValueToProvidedType<int>(sevenBytesMax, 56),
        0x00ffffffffffffff,
      );
      expect(
        bit.convertStringValueToProvidedType<num>(sevenBytesMax, 56),
        0x00ffffffffffffff,
      );
      expect(
        bit.convertStringValueToProvidedType<BigInt>(sevenBytesMax, 56),
        BigInt.from(0x00ffffffffffffff),
      );
    });

    test('rejects unsupported target types with MySQLClientException', () {
      final oneByte = Uint8List.fromList([1]);
      expect(
        () => bit.convertStringValueToProvidedType<String>(oneByte, 1),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => bit.convertStringValueToProvidedType<double>(oneByte, 1),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => bit.convertStringValueToProvidedType<DateTime>(oneByte, 1),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => bit.convertStringValueToProvidedType<Uint8List>('1', 1),
        throwsA(isA<exc.MySQLClientException>()),
      );
    });
  });

  group('BIT ResultSetRow typed reads (text and binary protocols)', () {
    final columns = <_ColSpec>[
      const _ColSpec('bit1_zero', mysqlColumnTypeBit, length: 1),
      const _ColSpec('bit1_one', mysqlColumnTypeBit, length: 1),
      const _ColSpec('bit16', mysqlColumnTypeBit, length: 16),
      const _ColSpec('bit64_padded_zero', mysqlColumnTypeBit, length: 64),
      const _ColSpec('bit64_padded_five', mysqlColumnTypeBit, length: 64),
      const _ColSpec('bit63_max', mysqlColumnTypeBit, length: 63),
      const _ColSpec('bit64_msb_min', mysqlColumnTypeBit, length: 64),
      const _ColSpec('bit64_msb_max', mysqlColumnTypeBit, length: 64),
      const _ColSpec('bit_empty', mysqlColumnTypeBit, length: 1),
      const _ColSpec('bit_9bytes', mysqlColumnTypeBit, length: 64),
      const _ColSpec('bit_null', mysqlColumnTypeBit, length: 64),
    ];

    final rowBytes = <Uint8List?>[
      Uint8List.fromList([0x00]),
      Uint8List.fromList([0x01]),
      Uint8List.fromList([0xab, 0xcd]),
      Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0]),
      Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 5]),
      Uint8List.fromList([0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
      Uint8List.fromList([0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
      Uint8List.fromList([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
      Uint8List(0),
      Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9]),
      null,
    ];

    void verifyBitRow(ResultSetRow row, {required String label}) {
      void expectValid(
        int index,
        String name, {
        required bool expectedBool,
        required int expectedInt,
        required BigInt expectedBigInt,
        required List<int> expectedBytes,
      }) {
        expect(row.typedColAt<bool>(index), expectedBool,
            reason: '$label #$index bool');
        expect(row.typedColByName<bool>(name), expectedBool,
            reason: '$label $name bool');
        expect(row.typedColAt<int>(index), expectedInt,
            reason: '$label #$index int');
        expect(row.typedColByName<int>(name), expectedInt,
            reason: '$label $name int');
        expect(row.typedColAt<num>(index), expectedInt,
            reason: '$label #$index num');
        expect(row.typedColByName<num>(name), expectedInt,
            reason: '$label $name num');
        expect(
          row.typedColAt<BigInt>(index),
          expectedBigInt,
          reason: '$label #$index BigInt',
        );
        expect(
          row.typedColByName<BigInt>(name),
          expectedBigInt,
          reason: '$label $name BigInt',
        );
        expect(
          row.typedColAt<Uint8List>(index),
          expectedBytes,
          reason: '$label #$index Uint8List',
        );
        expect(
          row.typedColByName<Uint8List>(name),
          expectedBytes,
          reason: '$label $name Uint8List',
        );
        expect(row.typedAssoc()[name], isA<Uint8List>(),
            reason: '$label $name typedAssoc');
        expect(row.typedAssoc()[name], expectedBytes,
            reason: '$label $name typedAssoc bytes');
      }

      // BIT(1) = 0
      expectValid(
        0,
        'bit1_zero',
        expectedBool: false,
        expectedInt: 0,
        expectedBigInt: BigInt.zero,
        expectedBytes: const [0x00],
      );

      // BIT(1) = 1
      expectValid(
        1,
        'bit1_one',
        expectedBool: true,
        expectedInt: 1,
        expectedBigInt: BigInt.one,
        expectedBytes: const [0x01],
      );

      // Multi-byte BIT(16) = 0xabcd
      expectValid(
        2,
        'bit16',
        expectedBool: true,
        expectedInt: 0xabcd,
        expectedBigInt: BigInt.from(0xabcd),
        expectedBytes: const [0xab, 0xcd],
      );

      // 8-byte zero-padded BIT(64) = 0
      expectValid(
        3,
        'bit64_padded_zero',
        expectedBool: false,
        expectedInt: 0,
        expectedBigInt: BigInt.zero,
        expectedBytes: const [0, 0, 0, 0, 0, 0, 0, 0],
      );

      // 8-byte zero-padded BIT(64) = 5
      expectValid(
        4,
        'bit64_padded_five',
        expectedBool: true,
        expectedInt: 5,
        expectedBigInt: BigInt.from(5),
        expectedBytes: const [0, 0, 0, 0, 0, 0, 0, 5],
      );

      // Max signed BIT(63) = 0x7fffffffffffffff
      expectValid(
        5,
        'bit63_max',
        expectedBool: true,
        expectedInt: 0x7fffffffffffffff,
        expectedBigInt: BigInt.parse('9223372036854775807'),
        expectedBytes: const [0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
      );

      // Unsigned BIT(64) MSB set: 0x8000000000000000 (2^63)
      final twoPow63Bytes = const [0x80, 0, 0, 0, 0, 0, 0, 0];
      final twoPow63 = BigInt.parse('9223372036854775808');
      expect(row.typedColAt<BigInt>(6), twoPow63);
      expect(row.typedColByName<BigInt>('bit64_msb_min'), twoPow63);
      expect(row.typedColAt<Uint8List>(6), twoPow63Bytes);
      expect(row.typedColByName<Uint8List>('bit64_msb_min'), twoPow63Bytes);
      expect(row.typedColAt<bool>(6), isTrue);
      expect(row.typedColByName<bool>('bit64_msb_min'), isTrue);
      expect(
        () => row.typedColAt<int>(6),
        throwsA(
          isA<exc.MySQLClientException>().having(
            (e) => e.message,
            'message',
            contains('BigInt'),
          ),
        ),
      );
      expect(
        () => row.typedColByName<int>('bit64_msb_min'),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => row.typedColAt<num>(6),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => row.typedColByName<num>('bit64_msb_min'),
        throwsA(isA<exc.MySQLClientException>()),
      );

      // Unsigned BIT(64) all ones: 0xffffffffffffffff (2^64 - 1)
      final maxU64Bytes = List<int>.filled(8, 0xff);
      final maxU64 = BigInt.parse('18446744073709551615');
      expect(row.typedColAt<BigInt>(7), maxU64);
      expect(row.typedColByName<BigInt>('bit64_msb_max'), maxU64);
      expect(row.typedColAt<Uint8List>(7), maxU64Bytes);
      expect(row.typedColByName<Uint8List>('bit64_msb_max'), maxU64Bytes);
      expect(row.typedColAt<bool>(7), isTrue);
      expect(row.typedColByName<bool>('bit64_msb_max'), isTrue);
      expect(
        () => row.typedColAt<int>(7),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => row.typedColByName<int>('bit64_msb_max'),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => row.typedColAt<num>(7),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => row.typedColByName<num>('bit64_msb_max'),
        throwsA(isA<exc.MySQLClientException>()),
      );

      // Empty Uint8List(0)
      expectValid(
        8,
        'bit_empty',
        expectedBool: false,
        expectedInt: 0,
        expectedBigInt: BigInt.zero,
        expectedBytes: const <int>[],
      );

      // >8-byte payload throws MySQLClientException on numeric/bool conversions
      expect(
        () => row.typedColAt<bool>(9),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => row.typedColByName<bool>('bit_9bytes'),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => row.typedColAt<int>(9),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => row.typedColByName<int>('bit_9bytes'),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => row.typedColAt<num>(9),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => row.typedColByName<num>('bit_9bytes'),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => row.typedColAt<BigInt>(9),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(
        () => row.typedColByName<BigInt>('bit_9bytes'),
        throwsA(isA<exc.MySQLClientException>()),
      );
      expect(row.typedColAt<Uint8List>(9), const [1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect(
        row.typedColByName<Uint8List>('bit_9bytes'),
        const [1, 2, 3, 4, 5, 6, 7, 8, 9],
      );

      // NULL
      expect(row.typedColAt<bool>(10), isNull);
      expect(row.typedColByName<bool>('bit_null'), isNull);
      expect(row.typedColAt<int>(10), isNull);
      expect(row.typedColByName<int>('bit_null'), isNull);
      expect(row.typedColAt<num>(10), isNull);
      expect(row.typedColByName<num>('bit_null'), isNull);
      expect(row.typedColAt<BigInt>(10), isNull);
      expect(row.typedColByName<BigInt>('bit_null'), isNull);
      expect(row.typedColAt<Uint8List>(10), isNull);
      expect(row.typedColByName<Uint8List>('bit_null'), isNull);
      expect(row.typedAssoc()['bit_null'], isNull);
    }

    test('text and binary result set rows decode and convert all BIT cases',
        () async {
      final server = await _FakeMySQLServer.start(
        columns: columns,
        rows: [rowBytes],
      );
      addTearDown(server.close);

      final conn = await MySQLConnection.createConnection(
        host: '127.0.0.1',
        port: server.port,
        userName: 'root',
        password: '',
        secure: false,
      );
      await conn.connect(timeoutMs: 5000);
      addTearDown(conn.close);

      final textResult = await conn.execute('SELECT * FROM bit_cases');
      verifyBitRow(textResult.rows.single, label: 'text');

      final iterTextResult =
          await conn.execute('SELECT * FROM bit_cases', null, true);
      final iterTextRows = await iterTextResult.rowsStream.toList();
      verifyBitRow(iterTextRows.single, label: 'iterable-text');

      final stmt = await conn.prepare('SELECT * FROM bit_cases');
      final binaryResult = await stmt.execute(const []);
      verifyBitRow(binaryResult.rows.single, label: 'binary');
      await stmt.deallocate();

      final iterStmt = await conn.prepare('SELECT * FROM bit_cases', true);
      final iterBinaryResult = await iterStmt.execute(const []);
      final iterBinaryRows = await iterBinaryResult.rowsStream.toList();
      verifyBitRow(iterBinaryRows.single, label: 'iterable-binary');
      await iterStmt.deallocate();
    });
  });

  group('Column flag bitmask constants and getters', () {
    const expectedMasks = <String, int>{
      'isNotNull': 0x0001,
      'isPrimaryKey': 0x0002,
      'isUniqueKey': 0x0004,
      'isMultipleKey': 0x0008,
      'isBlob': 0x0010,
      'isUnsigned': 0x0020,
      'isZeroFill': 0x0040,
      'isBinary': 0x0080,
      'isEnum': 0x0100,
      'isAutoIncrement': 0x0200,
      'isTimestamp': 0x0400,
      'isSet': 0x0800,
    };

    test('constants on MySQLColumnDefinitionPacket and ResultSetColumn match',
        () {
      expect(_packetFlags, hasLength(12));
      expect(_resultColumnFlags, hasLength(12));

      for (var i = 0; i < 12; i++) {
        final p = _packetFlags[i];
        final r = _resultColumnFlags[i];
        expect(p.name, r.name);
        expect(p.mask, expectedMasks[p.name], reason: p.name);
        expect(r.mask, expectedMasks[r.name], reason: r.name);
      }
    });

    test('ResultSetColumn constructor defaults flags to 0', () {
      final col = ResultSetColumn(
        name: 'x',
        type: MySQLColumnType.longType,
        length: 1,
      );
      expect(col.name, 'x');
      expect(col.length, 1);
      expect(col.flags, 0);
      for (final flag in _resultColumnFlags) {
        expect(flag.read(col), isFalse, reason: flag.name);
      }
    });

    test(
        'MySQLColumnDefinitionPacket constructor and decode expose all 12 flags',
        () {
      final none = MySQLColumnDefinitionPacket.decode(
        _encodeColumnDefinitionPayload(
          name: 'none',
          type: mysqlColumnTypeLong,
          length: 11,
          flags: 0,
        ),
      );
      expect(none.flags, 0);
      for (final flag in _packetFlags) {
        expect(flag.read(none), isFalse, reason: 'none ${flag.name}');
      }

      for (final target in _packetFlags) {
        final decoded = MySQLColumnDefinitionPacket.decode(
          _encodeColumnDefinitionPayload(
            name: target.name,
            type: mysqlColumnTypeLong,
            length: 11,
            flags: target.mask,
          ),
        );
        expect(decoded.flags, target.mask);
        for (final candidate in _packetFlags) {
          expect(
            candidate.read(decoded),
            candidate.mask == target.mask,
            reason: '${target.name} packet -> ${candidate.name}',
          );
        }
      }

      const allTwelveMask = 0x0fff;
      final all = MySQLColumnDefinitionPacket(
        catalog: 'def',
        schema: 'db',
        table: 't',
        orgTable: 't',
        name: 'all',
        orgName: 'all',
        charset: 63,
        columnLength: 64,
        type: MySQLColumnType.bitType,
        flags: allTwelveMask,
        decimals: 0,
      );
      expect(all.flags, allTwelveMask);
      for (final flag in _packetFlags) {
        expect(flag.read(all), isTrue, reason: 'all ${flag.name}');
      }
    });

    test('IResultSet.cols exposes flags and all 12 getters across protocols',
        () async {
      const compositePkMask = ResultSetColumn.flagNotNull |
          ResultSetColumn.flagPrimaryKey |
          ResultSetColumn.flagUnsigned |
          ResultSetColumn.flagAutoIncrement;

      final specs = <_ColSpec>[
        const _ColSpec('col_zero', mysqlColumnTypeLong, flags: 0),
        for (final f in _resultColumnFlags)
          _ColSpec('col_${f.name}', mysqlColumnTypeLong, flags: f.mask),
        const _ColSpec('col_all', mysqlColumnTypeLong, flags: 0x0fff),
        const _ColSpec('col_pk', mysqlColumnTypeLong, flags: compositePkMask),
      ];

      final server = await _FakeMySQLServer.start(
        columns: specs,
        rows: const [],
      );
      addTearDown(server.close);

      final conn = await MySQLConnection.createConnection(
        host: '127.0.0.1',
        port: server.port,
        userName: 'root',
        password: '',
        secure: false,
      );
      await conn.connect(timeoutMs: 5000);
      addTearDown(conn.close);

      void verifyResultCols(IResultSet resultSet, {required String label}) {
        final cols = resultSet.cols.toList();
        expect(cols, hasLength(specs.length), reason: label);

        // Source-compatible construction using type obtained from public cols.
        final defaultCol = ResultSetColumn(
          name: 'x',
          type: cols.first.type,
          length: 1,
        );
        expect(defaultCol.flags, 0);

        // 0: flags = 0
        expect(cols[0].flags, 0, reason: '$label zero');
        for (final f in _resultColumnFlags) {
          expect(f.read(cols[0]), isFalse, reason: '$label zero ${f.name}');
        }

        // 1..12: isolated single-bit flags
        for (var i = 0; i < _resultColumnFlags.length; i++) {
          final expectedFlag = _resultColumnFlags[i];
          final col = cols[i + 1];
          expect(col.flags, expectedFlag.mask, reason: '$label ${col.name}');
          for (final candidate in _resultColumnFlags) {
            expect(
              candidate.read(col),
              candidate.mask == expectedFlag.mask,
              reason: '$label ${col.name} -> ${candidate.name}',
            );
          }
        }

        // 13: all 12 flags set
        final allCol = cols[13];
        expect(allCol.flags, 0x0fff, reason: '$label all');
        for (final f in _resultColumnFlags) {
          expect(f.read(allCol), isTrue, reason: '$label all ${f.name}');
        }

        // 14: composite PK column
        final pkCol = cols[14];
        expect(pkCol.flags, compositePkMask);
        expect(pkCol.isNotNull, isTrue);
        expect(pkCol.isPrimaryKey, isTrue);
        expect(pkCol.isUnsigned, isTrue);
        expect(pkCol.isAutoIncrement, isTrue);
        expect(pkCol.isUniqueKey, isFalse);
        expect(pkCol.isMultipleKey, isFalse);
        expect(pkCol.isBlob, isFalse);
        expect(pkCol.isZeroFill, isFalse);
        expect(pkCol.isBinary, isFalse);
        expect(pkCol.isEnum, isFalse);
        expect(pkCol.isTimestamp, isFalse);
        expect(pkCol.isSet, isFalse);
      }

      verifyResultCols(
        await conn.execute('SELECT * FROM flags_test'),
        label: 'text',
      );

      final iterText =
          await conn.execute('SELECT * FROM flags_test', null, true);
      await iterText.rowsStream.drain<void>();
      verifyResultCols(iterText, label: 'iterable-text');

      final stmt = await conn.prepare('SELECT * FROM flags_test');
      verifyResultCols(await stmt.execute(const []), label: 'binary');
      await stmt.deallocate();

      final iterStmt = await conn.prepare('SELECT * FROM flags_test', true);
      final iterBinary = await iterStmt.execute(const []);
      await iterBinary.rowsStream.drain<void>();
      verifyResultCols(iterBinary, label: 'iterable-binary');
      await iterStmt.deallocate();
    });
  });
}

class _ColSpec {
  final String name;
  final int type;
  final int length;
  final int flags;

  const _ColSpec(
    this.name,
    this.type, {
    this.length = 11,
    this.flags = 0,
  });
}

class _FakeMySQLServer {
  final ServerSocket _server;
  final List<_ColSpec> columns;
  final List<List<Uint8List?>> rows;
  final _clients = <Socket>[];

  _FakeMySQLServer._(this._server, this.columns, this.rows);

  int get port => _server.port;

  static Future<_FakeMySQLServer> start({
    required List<_ColSpec> columns,
    required List<List<Uint8List?>> rows,
  }) async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = _FakeMySQLServer._(socket, columns, rows);
    socket.listen(server._handleClient);
    return server;
  }

  Future<void> close() async {
    for (final client in _clients) {
      client.destroy();
    }
    await _server.close();
  }

  void _handleClient(Socket client) {
    _clients.add(client);
    client.setOption(SocketOption.tcpNoDelay, true);
    client.done.ignore();

    // Send initial handshake greeting (MySQL 5.7 mysql_native_password).
    client.add(_frame(0, _initialHandshakePayload()));

    var authenticated = false;
    final pending = BytesBuilder(copy: false);

    client.listen(
      (chunk) {
        pending.add(chunk);
        final bytes = pending.takeBytes();
        var offset = 0;
        while (bytes.length - offset >= 4) {
          final length = bytes[offset] |
              (bytes[offset + 1] << 8) |
              (bytes[offset + 2] << 16);
          if (bytes.length - offset < 4 + length) {
            break;
          }
          final seq = bytes[offset + 3];
          final payload =
              Uint8List.sublistView(bytes, offset + 4, offset + 4 + length);
          offset += 4 + length;

          if (!authenticated) {
            authenticated = true;
            client.add(_frame(seq + 1, _okPayload()));
            continue;
          }

          final cmd = payload.isNotEmpty ? payload[0] : -1;
          switch (cmd) {
            case 0x01: // COM_QUIT
            case 0x19: // COM_STMT_CLOSE
              break;
            case 0x03: // COM_QUERY
              final sql = utf8.decode(payload.sublist(1), allowMalformed: true);
              if (sql.startsWith('SET ')) {
                client.add(_frame(1, _okPayload()));
              } else {
                client.add(_buildResultSetResponse(binary: false));
              }
              break;
            case 0x16: // COM_STMT_PREPARE
              client.add(_buildPrepareOkResponse());
              break;
            case 0x17: // COM_STMT_EXECUTE
              client.add(_buildResultSetResponse(binary: true));
              break;
            default:
              client.add(_frame(1, _okPayload()));
          }
        }
        if (offset < bytes.length) {
          pending.add(Uint8List.sublistView(bytes, offset));
        }
      },
      onError: (_) {},
      onDone: client.destroy,
    );
  }

  Uint8List _buildPrepareOkResponse() {
    final out = BytesBuilder(copy: false);
    var seq = 1;
    final header = ByteData(12)
      ..setUint8(0, 0x00)
      ..setUint32(1, 1, Endian.little)
      ..setUint16(5, columns.length, Endian.little)
      ..setUint16(7, 0, Endian.little)
      ..setUint8(9, 0)
      ..setUint16(10, 0, Endian.little);
    out.add(_frame(seq++, header.buffer.asUint8List()));
    if (columns.isNotEmpty) {
      for (final col in columns) {
        out.add(
          _frame(
            seq++,
            _encodeColumnDefinitionPayload(
              name: col.name,
              type: col.type,
              length: col.length,
              flags: col.flags,
            ),
          ),
        );
      }
      out.add(_frame(seq++, _eofPayload()));
    }
    return out.takeBytes();
  }

  Uint8List _buildResultSetResponse({required bool binary}) {
    final out = BytesBuilder(copy: false);
    var seq = 1;
    out.add(_frame(seq++, _encodeLenInt(columns.length)));
    for (final col in columns) {
      out.add(
        _frame(
          seq++,
          _encodeColumnDefinitionPayload(
            name: col.name,
            type: col.type,
            length: col.length,
            flags: col.flags,
          ),
        ),
      );
    }
    out.add(_frame(seq++, _eofPayload()));
    for (final row in rows) {
      out.add(
        _frame(
          seq++,
          binary ? _encodeBinaryRow(row) : _encodeTextRow(row),
        ),
      );
    }
    out.add(_frame(seq++, _eofPayload()));
    return out.takeBytes();
  }

  Uint8List _encodeTextRow(List<Uint8List?> row) {
    final out = BytesBuilder(copy: false);
    for (final cell in row) {
      if (cell == null) {
        out.addByte(0xfb);
      } else {
        out.add(_encodeLenInt(cell.length));
        out.add(cell);
      }
    }
    return out.takeBytes();
  }

  Uint8List _encodeBinaryRow(List<Uint8List?> row) {
    final out = BytesBuilder(copy: false);
    out.addByte(0x00);
    final bitmap = Uint8List((columns.length + 9) >> 3);
    for (var i = 0; i < row.length; i++) {
      if (row[i] == null) {
        final bit = i + 2;
        bitmap[bit >> 3] |= 1 << (bit & 7);
      }
    }
    out.add(bitmap);
    for (final cell in row) {
      if (cell != null) {
        out.add(_encodeLenInt(cell.length));
        out.add(cell);
      }
    }
    return out.takeBytes();
  }
}

Uint8List _frame(int seq, List<int> payload) => Uint8List.fromList([
      payload.length & 0xff,
      (payload.length >> 8) & 0xff,
      (payload.length >> 16) & 0xff,
      seq & 0xff,
      ...payload,
    ]);

Uint8List _okPayload() =>
    Uint8List.fromList(const [0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]);

Uint8List _eofPayload() =>
    Uint8List.fromList(const [0xfe, 0x00, 0x00, 0x02, 0x00]);

Uint8List _initialHandshakePayload() {
  final out = BytesBuilder(copy: false)
    ..addByte(0x0a) // protocol v10
    ..add(utf8.encode('5.7.31'))
    ..addByte(0x00)
    ..add(const [0x01, 0x00, 0x00, 0x00]) // connection id
    ..add(List<int>.filled(8, 0x41)) // auth-plugin-data-part-1
    ..addByte(0x00) // filler
    ..add(const [0xff, 0xf7]) // capability flags lower 2 bytes
    ..addByte(0x2d) // utf8mb4 charset
    ..add(const [0x02, 0x00]) // status flags
    ..add(const [0x0f, 0x80]) // capability flags upper 2 bytes (PLUGIN_AUTH)
    ..addByte(21) // auth plugin data length
    ..add(List<int>.filled(10, 0x00)) // reserved
    ..add(List<int>.filled(12, 0x42)) // auth-plugin-data-part-2
    ..addByte(0x00)
    ..add(utf8.encode('mysql_native_password'))
    ..addByte(0x00);
  return out.takeBytes();
}

Uint8List _encodeColumnDefinitionPayload({
  required String name,
  required int type,
  required int length,
  required int flags,
}) {
  final out = BytesBuilder(copy: false)
    ..add(_encodeLenStr('def'))
    ..add(_encodeLenStr('db'))
    ..add(_encodeLenStr('t'))
    ..add(_encodeLenStr('t'))
    ..add(_encodeLenStr(name))
    ..add(_encodeLenStr(name))
    ..addByte(0x0c);
  final fixed = ByteData(12)
    ..setUint16(0, 63, Endian.little)
    ..setUint32(2, length, Endian.little)
    ..setUint8(6, type)
    ..setUint16(7, flags, Endian.little)
    ..setUint8(9, 0)
    ..setUint16(10, 0, Endian.little);
  out.add(fixed.buffer.asUint8List());
  return out.takeBytes();
}

Uint8List _encodeLenStr(String value) {
  final bytes = utf8.encode(value);
  return Uint8List.fromList([..._encodeLenInt(bytes.length), ...bytes]);
}

Uint8List _encodeLenInt(int value) {
  if (value < 0xfb) {
    return Uint8List.fromList([value]);
  }
  return Uint8List.fromList([0xfc, value & 0xff, (value >> 8) & 0xff]);
}
