import 'dart:async';
import 'dart:isolate';

/// Thrown on the host side when a worker call fails, times out, or the worker
/// exits unexpectedly.
class IsolateRpcException implements Exception {
  const IsolateRpcException(this.message);

  final String message;

  @override
  String toString() => 'IsolateRpcException: $message';
}

typedef RpcHandler = FutureOr<Object?> Function(String op, Object? args);

/// Worker-side RPC server. Call once from the isolate entry point.
///
/// Requests are processed strictly one at a time, including asynchronous
/// handlers. A failed request is reported to the host without killing the
/// worker; an invalid/unreadable message is ignored safely.
void serveRpc(SendPort host, RpcHandler handler) {
  final ReceivePort inbox = ReceivePort();
  Future<void> queue = Future<void>.value();

  inbox.listen((Object? message) {
    queue = queue.then((_) => _dispatchRpcMessage(host, handler, message));
  });

  host.send(inbox.sendPort);
}

Future<void> _dispatchRpcMessage(
  SendPort host,
  RpcHandler handler,
  Object? message,
) async {
  if (message is! List || message.length != 3 || message[0] is! int) {
    return;
  }

  final int id = message[0] as int;
  try {
    final String op = message[1] as String;
    final Object? args = message[2];
    final Object? result = await handler(op, args);
    try {
      host.send(<Object?>[id, true, result]);
    } catch (sendError, sendStack) {
      // A non-sendable result must become an ordinary RPC error instead of
      // escaping the worker's event loop and leaving the caller pending.
      try {
        host.send(<Object?>[id, false, '$sendError\n$sendStack']);
      } catch (_) {
        // The host may already have gone away.
      }
    }
  } catch (error, stackTrace) {
    try {
      host.send(<Object?>[id, false, '$error\n$stackTrace']);
    } catch (_) {
      // The host may already have gone away.
    }
  }
}

class _PendingRpc {
  _PendingRpc(this.completer, this.timer);

  final Completer<Object?> completer;
  final Timer timer;
}

/// Host-side controller for a long-lived worker isolate.
///
/// Every request has a bounded lifetime. A timeout terminates the worker and
/// fails *all* outstanding requests because a timed-out serial worker cannot
/// be trusted to process later queued messages.
class IsolateRpc {
  IsolateRpc._(this._isolate, this._inbox, this._errors, this._exits);

  static const Duration defaultStartupTimeout = Duration(seconds: 10);
  static const Duration defaultCallTimeout = Duration(seconds: 90);

  final Isolate _isolate;
  final ReceivePort _inbox;
  final ReceivePort _errors;
  final ReceivePort _exits;
  final Completer<void> _ready = Completer<void>();
  final Map<int, _PendingRpc> _pending = <int, _PendingRpc>{};

  SendPort? _worker;
  int _nextId = 0;
  bool _closed = false;

  bool get isClosed => _closed;

  /// [entry] must be a top-level or static function. It receives
  /// `[SendPort host, Object? init]` and must call [serveRpc].
  static Future<IsolateRpc> spawn(
    void Function(List<Object?> boot) entry,
    Object? init, {
    String? debugName,
    Duration startupTimeout = defaultStartupTimeout,
  }) async {
    if (startupTimeout <= Duration.zero) {
      throw ArgumentError.value(
        startupTimeout,
        'startupTimeout',
        'Must be greater than zero',
      );
    }

    final ReceivePort inbox = ReceivePort();
    final ReceivePort errors = ReceivePort();
    final ReceivePort exits = ReceivePort();

    late final Isolate isolate;
    try {
      isolate = await Isolate.spawn<List<Object?>>(
        entry,
        <Object?>[inbox.sendPort, init],
        onError: errors.sendPort,
        onExit: exits.sendPort,
        debugName: debugName,
      );
    } catch (_) {
      inbox.close();
      errors.close();
      exits.close();
      rethrow;
    }

    final IsolateRpc rpc = IsolateRpc._(isolate, inbox, errors, exits);
    inbox.listen(rpc._onMessage);
    errors.listen(rpc._onError);
    exits.listen(rpc._onExit);

    try {
      await rpc._ready.future.timeout(startupTimeout);
    } on Object catch (error, stackTrace) {
      rpc._fail(
        IsolateRpcException('Worker did not become ready: $error'),
        terminate: true,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }

    return rpc;
  }

  Future<T?> call<T>(String op, [Object? args]) =>
      callWithTimeout<T>(op, args: args);

  /// Sends an RPC request and fails the worker if it does not respond in time.
  Future<T?> callWithTimeout<T>(
    String op, {
    Object? args,
    Duration timeout = defaultCallTimeout,
  }) async {
    if (_closed) {
      throw const IsolateRpcException('Worker is closed');
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'Must be greater than zero',
      );
    }

    final SendPort? worker = _worker;
    if (worker == null) {
      throw const IsolateRpcException('Worker is not ready');
    }

    final int id = _nextId++;
    final Completer<Object?> completer = Completer<Object?>();
    final Timer timer = Timer(timeout, () {
      _fail(
        IsolateRpcException(
          'Timed out after ${timeout.inMilliseconds} ms waiting for RPC "$op"',
        ),
        terminate: true,
      );
    });
    _pending[id] = _PendingRpc(completer, timer);

    try {
      worker.send(<Object?>[id, op, args]);
    } catch (error, stackTrace) {
      final _PendingRpc? pending = _pending.remove(id);
      pending?.timer.cancel();
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.completeError(
          IsolateRpcException('Could not send RPC "$op": $error'),
          stackTrace,
        );
      }
    }

    final Object? result = await completer.future;
    return result as T?;
  }

  Future<void> dispose() async {
    if (_closed) return;
    _fail(const IsolateRpcException('Worker disposed'), terminate: true);
  }

  void _onMessage(Object? message) {
    if (message is SendPort) {
      _worker = message;
      if (!_ready.isCompleted) _ready.complete();
      return;
    }

    if (message is! List || message.length != 3 || message[0] is! int) {
      return;
    }

    final int id = message[0] as int;
    final _PendingRpc? pending = _pending.remove(id);
    if (pending == null) return; // Late reply to a timed-out/cancelled call.

    pending.timer.cancel();
    if (pending.completer.isCompleted) return;

    if (message[1] == true) {
      pending.completer.complete(message[2]);
    } else {
      pending.completer.completeError(IsolateRpcException('${message[2]}'));
    }
  }

  void _onError(Object? error) {
    final String message = error is List && error.isNotEmpty
        ? '${error[0]}'
        : '$error';
    _fail(IsolateRpcException('Worker crashed: $message'));
  }

  void _onExit(Object? _) {
    if (!_closed) {
      _fail(const IsolateRpcException('Worker exited unexpectedly'));
    }
  }

  void _fail(IsolateRpcException error, {bool terminate = false}) {
    if (_closed) return;
    _closed = true;

    if (!_ready.isCompleted) {
      _ready.completeError(error);
    }

    final List<_PendingRpc> waiting = _pending.values.toList();
    _pending.clear();
    for (final _PendingRpc pending in waiting) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }

    _inbox.close();
    _errors.close();
    _exits.close();

    if (terminate) {
      _isolate.kill(priority: Isolate.immediate);
    }
  }
}
