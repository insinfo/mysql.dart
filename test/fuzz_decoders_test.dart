// Fuzzes the decoders of server packets with mutations of real packets
// (test/fixtures/server_packets_*.json, captured by
// tool/capture_server_packets.dart).
//
// Bytes from the server may only fail with a MySQLException: a RangeError,
// a TypeError or a decoder that never returns means a malformed packet
// escapes the driver's error handling.
//
// FUZZ_ITERATIONS (default 200) sets the mutations per seed and target and
// FUZZ_SEED the random sequence; a finding prints the input that caused it.
//
// A few seconds on an idle machine; the timeout leaves room for a slow CI
// runner and matches the deadline of each target's isolate.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_protocol.dart';
import 'package:mysql_dart/src/mysql_client/caching_sha2_auth.dart';
import 'package:test/test.dart';

final _iterations =
    int.tryParse(Platform.environment['FUZZ_ITERATIONS'] ?? '') ?? 200;
final _baseSeed = int.tryParse(Platform.environment['FUZZ_SEED'] ?? '') ?? 1;

typedef _Row = ({
  Uint8List packet,
  List<MySQLColumnDefinitionPacket> columns,
  List<Uint8List> columnPackets,
  bool binary,
});

void main() {
  final seeds = _Seeds.load();

  test('the fixtures have every kind of seed', () {
    expect(seeds.packets, isNotEmpty);
    expect(seeds.handshakes, hasLength(greaterThanOrEqualTo(2)));
    expect(seeds.textRows, isNotEmpty);
    expect(seeds.binaryRows, isNotEmpty);
    expect(seeds.publicKeys, isNotEmpty);
  });

  final packetTargets = <String, void Function(Uint8List)>{
    'detectPacketType': MySQLPacket.detectPacketType,
    'decodeInitialHandshake': MySQLPacket.decodeInitialHandshake,
    'decodeAuthSwitchRequestPacket': MySQLPacket.decodeAuthSwitchRequestPacket,
    'decodeGenericPacket': MySQLPacket.decodeGenericPacket,
    'decodeColumnCountPacket': MySQLPacket.decodeColumnCountPacket,
    'decodeColumnDefPacket': MySQLPacket.decodeColumnDefPacket,
    'decodeCommPrepareStmtResponsePacket':
        MySQLPacket.decodeCommPrepareStmtResponsePacket,
  };

  for (final MapEntry(key: name, value: decode) in packetTargets.entries) {
    // The greeting is the only packet the handshake decoder should parse;
    // every other target gets every packet the servers sent.
    final targetSeeds =
        name == 'decodeInitialHandshake' ? seeds.handshakes : seeds.packets;
    test('$name only fails with MySQLException', () async {
      final findings = await _fuzz<Uint8List>(
        name,
        targetSeeds,
        bytesOf: (s) => s,
        run: (_, mutated) => decode(mutated),
      );
      expect(findings, isEmpty, reason: findings.join('\n\n'));
    });
  }

  test('text rows and typed reads only fail with MySQLException', () async {
    final findings = await _fuzz<_Row>(
      'decodeResultSetRowPacket',
      seeds.textRows,
      bytesOf: (s) => s.packet,
      run: (seed, mutated) {
        final row = MySQLPacket.decodeResultSetRowPacket(mutated, seed.columns)
            .payload as MySQLResultSetRowPacket;
        _typedReads(row.values, seed.columns);
      },
    );
    expect(findings, isEmpty, reason: findings.join('\n\n'));
  });

  test('binary rows and typed reads only fail with MySQLException', () async {
    final findings = await _fuzz<_Row>(
      'decodeBinaryResultSetRowPacket',
      seeds.binaryRows,
      bytesOf: (s) => s.packet,
      run: (seed, mutated) {
        final row =
            MySQLPacket.decodeBinaryResultSetRowPacket(mutated, seed.columns)
                .payload as MySQLBinaryResultSetRowPacket;
        _typedReads(row.values, seed.columns);
      },
    );
    expect(findings, isEmpty, reason: findings.join('\n\n'));
  });

  test('rows decoded with mutated column definitions', () async {
    // The row is intact; the server lies about one column's type or length.
    final findings = await _fuzz<(_Row, int)>(
      'row with mutated column definition',
      [
        for (final row in [...seeds.textRows, ...seeds.binaryRows])
          for (var c = 0; c < row.columns.length; c++) (row, c),
      ],
      bytesOf: (s) => s.$1.columnPackets[s.$2],
      run: (seed, mutated) {
        final (row, index) = seed;
        final column = MySQLPacket.decodeColumnDefPacket(mutated).payload
            as MySQLColumnDefinitionPacket;
        final columns = [...row.columns]..[index] = column;
        final values = row.binary
            ? (MySQLPacket.decodeBinaryResultSetRowPacket(row.packet, columns)
                    .payload as MySQLBinaryResultSetRowPacket)
                .values
            : (MySQLPacket.decodeResultSetRowPacket(row.packet, columns).payload
                    as MySQLResultSetRowPacket)
                .values;
        _typedReads(values, columns);
      },
    );
    expect(findings, isEmpty, reason: findings.join('\n\n'));
  });

  test('the RSA public key from the server only fails cleanly', () async {
    // FormatException is how caching_sha2_auth reports a malformed key.
    final authSeed = Uint8List.fromList(List.generate(20, (i) => i + 1));
    final findings = await _fuzz<Uint8List>(
      'buildCachingSha2EncryptedPassword',
      seeds.publicKeys,
      bytesOf: (s) => _frame(0, s),
      allowed: (e) => e is MySQLException || e is FormatException,
      run: (_, mutated) => buildCachingSha2EncryptedPassword(
        'dart',
        authSeed,
        _pem(mutated.length > 4 ? mutated.sublist(4) : Uint8List(0)),
      ),
    );
    expect(findings, isEmpty, reason: findings.join('\n\n'));
  });
}

