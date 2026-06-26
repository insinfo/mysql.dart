import 'dart:convert';
import 'dart:typed_data';

import 'package:mysql_dart/src/mysql_client/caching_sha2_auth.dart';
import 'package:mysql_dart/src/utils/byte_data_writer.dart';
import 'package:mysql_dart/src/utils/hash.dart';
import 'package:mysql_dart/src/utils/hex.dart';
import 'package:test/test.dart';

void main() {
  group('performance regression', () {
    test(
        'hash utilities handle repeated auth-sized payloads within a sane budget',
        () {
      final payload = Uint8List.fromList(
        List<int>.generate(4096, (index) => index % 251),
      );
      final watch = Stopwatch()..start();

      for (var i = 0; i < 1500; i++) {
        sha1Digest(payload);
        sha256Digest(payload);
      }

      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(4000));
    });

    test('hex codec round-trips medium payloads without pathological slowdown',
        () {
      final payload = Uint8List.fromList(
        List<int>.generate(16 * 1024, (index) => index % 256),
      );
      final watch = Stopwatch()..start();

      for (var i = 0; i < 200; i++) {
        final encoded = hex.encode(payload);
        final decoded = hex.decode(encoded);
        expect(decoded, payload);
      }

      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(3000));
    });

    test('byte writer builds many small protocol packets efficiently', () {
      final payload = utf8.encode('SELECT 1');
      final watch = Stopwatch()..start();

      for (var i = 0; i < 50000; i++) {
        final writer = ByteDataWriter(endian: Endian.little);
        writer.writeUint8(0x03);
        writer.write(payload);
        writer.writeUint32(i, Endian.little);
        final bytes = writer.toBytes();
        expect(bytes.length, payload.length + 5);
      }

      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(2500));
    });

    test('caching_sha2 RSA password encryption stays practical for handshakes',
        () {
      const publicKeyPem = '''
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDckgVqA8sCZ+1xqauRZyUYEcSi
BpFPBbA09BzLx7xd00f2cHtB90g2eUTz6Q+1xOlcOxpE2NjFttW+tF2PrXuCm0Wv
Hlv570PG1lE0VoRl92BJZzjAqpz+1HN35wX8SujF27RXvOhYyDUEpQ6q3j006vs3
8BVC4PAGQCdnJIgVrQIDAQAB
-----END PUBLIC KEY-----
''';
      final seed = Uint8List.fromList(
        List<int>.generate(20, (index) => index + 1),
      );
      final watch = Stopwatch()..start();

      for (var i = 0; i < 150; i++) {
        final encrypted = buildCachingSha2EncryptedPassword(
          'dart',
          seed,
          publicKeyPem,
        );
        expect(encrypted.length, 128);
      }

      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(3500));
    });
  });
}
