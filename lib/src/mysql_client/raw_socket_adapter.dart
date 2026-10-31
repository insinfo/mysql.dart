import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A [Socket] over a [RawSocket] the driver keeps a handle to.
///
/// `SecureSocket.secure` takes over the [Socket] it upgrades: destroying that
/// Socket afterwards does nothing, so a server that sent the greeting and
/// then never answered the TLS handshake kept the TCP connection open after
/// `connect()` timed out. `RawSecureSocket.secure` upgrades a [RawSocket]
/// this adapter still holds, and [destroy] closes it at any point of the
/// handshake. Used for TLS connections only; plain ones keep [Socket].
class RawSocketAdapter extends Stream<Uint8List> implements Socket {
  RawSocketAdapter(this._raw) {
    _controller
      ..onListen = _updateReadEvents
      ..onPause = _updateReadEvents
      ..onResume = _updateReadEvents
      ..onCancel = _updateReadEvents;
    // Read events are delivered while someone listens and has not paused
    // (backpressure); write events only while a write is incomplete.
    _raw.readEventsEnabled = false;
    _raw.writeEventsEnabled = false;
    _subscription = _raw.listen(
      _onEvent,
      onError: _onError,
      onDone: _onDone,
    );
    // done reports write failures (connection reset); the driver observes it,
    // this keeps an unobserved one from becoming an uncaught error.
    _done.future.ignore();
  }

  final RawSocket _raw;
  late final StreamSubscription<RawSocketEvent> _subscription;
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>(sync: true);
  final ListQueue<Uint8List> _pendingWrites = ListQueue<Uint8List>();
  int _pendingOffset = 0;
  final List<Completer<void>> _flushWaiters = [];
  final Completer<void> _done = Completer<void>();
  bool _detached = false;
  bool _destroyed = false;

  @override
  Encoding encoding = utf8;

  /// Hands the raw socket and its subscription to `RawSecureSocket.secure`.
  /// Pending writes must be flushed first. The adapter delivers no more
  /// events, but [destroy] still closes the transport, which aborts the
  /// handshake.
  ({RawSocket socket, StreamSubscription<RawSocketEvent> subscription})
      detachForUpgrade() {
    if (_pendingWrites.isNotEmpty) {
      throw StateError('Pending writes must be flushed before the upgrade');
    }
    _detached = true;
    return (socket: _raw, subscription: _subscription);
  }

  void _updateReadEvents() {
    if (_detached || _destroyed) return;
    _raw.readEventsEnabled = _controller.hasListener && !_controller.isPaused;
  }

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        final data = _raw.read();
        if (data != null) _controller.add(data);
      case RawSocketEvent.write:
        _writePending();
      case RawSocketEvent.readClosed:
        // Data the server sent before closing comes first.
        while (_raw.available() > 0) {
          final data = _raw.read();
          if (data == null) break;
          _controller.add(data);
        }
        _closeStream();
      case RawSocketEvent.closed:
        _closeStream();
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (!_controller.isClosed) _controller.addError(error, stackTrace);
    _failWrites(error, stackTrace);
  }

  void _onDone() => _closeStream();

  void _closeStream() {
    if (!_controller.isClosed) _controller.close();
    _completeFlushWaiters();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  void add(List<int> data) {
    if (_destroyed || _detached) {
      throw StateError('StreamSink is closed');
    }
    if (data.isEmpty) return;
    _pendingWrites.add(data is Uint8List ? data : Uint8List.fromList(data));
    _writePending();
  }

  void _writePending() {
    if (_destroyed || _detached) return;
    try {
      while (_pendingWrites.isNotEmpty) {
        final chunk = _pendingWrites.first;
        _pendingOffset += _raw.write(chunk, _pendingOffset);
        if (_pendingOffset < chunk.length) {
          // The socket buffer is full; the next write event resumes here.
          _raw.writeEventsEnabled = true;
          return;
        }
        _pendingWrites.removeFirst();
        _pendingOffset = 0;
      }
    } catch (error, stackTrace) {
      _failWrites(error, stackTrace);
      return;
    }
    _completeFlushWaiters();
  }

  void _failWrites(Object error, StackTrace stackTrace) {
    _pendingWrites.clear();
    _pendingOffset = 0;
    final waiters = List.of(_flushWaiters);
    _flushWaiters.clear();
    for (final waiter in waiters) {
      waiter.completeError(error, stackTrace);
    }
    if (!_done.isCompleted) _done.completeError(error, stackTrace);
  }

  void _completeFlushWaiters() {
    final waiters = List.of(_flushWaiters);
    _flushWaiters.clear();
    for (final waiter in waiters) {
      waiter.complete();
    }
  }

  @override
  Future<void> flush() {
    if (_pendingWrites.isEmpty || _destroyed) return Future.value();
    final waiter = Completer<void>();
    _flushWaiters.add(waiter);
    return waiter.future;
  }

  @override
  Future<void> close() async {
    await flush();
    destroy();
    return done;
  }

  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _pendingWrites.clear();
    _pendingOffset = 0;
    if (!_detached) unawaited(_subscription.cancel());
    // After detachForUpgrade the subscription belongs to the TLS upgrade;
    // closing the socket under it is what aborts a stalled handshake.
    unawaited(_raw.close().then<void>((_) {}, onError: (Object _) {}));
    _closeStream();
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    throw UnsupportedError('addError is not supported on a MySQL socket');
  }

  @override
  void write(Object? object) => add(encoding.encode('$object'));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _raw.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _raw.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _raw.setRawOption(option);

  @override
  int get port => _raw.port;

  @override
  int get remotePort => _raw.remotePort;

  @override
  InternetAddress get address => _raw.address;

  @override
  InternetAddress get remoteAddress => _raw.remoteAddress;
}

/// [RawSocketAdapter] over the upgraded [RawSecureSocket]: `getSocket()` is
/// still a [SecureSocket], with the server's certificate.
class SecureRawSocketAdapter extends RawSocketAdapter implements SecureSocket {
  SecureRawSocketAdapter(RawSecureSocket super.raw);

  RawSecureSocket get _secure => _raw as RawSecureSocket;

  @override
  X509Certificate? get peerCertificate => _secure.peerCertificate;

  @override
  String? get selectedProtocol => _secure.selectedProtocol;

  @override
  // ignore: deprecated_member_use
  void renegotiate({
    bool useSessionCache = true,
    bool requestClientCertificate = false,
    bool requireClientCertificate = false,
  }) {
    throw UnsupportedError('renegotiate is not supported');
  }
}