/// Reads every column as each type an application might ask for.
void _typedReads(
    List<dynamic> values, List<MySQLColumnDefinitionPacket> columns) {
  for (var i = 0; i < values.length && i < columns.length; i++) {
    final type = columns[i].type;
    final length = columns[i].columnLength;
    final value = values[i];
    for (final read in <void Function()>[
      () => type.convertStringValueToProvidedType<String>(value, length),
      () => type.convertStringValueToProvidedType<int>(value, length),
      () => type.convertStringValueToProvidedType<double>(value, length),
      () => type.convertStringValueToProvidedType<num>(value, length),
      () => type.convertStringValueToProvidedType<bool>(value, length),
      () => type.convertStringValueToProvidedType<DateTime>(value, length),
      () => type.convertStringValueToProvidedType<BigInt>(value, length),
      () => type.convertStringValueToProvidedType<Uint8List>(value, length),
      () => type.convertStringValueToProvidedType<Object>(value, length),
    ]) {
      try {
        read();
      } on MySQLException {
        // Refusing a conversion is fine; anything else is a finding.
      }
    }
  }
}

/// Mutates every seed [_iterations] times in an isolate and returns one line
/// per distinct finding (exception type and the frame that threw it).
Future<List<String>> _fuzz<S>(
  String target,
  List<S> seeds, {
  required Uint8List Function(S seed) bytesOf,
  required void Function(S seed, Uint8List mutated) run,
  bool Function(Object error) allowed = _isMySQLException,
}) async {
  final iterations = _iterations;
  final baseSeed = _baseSeed;
  List<String> work() {
    final findings = <String, String>{};
    final counts = <String, int>{};
    for (var s = 0; s < seeds.length; s++) {
      final original = bytesOf(seeds[s]);
      for (var i = 0; i < iterations; i++) {
        final seed = baseSeed * 1000003 + s * 7919 + i;
        final mutated = _mutate(Random(seed), original);
        try {
          run(seeds[s], mutated);
        } catch (e, st) {
          if (allowed(e)) continue;
          final frame = st
              .toString()
              .split('\n')
              .firstWhere((l) => l.contains('package:mysql_dart/'),
                  orElse: () => st.toString().split('\n').first)
              .replaceFirst(RegExp(r'^#\d+\s+'), '')
              .trim();
          final key = '${e.runtimeType} at $frame';
          counts[key] = (counts[key] ?? 0) + 1;
          findings.putIfAbsent(
            key,
            () => '[$target] $key\n'
                '  ${e.toString().split('\n').first}\n'
                '  seed $seed, input ${_hex(mutated)}',
          );
        }
      }
    }
    return [
      for (final MapEntry(:key, :value) in findings.entries)
        '$value\n  (${counts[key]} times)',
    ];
  }

  return _runWithDeadline(work, const Duration(minutes: 2), target);
}

bool _isMySQLException(Object e) => e is MySQLException;

/// Runs [work] in an isolate; a decoder stuck in a loop becomes a finding
/// instead of hanging the suite.
Future<List<String>> _runWithDeadline(
  List<String> Function() work,
  Duration limit,
  String target,
) async {
  final port = ReceivePort();
  final isolate = await Isolate.spawn(_isolateEntry, (port.sendPort, work));
  try {
    return await port.first.timeout(limit) as List<String>;
  } on Exception {
    return ['[$target] did not finish in $limit: a decoder may loop forever'];
  } finally {
    isolate.kill(priority: Isolate.immediate);
    port.close();
  }
}

void _isolateEntry((SendPort, List<String> Function()) message) {
  message.$1.send(message.$2());
}

const _interesting = [0x00, 0x01, 0x7f, 0x80, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe];

/// One to three mutations of the payload. Most keep the header length in
/// step with the payload so the decoder gets past the envelope check.
Uint8List _mutate(Random r, Uint8List packet) {
  final seq = packet.length > 3 ? packet[3] : 0;
  var payload =
      packet.length > 4 ? Uint8List.fromList(packet.sublist(4)) : Uint8List(0);
  final rounds = 1 + r.nextInt(3);
  for (var i = 0; i < rounds; i++) {
    payload = _mutatePayload(r, payload);
  }
  if (r.nextInt(10) == 0) {
    final declared = switch (r.nextInt(4)) {
      0 => 0,
      1 => 0xffffff,
      2 => max(0, payload.length + r.nextInt(7) - 3),
      _ => r.nextInt(0x1000000),
    };
    return Uint8List.fromList([
      declared & 0xff,
      (declared >> 8) & 0xff,
      (declared >> 16) & 0xff,
      seq,
      ...payload,
    ]);
  }
  return _frame(seq, payload);
}

