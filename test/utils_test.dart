import 'dart:convert';
import 'dart:typed_data';

import 'package:mysql_dart/src/utils/hex.dart';
import 'package:mysql_dart/mysql_protocol_extension.dart';
import 'package:mysql_dart/src/mysql_client/caching_sha2_auth.dart';
import 'package:mysql_dart/src/utils/byte_data_writer.dart';
import 'package:mysql_dart/src/utils/hash.dart';
import 'package:mysql_dart/src/utils/tuple2.dart';
import 'package:test/test.dart';

void main() {
  group('Tuple2', () {
    test('stores both items', () {
      const tuple = Tuple2<String, int>('value', 42);
      expect(tuple.item1, 'value');
      expect(tuple.item2, 42);
    });
  });

  group('Hash utils', () {
    test('sha1 matches known vector', () {
      expect(
        hex.encode(sha1Digest(utf8.encode('abc'))),
        'a9993e364706816aba3e25717850c26c9cd0d89d',
      );
    });

    test('sha256 matches known vector', () {
      expect(
        hex.encode(sha256Digest(utf8.encode('abc'))),
        'ba7816bf8f01cfea414140de5dae2223'
        'b00361a396177a9cb410ff61f20015ad',
      );
    });
  });

  group('ByteDataWriter', () {
    test('writes signed, unsigned and floating point values in little endian',
        () {
      final writer = ByteDataWriter(endian: Endian.little);
      writer.writeInt8(-1);
      writer.writeInt16(-2);
      writer.writeInt32(-3);
      writer.writeInt64(-4);
      writer.writeUint8(255);
      writer.writeUint16(65534);
      writer.writeUint32(65535);
      writer.writeUint64(65536);
      writer.writeFloat32(1.5);
      writer.writeFloat64(3.25);

      final bytes = writer.toBytes();
      final data = ByteData.sublistView(bytes);
      var offset = 0;

      expect(data.getInt8(offset), -1);
      offset += 1;
      expect(data.getInt16(offset, Endian.little), -2);
      offset += 2;
      expect(data.getInt32(offset, Endian.little), -3);
      offset += 4;
      expect(data.getInt64(offset, Endian.little), -4);
      offset += 8;
      expect(data.getUint8(offset), 255);
      offset += 1;
      expect(data.getUint16(offset, Endian.little), 65534);
      offset += 2;
      expect(data.getUint32(offset, Endian.little), 65535);
      offset += 4;
      expect(data.getUint64(offset, Endian.little), 65536);
      offset += 8;
      expect(data.getFloat32(offset, Endian.little), closeTo(1.5, 0.000001));
      offset += 4;
      expect(data.getFloat64(offset, Endian.little), closeTo(3.25, 0.000001));
    });

    test('write with copy false reflects later source mutations', () {
      final source = Uint8List.fromList([1, 2, 3]);
      final writer = ByteDataWriter(endian: Endian.little);
      writer.write(source);
      source[1] = 9;

      expect(writer.toBytes(), [1, 9, 3]);
    });

    test('write with copy true isolates later source mutations', () {
      final source = Uint8List.fromList([1, 2, 3]);
      final writer = ByteDataWriter(endian: Endian.little);
      writer.write(source, copy: true);
      source[1] = 9;

      expect(writer.toBytes(), [1, 2, 3]);
    });
  });

  group('MySQL protocol extensions', () {
    test('reads length encoded bytes', () {
      final buffer = Uint8List.fromList([0x03, 0x61, 0x62, 0x63, 0xff]);
      final value = buffer.getLengthEncodedBytes(0);

      expect(value.item1, [0x61, 0x62, 0x63]);
      expect(value.item2, 4);
    });

    test('reads int2 and int3 in little endian', () {
      final data = ByteData.sublistView(
          Uint8List.fromList([0x34, 0x12, 0x78, 0x56, 0x34]));

      expect(data.getInt2(0), 0x1234);
      expect(data.getInt3(2), 0x345678);
    });
  });

  group('Caching sha2 auth helpers', () {
    const publicKeyPem = '''
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDckgVqA8sCZ+1xqauRZyUYEcSi
BpFPBbA09BzLx7xd00f2cHtB90g2eUTz6Q+1xOlcOxpE2NjFttW+tF2PrXuCm0Wv
Hlv570PG1lE0VoRl92BJZzjAqpz+1HN35wX8SujF27RXvOhYyDUEpQ6q3j006vs3
8BVC4PAGQCdnJIgVrQIDAQAB
-----END PUBLIC KEY-----
''';

    test('builds cleartext password without implicit null terminator', () {
      expect(buildCachingSha2CleartextPassword('dart'), utf8.encode('dart'));
    });

    test('builds public key retrieval request byte', () {
      expect(buildCachingSha2PublicKeyRequest(), [0x02]);
    });

    test('encrypts password using PEM public key', () {
      final encrypted = buildCachingSha2EncryptedPassword(
        'dart',
        Uint8List.fromList(List<int>.generate(20, (index) => index + 1)),
        publicKeyPem,
      );

      expect(encrypted.length, 128);
      expect(encrypted, isNot(everyElement(0)));
    });

    test('throws for invalid PEM payload', () {
      expect(
        () => buildCachingSha2EncryptedPassword(
          'dart',
          Uint8List.fromList(List<int>.filled(20, 1)),
          'not-a-pem',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
