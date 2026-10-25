import 'dart:convert';
import 'dart:typed_data';

import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/src/mysql_protocol/column_utils.dart';
import 'package:test/test.dart';

const int _unsignedFlag = 0x20;

MySQLColumnDefinitionPacket _col(
  int type, {
  int charset = 45,
  int columnLength = 255,
  int flags = 0,
  String name = 'c',
}) {
  return MySQLColumnDefinitionPacket(
    catalog: 'def',
    schema: 'db',
    table: 't',
    orgTable: 't',
    name: name,
    orgName: name,
    charset: charset,
    columnLength: columnLength,
    type: MySQLColumnType.create(type),
    flags: flags,
    decimals: 0,
  );
}

final Matcher _throwsProtocolException = throwsA(isA<MySQLProtocolException>());

void main() {
  group('MySQLResultSetRowPacket.decode bounds and null handling', () {
    test('rejects empty buffer and truncated subsequent column', () {
      final col = _col(mysqlColumnTypeVarChar);
      expect(
        () => MySQLResultSetRowPacket.decode(Uint8List(0), [col]),
        _throwsProtocolException,
      );
      expect(
        () => MySQLResultSetRowPacket.decode(
          Uint8List.fromList([0xfb]),
          [col, col],
        ),
        _throwsProtocolException,
      );
    });

    test('decodes 0-column empty row and preserves trailing packet bytes', () {
      final emptyRow = MySQLResultSetRowPacket.decode(
        Uint8List(0),
        const <MySQLColumnDefinitionPacket>[],
      );
      expect(emptyRow.values, isEmpty);

      final rowWithTrailingBytes = MySQLResultSetRowPacket.decode(
        Uint8List.fromList([0x02, 0x6f, 0x6b, 0xaa, 0xbb]),
        [_col(mysqlColumnTypeVarChar)],
      );
      expect(rowWithTrailingBytes.values, ['ok']);
    });

    test('rejects truncated 0xfc, 0xfd, 0xfe headers and invalid 0xff marker',
        () {
      final col = _col(mysqlColumnTypeVarChar);
      for (final bytes in <List<int>>[
        [0xfc],
        [0xfc, 0x01],
        [0xfd, 0x01, 0x00],
        [0xfe, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        [0xff],
      ]) {
        expect(
          () =>
              MySQLResultSetRowPacket.decode(Uint8List.fromList(bytes), [col]),
          _throwsProtocolException,
          reason: 'bytes: $bytes',
        );
      }
    });

    test('rejects payload length exceeding buffer and 64-bit 0xfe overflow',
        () {
      final col = _col(mysqlColumnTypeVarChar);
      for (final bytes in <List<int>>[
        // 1-byte header declaring 10 bytes with 0 bytes remaining
        [0x0a],
        // 0xfc declaring 300 bytes with 1 byte remaining
        [0xfc, 0x2c, 0x01, 0x41],
        // 0xfd declaring 70000 bytes with 0 bytes remaining
        [0xfd, 0x70, 0x11, 0x01],
        // 0xfe with max uint64 (previously clamped to 2^63-1 and overflowed valueEnd)
        [0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
        // 0xfe with high word > 0 and low word = 1
        [0xfe, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x41],
        // 0xfe with bit 31 set in low word (4294967295 bytes)
        [0xfe, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00],
      ]) {
        expect(
          () =>
              MySQLResultSetRowPacket.decode(Uint8List.fromList(bytes), [col]),
          _throwsProtocolException,
          reason: 'bytes: $bytes',
        );
      }
    });

    test('decodes valid 0xfc, 0xfd, and 0xfe length-encoded fields', () {
      final col = _col(mysqlColumnTypeVarChar);

      final fcRow = MySQLResultSetRowPacket.decode(
        Uint8List.fromList([0xfc, 0x02, 0x00, 0x68, 0x69]),
        [col],
      );
      expect(fcRow.values, ['hi']);

      final fdRow = MySQLResultSetRowPacket.decode(
        Uint8List.fromList([0xfd, 0x02, 0x00, 0x00, 0x6f, 0x6b]),
        [col],
      );
      expect(fdRow.values, ['ok']);

      final feRow = MySQLResultSetRowPacket.decode(
        Uint8List.fromList(
          [0xfe, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x67, 0x6f],
        ),
        [col],
      );
      expect(feRow.values, ['go']);
    });

    test('decodes 0xfb as null for JSON and handles binary vs utf8 BLOBs', () {
      final jsonBinaryCharset =
          _col(mysqlColumnTypeJson, charset: mysqlBinaryCollationId);
      final jsonUtf8Charset = _col(mysqlColumnTypeJson, charset: 45);
      final binaryBlob = _col(
        mysqlColumnTypeBlob,
        charset: mysqlBinaryCollationId,
        flags: mysqlColumnFlagBinary,
      );
      final utf8Blob = _col(
        mysqlColumnTypeBlob,
        charset: 33,
        flags: mysqlColumnFlagBinary,
      );
      final bitCol = _col(mysqlColumnTypeBit, charset: mysqlBinaryCollationId);
      final geomCol =
          _col(mysqlColumnTypeGeometry, charset: mysqlBinaryCollationId);

      const jsonText = '{"ok":true}';
      final jsonBytes = utf8.encode(jsonText);
      final payload = Uint8List.fromList([
        0xfb, // null JSON
        jsonBytes.length,
        ...jsonBytes, // non-null JSON
        0x02,
        0xde,
        0xad, // binary BLOB (charset 63)
        0x03,
        0x61,
        0x62,
        0x63, // textual BLOB (charset 33)
        0x01,
        0x05, // BIT
        0x02,
        0x01,
        0x02, // GEOMETRY
      ]);

      final row = MySQLResultSetRowPacket.decode(
        payload,
        [
          jsonBinaryCharset,
          jsonUtf8Charset,
          binaryBlob,
          utf8Blob,
          bitCol,
          geomCol,
        ],
      );

      expect(row.values[0], isNull);
      expect(row.values[1], jsonText);
      expect(row.values[2], isA<Uint8List>());
      expect(row.values[2], [0xde, 0xad]);
      expect(row.values[3], 'abc');
      expect(row.values[4], isA<Uint8List>());
      expect(row.values[4], [0x05]);
      expect(row.values[5], isA<Uint8List>());
      expect(row.values[5], [0x01, 0x02]);
    });

    test('falls back safely when binaryColumns is shorter than columns', () {
      final row = MySQLResultSetRowPacket.decode(
        Uint8List.fromList([0x01, 0x41, 0x02, 0xfe, 0xff]),
        [
          _col(mysqlColumnTypeVarChar),
          _col(mysqlColumnTypeBlob, charset: mysqlBinaryCollationId),
        ],
        binaryColumns: const <bool>[false],
      );

      expect(row.values[0], 'A');
      expect(row.values[1], isA<Uint8List>());
      expect(row.values[1], [0xfe, 0xff]);
    });
  });

  group('MySQLBinaryResultSetRowPacket.decode bounds and null bitmaps', () {
    test(
        'rejects empty buffer and truncated single- or multi-byte null bitmaps',
        () {
      final col = _col(mysqlColumnTypeTiny);

      // Empty packet buffer
      expect(
        () => MySQLBinaryResultSetRowPacket.decode(Uint8List(0), [col]),
        _throwsProtocolException,
      );

      // Missing 1-byte null bitmap for 1 column
      expect(
        () => MySQLBinaryResultSetRowPacket.decode(
          Uint8List.fromList([0x00]),
          [col],
        ),
        _throwsProtocolException,
      );

      // 7 columns require a 2-byte null bitmap ((7 + 9) >> 3 == 2)
      final sevenCols = List.filled(7, col);
      expect(
        () => MySQLBinaryResultSetRowPacket.decode(
          Uint8List.fromList([0x00, 0xff]),
          sevenCols,
        ),
        _throwsProtocolException,
      );

      // 15 columns require a 3-byte null bitmap ((15 + 9) >> 3 == 3)
      final fifteenCols = List.filled(15, col);
      expect(
        () => MySQLBinaryResultSetRowPacket.decode(
          Uint8List.fromList([0x00, 0xff, 0xff]),
          fifteenCols,
        ),
        _throwsProtocolException,
      );
    });

    test('decodes 0-column binary row packet', () {
      final row = MySQLBinaryResultSetRowPacket.decode(
        Uint8List.fromList([0x00]),
        const <MySQLColumnDefinitionPacket>[],
      );
      expect(row.values, isEmpty);
    });

    test('decodes >8-column null bitmap across multiple bitmap bytes', () {
      // 10 columns -> 2-byte null bitmap ((10 + 9) >> 3 == 2), bits 2..11.
      // Mark columns 0 (bit 2 -> byte0 0x04), 6 (bit 8 -> byte1 0x01),
      // and 9 (bit 11 -> byte1 0x08) as NULL.
      final cols = List<MySQLColumnDefinitionPacket>.generate(
        10,
        (i) => _col(mysqlColumnTypeTiny, flags: _unsignedFlag, name: 'c$i'),
      );
      final packet = Uint8List.fromList([
        0x00, // OK header
        0x04, // bitmap byte 0: bit 2 set (col 0 is NULL)
        0x09, // bitmap byte 1: bits 0 and 3 set (cols 6 and 9 are NULL)
        1, 2, 3, 4, 5, // cols 1..5
        7, 8, // cols 7..8
        0xaa, // trailing byte ignored
      ]);

      final row = MySQLBinaryResultSetRowPacket.decode(packet, cols);
      expect(row.values, [
        null,
        '1',
        '2',
        '3',
        '4',
        '5',
        null,
        '7',
        '8',
        null,
      ]);
    });

    test(
        'rejects truncated headers, 0xfb/0xff markers, and 0xfe shift overflow',
        () {
      final col = _col(mysqlColumnTypeVarChar);

      for (final bytes in <List<int>>[
        // Missing length byte after header + null bitmap
        [0x00, 0x00],
        // 0xfb NULL marker is invalid inside a non-null binary field
        [0x00, 0x00, 0xfb],
        // 0xff invalid length-encoded integer marker
        [0x00, 0x00, 0xff],
        // Truncated 0xfc, 0xfd, 0xfe headers
        [0x00, 0x00, 0xfc, 0x01],
        [0x00, 0x00, 0xfd, 0x01, 0x00],
        [0x00, 0x00, 0xfe, 0x01, 0x00, 0x00, 0x00],
        // Declared payload exceeds remaining bytes
        [0x00, 0x00, 0x05, 0x41],
        // Fuzz reproducer: (value << 4) signed 64-bit shift overflowed negative
        [
          0x00,
          0x00,
          0xfe,
          0xfe,
          0x01,
          0x34,
          0x00,
          0xf8,
          0x00,
          0x4d,
          0x79,
          0xfe
        ],
        // Upper nibble 0x1000000000000001 previously dropped by (value << 4)
        [
          0x00,
          0x00,
          0xfe,
          0x01,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x10,
          0x41
        ],
      ]) {
        expect(
          () => MySQLBinaryResultSetRowPacket.decode(
            Uint8List.fromList(bytes),
            [col],
          ),
          _throwsProtocolException,
          reason: 'bytes: $bytes',
        );
      }
    });

    test(
        'decodes binary JSON, BLOB charsets, BIT, GEOMETRY, and short textualColumns',
        () {
      final cols = [
        _col(mysqlColumnTypeJson, charset: mysqlBinaryCollationId),
        _col(
          mysqlColumnTypeBlob,
          charset: mysqlBinaryCollationId,
          flags: mysqlColumnFlagBinary,
        ),
        _col(mysqlColumnTypeBlob, charset: 33, flags: mysqlColumnFlagBinary),
        _col(mysqlColumnTypeBit, charset: mysqlBinaryCollationId),
        _col(mysqlColumnTypeGeometry, charset: mysqlBinaryCollationId),
      ];

      final payload = Uint8List.fromList([
        0x00, // header
        0x00, // null bitmap (0 nulls)
        0x02, 0x5b, 0x5d, // JSON "[]"
        0x02, 0xca, 0xfe, // binary BLOB (charset 63)
        0x02, 0x6f, 0x6b, // utf8 BLOB (charset 33)
        0x01, 0x07, // BIT
        0x02, 0x10, 0x20, // GEOMETRY
      ]);

      final row = MySQLBinaryResultSetRowPacket.decode(
        payload,
        cols,
        // Shorter than cols.length: must fall back safely for remaining columns.
        textualColumns: const <bool>[true],
      );

      expect(row.values[0], '[]');
      expect(row.values[1], isA<Uint8List>());
      expect(row.values[1], [0xca, 0xfe]);
      expect(row.values[2], 'ok');
      expect(row.values[3], isA<Uint8List>());
      expect(row.values[3], [0x07]);
      expect(row.values[4], isA<Uint8List>());
      expect(row.values[4], [0x10, 0x20]);
    });
  });

  group('parseBinaryColumnData bounds and wire validation', () {
    void expectTruncatedThrows(
      int columnType,
      List<int> bytes, {
      int startOffset = 0,
      bool unsigned = false,
    }) {
      final buffer = Uint8List.fromList(bytes);
      final data = ByteData.sublistView(buffer);
      expect(
        () => parseBinaryColumnData(
          columnType,
          data,
          buffer,
          startOffset,
          unsigned: unsigned,
        ),
        _throwsProtocolException,
        reason: 'type=0x${columnType.toRadixString(16)} bytes=$bytes '
            'offset=$startOffset unsigned=$unsigned',
      );
    }

    test(
        'rejects negative or overflowing startOffset and mismatched ByteData/Uint8List views',
        () {
      const maxInt64 = 0x7fffffffffffffff;
      final buffer = Uint8List.fromList([0x04, 1, 2, 3, 4]);
      final fullData = ByteData.sublistView(buffer);
      expect(
        () => parseBinaryColumnData(mysqlColumnTypeTiny, fullData, buffer, -1),
        _throwsProtocolException,
      );
      expect(
        () => parseBinaryColumnData(
          mysqlColumnTypeTiny,
          fullData,
          buffer,
          maxInt64,
        ),
        _throwsProtocolException,
      );
      expect(
        () => parseBinaryColumnData(
          mysqlColumnTypeDateTime,
          fullData,
          buffer,
          maxInt64,
        ),
        _throwsProtocolException,
      );
      expect(
        () => parseBinaryColumnData(
          mysqlColumnTypeTime,
          fullData,
          buffer,
          maxInt64,
        ),
        _throwsProtocolException,
      );
      expect(
        () => parseBinaryColumnData(
          mysqlColumnTypeVarChar,
          fullData,
          buffer,
          maxInt64,
        ),
        _throwsProtocolException,
      );

      // readLengthEncodedSlice rejects out-of-range limit and overflowing offset
      expect(
        () => readLengthEncodedSlice(
          Uint8List(8),
          0,
          100,
          allowNullMarker: true,
        ),
        _throwsProtocolException,
      );
      expect(
        () => readLengthEncodedSlice(
          Uint8List(8),
          0,
          -1,
          allowNullMarker: true,
        ),
        _throwsProtocolException,
      );
      expect(
        () => readLengthEncodedSlice(
          Uint8List.fromList([0xfc, 0x01, 0x00]),
          maxInt64 - 1,
          3,
          allowNullMarker: false,
        ),
        _throwsProtocolException,
      );

      // ByteData view shorter than buffer
      expect(
        () => parseBinaryColumnData(
          mysqlColumnTypeLong,
          ByteData.sublistView(buffer, 0, 2),
          buffer,
          0,
        ),
        _throwsProtocolException,
      );

      // Uint8List shorter than ByteData view
      expect(
        () => parseBinaryColumnData(
          mysqlColumnTypeVarChar,
          fullData,
          Uint8List.sublistView(buffer, 0, 1),
          0,
        ),
        _throwsProtocolException,
      );
    });

    test('rejects truncated fixed-width numeric and year buffers', () {
      for (final unsigned in [false, true]) {
        expectTruncatedThrows(mysqlColumnTypeTiny, const [],
            unsigned: unsigned);
        expectTruncatedThrows(mysqlColumnTypeShort, [0x01], unsigned: unsigned);
        expectTruncatedThrows(
          mysqlColumnTypeInt24,
          [0x01, 0x02, 0x03],
          unsigned: unsigned,
        );
        expectTruncatedThrows(
          mysqlColumnTypeLong,
          [0x01, 0x02, 0x03],
          unsigned: unsigned,
        );
        expectTruncatedThrows(
          mysqlColumnTypeLongLong,
          [1, 2, 3, 4, 5, 6, 7],
          unsigned: unsigned,
        );
      }
      expectTruncatedThrows(mysqlColumnTypeFloat, [1, 2, 3]);
      expectTruncatedThrows(mysqlColumnTypeDouble, [1, 2, 3, 4, 5, 6, 7]);
      expectTruncatedThrows(mysqlColumnTypeYear, [0xe8]);
    });

    test('decodes valid signed and unsigned fixed-width integers', () {
      final tinyBuf = Uint8List.fromList([0xc8]); // 200 unsigned / -56 signed
      expect(
        parseBinaryColumnData(
          mysqlColumnTypeTiny,
          ByteData.sublistView(tinyBuf),
          tinyBuf,
          0,
        ).$1,
        '-56',
      );
      expect(
        parseBinaryColumnData(
          mysqlColumnTypeTiny,
          ByteData.sublistView(tinyBuf),
          tinyBuf,
          0,
          unsigned: true,
        ).$1,
        '200',
      );

      final maxU64 = Uint8List.fromList(List.filled(8, 0xff));
      expect(
        parseBinaryColumnData(
          mysqlColumnTypeLongLong,
          ByteData.sublistView(maxU64),
          maxU64,
          0,
          unsigned: true,
        ).$1,
        '18446744073709551615',
      );
    });

    test(
        'rejects truncated and invalid-length binary DATE/DATETIME/TIMESTAMP/TIME',
        () {
      for (final type in [
        mysqlColumnTypeDate,
        mysqlColumnTypeDateTime,
        mysqlColumnTypeTimestamp,
      ]) {
        expectTruncatedThrows(type, const []);
        expectTruncatedThrows(
            type, [0x04, 0xe8, 0x07]); // needs 4 payload bytes
        expectTruncatedThrows(
          type,
          [0x07, 0xe8, 0x07, 0x03, 0x0a, 0x0c, 0x00],
        );
        expectTruncatedThrows(
          type,
          [0x0b, 0xe8, 0x07, 0x03, 0x0a, 0x0c, 0x00, 0x00, 0x01, 0x00],
        );
        // Invalid MySQL binary date/datetime length byte (only 0, 4, 7, 11 allowed)
        expectTruncatedThrows(type, [0x05, 0xe8, 0x07, 0x03, 0x0a, 0x99]);
      }

      for (final type in [mysqlColumnTypeTime, mysqlColumnTypeTime2]) {
        expectTruncatedThrows(type, const []);
        expectTruncatedThrows(type, [0x08, 0x00, 0x01, 0x00, 0x00]);
        expectTruncatedThrows(
          type,
          [0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04],
        );
        // Invalid MySQL binary time length byte (only 0, 8, 12 allowed)
        expectTruncatedThrows(type, [0x03, 0x01, 0x02, 0x03]);
      }
    });

    test('decodes valid 0, 4, 7, 11-byte DATETIME and 0, 8, 12-byte TIME', () {
      for (final (bytes, expected) in <(List<int>, String)>[
        ([0x00], '0000-00-00 00:00:00'),
        ([0x04, 0xe8, 0x07, 0x03, 0x0a], '2024-03-10 00:00:00'),
        (
          [0x07, 0xe8, 0x07, 0x03, 0x0a, 0x0c, 0x22, 0x38],
          '2024-03-10 12:34:56'
        ),
        (
          [
            0x0b,
            0xe8,
            0x07,
            0x03,
            0x0a,
            0x0c,
            0x22,
            0x38,
            0x88,
            0x13,
            0x00,
            0x00,
          ],
          '2024-03-10 12:34:56.005000'
        ),
      ]) {
        final buf = Uint8List.fromList(bytes);
        final res = parseBinaryColumnData(
          mysqlColumnTypeDateTime,
          ByteData.sublistView(buf),
          buf,
          0,
        );
        expect(res.$1, expected);
        expect(res.$2, bytes.length);
      }

      for (final (bytes, expected) in <(List<int>, String)>[
        ([0x00], '00:00:00'),
        ([0x08, 0x01, 0x02, 0x00, 0x00, 0x00, 0x03, 0x04, 0x05], '-51:04:05'),
        (
          [
            0x0c,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x01,
            0x02,
            0x03,
            0x07,
            0x00,
            0x00,
            0x00,
          ],
          '01:02:03.000007'
        ),
      ]) {
        final buf = Uint8List.fromList(bytes);
        final res = parseBinaryColumnData(
          mysqlColumnTypeTime,
          ByteData.sublistView(buf),
          buf,
          0,
        );
        expect(res.$1, expected);
        expect(res.$2, bytes.length);
      }
    });

    test(
        'rejects empty, truncated, or 0xfb length-encoded columns and tolerates malformed UTF-8',
        () {
      for (final type in [
        mysqlColumnTypeDecimal,
        mysqlColumnTypeNewDecimal,
        mysqlColumnTypeVarChar,
        mysqlColumnTypeVarString,
        mysqlColumnTypeString,
        mysqlColumnTypeEnum,
        mysqlColumnTypeSet,
        mysqlColumnTypeJson,
        mysqlColumnTypeTinyBlob,
        mysqlColumnTypeMediumBlob,
        mysqlColumnTypeLongBlob,
        mysqlColumnTypeBlob,
        mysqlColumnTypeBit,
        mysqlColumnTypeGeometry,
      ]) {
        expectTruncatedThrows(type, const []);
        expectTruncatedThrows(type, [0xfb]);
        expectTruncatedThrows(type, [0x03, 0x41]);
      }

      final malformedUtf8 = Uint8List.fromList([0x02, 0xff, 0xfe]);
      for (final type in [mysqlColumnTypeVarChar, mysqlColumnTypeJson]) {
        final res = parseBinaryColumnData(
          type,
          ByteData.sublistView(malformedUtf8),
          malformedUtf8,
          0,
        );
        expect(res.$1, isA<String>());
        expect(res.$2, 3);
      }
    });
  });

  group('MySQLColumnType.convertStringValueToProvidedType safety', () {
    test(
        'throws MySQLProtocolException instead of TypeError on non-String values',
        () {
      final rawBytes = Uint8List.fromList([0x01, 0x02]);

      expect(
        () => MySQLColumnType.blobType
            .convertStringValueToProvidedType<String>(rawBytes),
        _throwsProtocolException,
      );
      expect(
        () => MySQLColumnType.tinyType
            .convertStringValueToProvidedType<bool>(rawBytes, 1),
        _throwsProtocolException,
      );
      expect(
        () => MySQLColumnType.longType
            .convertStringValueToProvidedType<int>(rawBytes),
        _throwsProtocolException,
      );
      expect(
        () => MySQLColumnType.doubleType
            .convertStringValueToProvidedType<double>(rawBytes),
        _throwsProtocolException,
      );
      expect(
        () => MySQLColumnType.floatType
            .convertStringValueToProvidedType<num>(rawBytes),
        _throwsProtocolException,
      );
      expect(
        () => MySQLColumnType.dateTimeType
            .convertStringValueToProvidedType<DateTime>(rawBytes),
        _throwsProtocolException,
      );
      expect(
        () => MySQLColumnType.varCharType
            .convertStringValueToProvidedType<Uint8List>('abc'),
        _throwsProtocolException,
      );
    });

    test(
        'supports Uint8List, Object, dynamic, nullable targets, and zero dates',
        () {
      final rawBytes = Uint8List.fromList([0xde, 0xad]);
      expect(
        MySQLColumnType.blobType
            .convertStringValueToProvidedType<Uint8List>(rawBytes),
        same(rawBytes),
      );
      expect(
        MySQLColumnType.blobType
            .convertStringValueToProvidedType<Uint8List?>(rawBytes),
        same(rawBytes),
      );
      expect(
        MySQLColumnType.blobType
            .convertStringValueToProvidedType<Object>(rawBytes),
        same(rawBytes),
      );
      expect(
        MySQLColumnType.blobType
            .convertStringValueToProvidedType<dynamic>(rawBytes),
        same(rawBytes),
      );
      expect(
        MySQLColumnType.longType.convertStringValueToProvidedType<int?>('42'),
        42,
      );
      expect(
        MySQLColumnType.longType.convertStringValueToProvidedType<int?>(null),
        isNull,
      );
      expect(
        MySQLColumnType.dateTimeType
            .convertStringValueToProvidedType<DateTime>('0000-00-00 00:00:00'),
        isNull,
      );
    });
  });
}