Uint8List _mutatePayload(Random r, Uint8List p) {
  final pos = p.isEmpty ? 0 : r.nextInt(p.length);
  switch (r.nextInt(6)) {
    case 0:
      return p.sublist(0, r.nextInt(p.length + 1));
    case 1:
      if (p.isEmpty) break;
      return Uint8List.fromList(p)..[pos] = r.nextInt(256);
    case 2:
      if (p.isEmpty) break;
      return Uint8List.fromList(p)
        ..[pos] = _interesting[r.nextInt(_interesting.length)];
    case 3:
      if (p.isEmpty) break;
      final end = min(p.length, pos + 1 + r.nextInt(8));
      return Uint8List.fromList([...p.sublist(0, pos), ...p.sublist(end)]);
    case 5:
      // A length-encoded integer that claims far more than is there.
      final width = [2, 3, 8][r.nextInt(3)];
      final marker = {2: 0xfc, 3: 0xfd, 8: 0xfe}[width]!;
      return Uint8List.fromList([
        ...p.sublist(0, pos),
        marker,
        for (var i = 0; i < width; i++) r.nextBool() ? 0xff : r.nextInt(256),
        ...p.sublist(pos),
      ]);
  }
  final extra = List.generate(1 + r.nextInt(8), (_) => r.nextInt(256));
  return Uint8List.fromList(
      [...p.sublist(0, pos), ...extra, ...p.sublist(pos)]);
}

class _Seeds {
  final packets = <Uint8List>[];
  final handshakes = <Uint8List>[];
  final textRows = <_Row>[];
  final binaryRows = <_Row>[];
  final publicKeys = <Uint8List>[];

  static _Seeds load() {
    final seeds = _Seeds();
    final files = Directory('test/fixtures')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('server_packets_'));
    for (final file in files) {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      for (final exchange in json['exchanges'] as List) {
        final command = exchange['command'] as String;
        final packets = [
          for (final hex in exchange['packets'] as List) _unhex(hex as String)
        ];
        seeds.packets.addAll(packets);
        if (command == 'handshake') {
          seeds._handshake(packets);
        } else if (command == 'query' || command == 'execute') {
          seeds._resultSet(packets, binary: command == 'execute');
        }
      }
    }
    return seeds;
  }

  void _handshake(List<Uint8List> packets) {
    handshakes.add(packets.first);
    for (final packet in packets.skip(1)) {
      final text = latin1.decode(packet.sublist(4));
      final begin = text.indexOf('-----BEGIN PUBLIC KEY-----');
      final end = text.indexOf('-----END PUBLIC KEY-----');
      if (begin < 0 || end < 0) continue;
      final body = text
          .substring(begin + '-----BEGIN PUBLIC KEY-----'.length, end)
          .replaceAll(RegExp(r'\s'), '');
      publicKeys.add(base64.decode(body));
    }
  }

  void _resultSet(List<Uint8List> packets, {required bool binary}) {
    final first = packets.first[4];
    if (first == 0x00 || first == 0xff) return;
    final count = (MySQLPacket.decodeColumnCountPacket(packets.first).payload
            as MySQLPacketColumnCount)
        .columnCount
        .toInt();
    final columns = [
      for (final p in packets.skip(1).take(count))
        MySQLPacket.decodeColumnDefPacket(p).payload
            as MySQLColumnDefinitionPacket
    ];
    var i = 1 + count;
    if (MySQLPacket.detectPacketType(packets[i]) ==
        MySQLGenericPacketType.eof) {
      i++;
    }
    for (; i < packets.length; i++) {
      final type = MySQLPacket.detectPacketType(packets[i]);
      if (type == MySQLGenericPacketType.eof ||
          type == MySQLGenericPacketType.error) {
        break;
      }
      (binary ? binaryRows : textRows).add((
        packet: packets[i],
        columns: columns,
        columnPackets: packets.sublist(1, 1 + count),
        binary: binary,
      ));
    }
  }
}

Uint8List _frame(int seq, List<int> payload) => Uint8List.fromList([
      payload.length & 0xff,
      (payload.length >> 8) & 0xff,
      (payload.length >> 16) & 0xff,
      seq,
      ...payload,
    ]);

String _pem(List<int> der) =>
    '-----BEGIN PUBLIC KEY-----\n${base64.encode(der)}\n'
    '-----END PUBLIC KEY-----\n';

Uint8List _unhex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16)
    ]);

String _hex(List<int> bytes) {
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return hex.length > 240
      ? '${hex.substring(0, 240)}… (${bytes.length} B)'
      : hex;
}
