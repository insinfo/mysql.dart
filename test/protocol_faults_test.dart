// Replays exchanges captured from real servers (test/fixtures: MySQL 5.7 for
// mysql_native_password and the commands, MySQL 9.7 for the RSA exchange of
// caching_sha2_password) through a local TCP server and breaks one of them at
// every packet: the connection drops between two packets or in the middle of
// one, an ERR, OK, EOF or empty packet replaces or precedes the expected one,
// or the bytes arrive one at a time or in a single write.
//
// Whatever the server does, the caller's future must complete before a
// deadline, with a result, a MySQLException or the TimeoutException of
// connect(timeoutMs:); an ERR before the end of an exchange must fail the
// call; no error may escape uncaught; and close() must complete. A fault that
// leaves the caller waiting forever is what a server crash or a dropped
// connection turns into a hang.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_dart.dart';
import 'package:test/test.dart';

// Generous for a loaded CI runner: only a hang waits for all of it.
const _deadline = Duration(seconds: 10);

void main() {
  // MySQL 5.7 authenticates with mysql_native_password in one round trip.
  final exchanges = _load('mysql57');
  List<Uint8List> reply(int i) => exchanges[i].packets;
  String sql(int i) => exchanges[i].sql!;
  final connectTurns = [..._handshakeTurns(exchanges), reply(1)];

  // MySQL 9.7 without TLS: caching_sha2_password asks for the full
  // authentication, sends its RSA public key, then OK.
  final sha2 = _load('mysql97');
  final sha2Turns = [..._handshakeTurns(sha2), sha2[1].packets];

  final scenarios = <_Scenario>[
    _Scenario(
        'caching_sha2 full authentication request', sha2Turns, 1, (_) async {},
        publicKeyRetrieval: true),
    _Scenario('caching_sha2 public key', sha2Turns, 2, (_) async {},
        publicKeyRetrieval: true),
    _Scenario('caching_sha2 OK', sha2Turns, 3, (_) async {},
        publicKeyRetrieval: true),
    _Scenario('greeting', connectTurns, 0, (_) async {}),
    _Scenario('auth reply', connectTurns, 1, (_) async {}),
    _Scenario('SET NAMES on connect', connectTurns, 2, (_) async {}),
    _Scenario('query with rows', [...connectTurns, reply(6)], 3,
        (conn) async => (await conn.execute(sql(6))).rows.toList()),
    _Scenario('iterable query with rows', [...connectTurns, reply(6)], 3,
        (conn) async {
      await (await conn.execute(sql(6), null, true)).rowsStream.toList();
    }),
    _Scenario('query with no rows', [...connectTurns, reply(7)], 3,
        (conn) async => (await conn.execute(sql(7))).rows.toList()),
    _Scenario('query answered by OK', [...connectTurns, reply(8)], 3,
        (conn) => conn.execute(sql(8))),
    _Scenario('query answered by ERR', [...connectTurns, reply(9)], 3,
        (conn) => conn.execute(sql(9))),
    _Scenario('prepare', [...connectTurns, reply(10), reply(11)], 3,
        (conn) async {
      final stmt = await conn.prepare(sql(10));
      (await stmt.execute([1])).rows.toList();
    }),
    _Scenario('prepared execute with rows',
        [...connectTurns, reply(10), reply(11)], 4, (conn) async {
      final stmt = await conn.prepare(sql(10));
      (await stmt.execute([1])).rows.toList();
    }),
    _Scenario(
        'iterable prepared execute', [...connectTurns, reply(10), reply(11)], 4,
        (conn) async {
      final stmt = await conn.prepare(sql(10), true);
      await (await stmt.execute([1])).rowsStream.toList();
    }),
    _Scenario('prepared DML', [...connectTurns, reply(14), reply(15)], 4,
        (conn) async {
      final stmt = await conn.prepare(sql(14));
      await stmt.execute([1, 3]);
    }),
  ];

  for (final scenario in scenarios) {
    test('${scenario.name}: every server fault ends the call', () async {
      final packets = scenario.turns[scenario.broken];
      final faults = <_Fault>[
        _Fault.coalesced(),
        _Fault.byteByByte(),
        for (var k = 0; k <= packets.length; k++) _Fault.dropBefore(k),
        for (var k = 0; k < packets.length; k++) _Fault.dropInside(k),
        // Each injected packet once on its own write and once in the same
        // write as the rest: [ERR, OK] in one TCP read used to connect.
        for (final together in [false, true])
          for (final kind in _Injected.values) ...[
            for (var k = 0; k < packets.length; k++)
              _Fault.replace(k, kind, together: together),
            for (var k = 0; k <= packets.length; k++)
              _Fault.insert(k, kind,
                  together: together, length: packets.length),
          ],
      ];
      final findings = <String>[];
      // Each run has its own server; a hang costs the deadline, so they
      // run a few at a time.
      for (var i = 0; i < faults.length; i += 16) {
        final batch = faults.skip(i).take(16);
        findings.addAll((await Future.wait(batch.map((fault) async {
          final problem = await _run(scenario, fault);
          return problem == null ? null : '$fault: $problem';
        })))
            .nonNulls);
      }
      // Without faults the scenario must simply work.
      final clean = await _run(scenario, null);
      expect(clean, isNull, reason: 'the unbroken exchange failed: $clean');
      expect(findings, isEmpty, reason: findings.join('\n'));
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}

typedef _Exchange = ({String? sql, List<Uint8List> packets});

List<_Exchange> _load(String server) {
  final fixture = jsonDecode(
          File('test/fixtures/server_packets_$server.json').readAsStringSync())
      as Map<String, dynamic>;
  return [
    for (final e in fixture['exchanges'] as List)
      (
        sql: e['sql'] as String?,
        packets: [
          for (final hex in e['packets'] as List) _unhex(hex as String)
        ],
      )
  ];
}

/// The greeting goes out on accept; each later packet of the handshake
/// answers one packet of the client (handshake response, public key
/// request, encrypted password).
List<List<Uint8List>> _handshakeTurns(List<_Exchange> exchanges) => [
      for (final packet in exchanges[0].packets) [packet]
    ];

class _Scenario {
  _Scenario(this.name, this.turns, this.broken, this.action,
      {this.publicKeyRetrieval = false});

  final String name;

  /// What the server sends: turn 0 on accept, turn i after the i-th client
  /// packet that expects an answer.
  final List<List<Uint8List>> turns;

  /// The turn the fault applies to.
  final int broken;

  /// What the application does after connect().
  final Future<void> Function(MySQLConnection conn) action;

  final bool publicKeyRetrieval;
}

enum _Injected { err, ok, eof, empty }

class _Fault {
  _Fault._(this.description, this.apply, {this.refused = false});

  _Fault.coalesced()
      : this._('all packets in one write', (packets) => _Plan(packets, 0));
  _Fault.byteByByte()
      : this._('one byte per write', (packets) => _Plan(packets, 1));
  _Fault.dropBefore(int k)
      : this._('connection dropped before packet $k',
            (packets) => _Plan(packets.sublist(0, k), null, drop: true));
  _Fault.dropInside(int k)
      : this._('connection dropped inside packet $k', (packets) {
          final half = packets[k].length ~/ 2;
          return _Plan(
              [...packets.sublist(0, k), packets[k].sublist(0, half)], null,
              drop: true);
        });
  _Fault.replace(int k, _Injected kind, {required bool together})
      : this._(
            'packet $k replaced by ${kind.name}${together ? ', one write' : ''}',
            (packets) {
          final copy = [...packets];
          copy[k] = _packet(kind, packets[k][3]);
          return _Plan(copy, together ? 0 : null);
        }, refused: kind == _Injected.err);
  _Fault.insert(int k, _Injected kind,
      {required bool together, required int length})
      : this._(
            '${kind.name} inserted before packet $k'
            '${together ? ', one write' : ''}', (packets) {
          final seq =
              k < packets.length ? packets[k][3] : (packets.last[3] + 1) & 0xff;
          return _Plan(
              [...packets]..insert(k, _packet(kind, seq)), together ? 0 : null);
        }, refused: kind == _Injected.err && k < length);

  final String description;
  final _Plan Function(List<Uint8List> packets) apply;

  /// An ERR arrives before the exchange is over: the call must fail. An
  /// ERR after the last packet comes when the command already succeeded.
  final bool refused;

  @override
  String toString() => description;
}

/// Packets to write; [chunk] null writes one packet per write, 0 all in one,
/// n > 0 n bytes per write. [drop] destroys the connection afterwards.
class _Plan {
  _Plan(this.packets, this.chunk, {this.drop = false});

  final List<Uint8List> packets;
  final int? chunk;
  final bool drop;
}

Uint8List _packet(_Injected kind, int seq) => _frame(
    seq,
    switch (kind) {
      _Injected.err => [
          0xff, 0x7a, 0x04, // 1146
          ...ascii.encode('#42S02injected error'),
        ],
      _Injected.ok => [0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00],
      _Injected.eof => [0xfe, 0x00, 0x00, 0x02, 0x00],
      _Injected.empty => <int>[],
    });

/// Runs [scenario] with [fault] and returns what went wrong, or null.
Future<String?> _run(_Scenario scenario, _Fault? fault) async {
  final server = await _ReplayServer.start(scenario, fault);
  final uncaught = <Object>[];
  final outcome = Completer<String?>();
  unawaited(runZonedGuarded(() async {
    MySQLConnection? conn;
    try {
      conn = await MySQLConnection.createConnection(
        host: '127.0.0.1',
        port: server.port,
        userName: 'dart',
        password: 'dart',
        databaseName: 'banco_teste',
        secure: false,
        allowPublicKeyRetrieval: scenario.publicKeyRetrieval,
      );
      await conn.connect(timeoutMs: 5000);
      await scenario.action(conn);
      outcome.complete(fault != null && fault.refused
          ? 'succeeded although the server sent ERR'
          : null);
    } on MySQLException {
      outcome.complete(null);
    } on TimeoutException {
      // connect(timeoutMs:) gave up: a bounded wait, as documented. It
      // happens when the script and the client part ways (an OK where the
      // script expected more of the handshake).
      outcome.complete(null);
    } catch (e) {
      outcome.complete('threw ${e.runtimeType}: $e');
    }
    try {
      await conn?.close().timeout(_deadline);
    } on TimeoutException {
      uncaught.add('close() did not complete');
    } catch (_) {
      // A failed close is fine; a hanging one is not.
    }
  }, (error, _) => uncaught.add(error)));

  var problem = await outcome.future.timeout(_deadline,
      onTimeout: () => 'the call did not complete in $_deadline');
  await Future<void>.delayed(const Duration(milliseconds: 20));
  if (uncaught.isNotEmpty) {
    problem = [
      if (problem != null) problem,
      'uncaught: ${uncaught.map((e) => '${e.runtimeType}: $e').join('; ')}',
    ].join('; ');
  }
  await server.close();
  return problem;
}

class _ReplayServer {
  _ReplayServer._(this._server, this._scenario, this._fault);

  final ServerSocket _server;
  final _Scenario _scenario;
  final _Fault? _fault;
  final _clients = <Socket>[];

  int get port => _server.port;

  static Future<_ReplayServer> start(_Scenario scenario, _Fault? fault) async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = _ReplayServer._(socket, scenario, fault);
    socket.listen(server._serve);
    return server;
  }

  Future<void> close() async {
    for (final client in _clients) {
      client.destroy();
    }
    await _server.close();
  }

  void _serve(Socket client) {
    _clients.add(client);
    client.setOption(SocketOption.tcpNoDelay, true);
    client.done.ignore();
    var turn = 0;
    var writes = Future<void>.value();
    void answer() {
      if (turn >= _scenario.turns.length) return;
      final t = turn++;
      writes = writes.then((_) => _send(client, t)).catchError((_) {});
    }

    answer();
    final pending = BytesBuilder(copy: false);
    client.listen(
      (data) {
        pending.add(data);
        final bytes = pending.takeBytes();
        var offset = 0;
        while (bytes.length - offset >= 4) {
          final length =
              bytes[offset] | bytes[offset + 1] << 8 | bytes[offset + 2] << 16;
          if (bytes.length - offset < 4 + length) break;
          final seq = bytes[offset + 3];
          final command = length > 0 ? bytes[offset + 4] : -1;
          offset += 4 + length;
          // COM_STMT_CLOSE and COM_QUIT get no answer.
          if (seq == 0 && (command == 0x19 || command == 0x01)) continue;
          answer();
        }
        pending.add(Uint8List.sublistView(bytes, offset));
      },
      onError: (_) {},
      onDone: client.destroy,
    );
  }

  Future<void> _send(Socket client, int turn) async {
    final packets = _scenario.turns[turn];
    final plan = turn == _scenario.broken && _fault != null
        ? _fault.apply(packets)
        : _Plan(packets, null);
    final chunk = plan.chunk;
    if (chunk == 0) {
      client.add([for (final p in plan.packets) ...p]);
    } else if (chunk != null) {
      final bytes = [for (final p in plan.packets) ...p];
      for (var i = 0; i < bytes.length; i += chunk) {
        client.add(bytes.sublist(i, i + chunk.clamp(0, bytes.length - i)));
        await client.flush();
      }
    } else {
      for (final packet in plan.packets) {
        client.add(packet);
        await client.flush();
      }
    }
    await client.flush();
    if (plan.drop) client.destroy();
  }
}

Uint8List _frame(int seq, List<int> payload) => Uint8List.fromList([
      payload.length & 0xff,
      (payload.length >> 8) & 0xff,
      (payload.length >> 16) & 0xff,
      seq,
      ...payload,
    ]);

Uint8List _unhex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16)
    ]);
