import 'dart:async';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_constants.dart';
import '../models/app_mode.dart';
import '../models/role_claim_result.dart';
import '../models/terminal_info.dart';
import 'app_initializer.dart';
import 'app_logger.dart';
import 'role_claim_policy.dart';

class TerminalService {
  TerminalService({
    required this.uid,
    this.database,
    this.auth,
    DeviceInfoPlugin? deviceInfo,
  }) : _deviceInfo = deviceInfo ?? DeviceInfoPlugin();

  static const _terminalIdKey = 'terminal_id';

  final String uid;
  final FirebaseDatabase? database;
  final FirebaseAuth? auth;
  final DeviceInfoPlugin _deviceInfo;
  FirebaseDatabase? _resolvedDatabase;

  String? _terminalId;
  String? _deviceName;
  Future<void>? _initialization;

  /// La base de datos se resuelve de forma diferida: el constructor no puede
  /// tocar `Firebase.app()` antes de `ensureFirebaseReady()`.
  FirebaseDatabase get _db =>
      database ??
      (_resolvedDatabase ??= FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: AppConstants.databaseUrl,
      ));

  /// Identificador local, o `null` mientras [initialize] no terminó.
  String? get terminalIdOrNull => _terminalId;

  String get terminalId => _terminalId!;
  String get deviceName => _deviceName ?? 'Este teléfono';
  DatabaseReference get _terminals => _db.ref('usuarios/$uid/terminales');
  DatabaseReference get _current => _terminals.child(terminalId);

  /// Idempotente: la app puede pedir la inicialización desde la pantalla de
  /// selección y, a la vez, desde la reserva de rol.
  Future<void> initialize() {
    final pending = _initialization;
    if (pending != null) return pending;
    final operation = _initialize();
    _initialization = operation;
    operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        if (identical(_initialization, operation)) _initialization = null;
      },
    );
    return operation;
  }

  Future<void> _initialize() async {
    await AppInitializer.ensureFirebaseReady();
    final preferences = await SharedPreferences.getInstance();
    _terminalId = preferences.getString(_terminalIdKey);
    if (_terminalId == null) {
      final random = Random.secure().nextInt(0x7fffffff).toRadixString(16);
      _terminalId = '${DateTime.now().microsecondsSinceEpoch}_$random';
      await preferences.setString(_terminalIdKey, _terminalId!);
      AppLogger.info(
        LogTags.firebase,
        'Nuevo terminalId generado: $_terminalId.',
      );
    } else {
      AppLogger.info(
        LogTags.firebase,
        'terminalId existente verificado: $_terminalId.',
      );
    }
    _deviceName = await _readDeviceName();
    AppLogger.info(
      LogTags.firebase,
      'Ruta del terminal: usuarios/$uid/terminales/$_terminalId.',
    );
  }

  Stream<TerminalInfo?> watchCurrent() => _current.onValue.map(
    (event) => TerminalInfo.fromEntry(terminalId, event.snapshot.value),
  );

  Stream<List<TerminalInfo>> watchAll() => _terminals.onValue.map((event) {
    final value = event.snapshot.value;
    if (value is! Map) return const <TerminalInfo>[];
    final terminals = <TerminalInfo>[];
    for (final entry in value.entries) {
      final terminal = TerminalInfo.fromEntry(
        entry.key.toString(),
        entry.value,
      );
      if (terminal != null && !terminal.revoked) terminals.add(terminal);
    }
    terminals.sort((a, b) {
      if (a.id == terminalId) return -1;
      if (b.id == terminalId) return 1;
      return a.name.compareTo(b.name);
    });
    return terminals;
  });

  /// Estado de la conexión con Realtime Database.
  ///
  /// Se usa antes de transaccionar: sin conexión el SDK deja la transacción
  /// pendiente hasta que vuelva la red, lo que antes se traducía en el
  /// timeout de 10 s sin causa visible.
  Stream<bool> watchConnection() => _db
      .ref('.info/connected')
      .onValue
      .map((event) => event.snapshot.value == true)
      .distinct();

  /// Espera a que RTDB esté conectada, con un límite corto.
  ///
  /// Se cancela la suscripción al vencer el límite para no acumular listeners
  /// cuando el teléfono está sin red y la reserva se reintenta.
  Future<bool> waitForConnection(Duration timeout) {
    if (timeout <= Duration.zero) return Future<bool>.value(false);

    final completer = Completer<bool>();
    StreamSubscription<bool>? subscription;
    Timer? timer;

    void finish(bool connected) {
      if (completer.isCompleted) return;
      timer?.cancel();
      final pending = subscription;
      if (pending != null) unawaited(pending.cancel());
      completer.complete(connected);
    }

    final listener = watchConnection().listen(
      (connected) {
        if (connected) finish(true);
      },
      onError: (Object error) {
        if (completer.isCompleted) return;
        AppLogger.warn(
          LogTags.firebase,
          '[TERMINAL] Error leyendo .info/connected: $error.',
        );
        finish(false);
      },
      onDone: () => finish(false),
    );
    subscription = listener;
    if (completer.isCompleted) {
      unawaited(listener.cancel());
    } else {
      timer = Timer(timeout, () => finish(false));
    }
    return completer.future;
  }

  /// Reserva el rol del terminal con reintentos y backoff.
  ///
  /// - Espera Firebase Auth y `.info/connected` antes de escribir.
  /// - Cada transacción tiene su propio límite; la campaña completa respeta
  ///   [RoleClaimPolicy.overallTimeout].
  /// - "Ocupado" y "revocado" son definitivos y no se reintentan. Un timeout
  ///   o una caída de red se devuelven como [RoleClaimResult.failed] para que
  ///   la app conserve la sesión y reintente, en lugar de cerrarla.
  Future<RoleClaimResult> claimRole(
    AppMode mode, {
    RoleClaimPolicy policy = RoleClaimPolicy.standard,
  }) async {
    try {
      await initialize();
    } catch (error, stack) {
      AppLogger.error(
        LogTags.firebase,
        '[TERMINAL] No se pudo inicializar el terminal antes de reservar el '
        'rol: $error',
        error,
        stack,
      );
      return const RoleClaimResult.failed(
        RoleClaimFailure.unknown,
        detail: 'inicialización local del terminal',
      );
    }

    final role = mode == AppMode.bridge ? 'puente' : 'monitor';
    final stopwatch = Stopwatch()..start();
    AppLogger.info(
      LogTags.firebase,
      '[TERMINAL] Reserva de rol "$role" para $terminalId: '
      'intentos=${policy.maxAttempts}, '
      'límite por intento=${policy.attemptTimeout.inSeconds} s, '
      'límite total=${policy.overallTimeout.inSeconds} s, '
      'usuario=${_currentUser()?.uid ?? 'sin sesión'}.',
    );

    if (!await _waitForAuthentication(policy.authTimeout)) {
      return const RoleClaimResult.failed(
        RoleClaimFailure.unauthenticated,
        detail: 'sin sesión o token de Firebase Auth',
      );
    }

    var lastFailure = RoleClaimFailure.unknown;
    String? lastDetail;
    var attempts = 0;

    while (attempts < policy.maxAttempts) {
      var remaining = policy.remainingBudget(stopwatch.elapsed);
      if (remaining <= Duration.zero) break;
      attempts++;

      if (attempts > 1) {
        final backoff = policy.backoffFor(attempts - 1);
        remaining = policy.remainingBudget(stopwatch.elapsed);
        if (remaining <= backoff) break;
        AppLogger.warn(
          LogTags.firebase,
          '[TERMINAL] Reintento $attempts/${policy.maxAttempts} del rol '
          '"$role" para $terminalId en ${backoff.inMilliseconds} ms '
          '(última causa: ${lastFailure.label}).',
        );
        await Future<void>.delayed(backoff);
      }

      // Sin conexión no tiene sentido esperar al servidor: se falla rápido y
      // se reintenta, en lugar de agotar un timeout ciego.
      final connectionBudget = Duration(
        milliseconds: min(
          (attempts == 1
                  ? policy.connectionTimeout
                  : policy.retryConnectionTimeout)
              .inMilliseconds,
          policy.remainingBudget(stopwatch.elapsed).inMilliseconds,
        ),
      );
      final connected = await waitForConnection(connectionBudget);
      if (!connected) {
        lastFailure = RoleClaimFailure.offline;
        lastDetail =
            'RTDB sin conexión tras ${connectionBudget.inMilliseconds} ms';
        AppLogger.warn(
          LogTags.firebase,
          '[TERMINAL] Intento $attempts/${policy.maxAttempts} del rol "$role": '
          'RTDB sin conexión tras ${connectionBudget.inMilliseconds} ms.',
        );
        continue;
      }

      final attemptTimeout = Duration(
        milliseconds: min(
          policy.attemptTimeout.inMilliseconds,
          policy.remainingBudget(stopwatch.elapsed).inMilliseconds,
        ),
      );
      if (attemptTimeout <= Duration.zero) break;

      AppLogger.info(
        LogTags.firebase,
        '[TERMINAL] Intento $attempts/${policy.maxAttempts} del rol "$role" '
        'con RTDB conectada (límite ${attemptTimeout.inSeconds} s).',
      );

      try {
        final outcome = await _runClaimTransaction(role)
            .timeout(attemptTimeout);

        if (outcome.committed) {
          // La presencia es complementaria: un fallo aquí no invalida un rol
          // ya confirmado por el servidor.
          await _configureDisconnectPresence(policy.presenceTimeout);
          AppLogger.ok(
            LogTags.firebase,
            '[TERMINAL] Rol "$role" confirmado para $terminalId en '
            '${stopwatch.elapsedMilliseconds} ms.',
          );
          return const RoleClaimResult.claimed();
        }

        if (outcome.conflictingId != null) {
          AppLogger.warn(
            LogTags.firebase,
            '[TERMINAL] Rol "$role" ocupado por '
            '${outcome.conflictingName ?? outcome.conflictingId} '
            '(${outcome.conflictingId}); no se reintenta.',
          );
          return RoleClaimResult.occupied(
            terminalId: outcome.conflictingId!,
            deviceName: outcome.conflictingName ?? 'Teléfono',
          );
        }

        if (outcome.revoked) {
          AppLogger.warn(
            LogTags.firebase,
            '[TERMINAL] $terminalId está revocado; no se reserva el rol '
            '"$role".',
          );
          return const RoleClaimResult.revoked();
        }

        lastFailure = RoleClaimFailure.unknown;
        lastDetail = 'transacción abortada sin conflicto detectado';
        AppLogger.warn(
          LogTags.firebase,
          '[TERMINAL] Intento $attempts/${policy.maxAttempts}: la transacción '
          'del rol "$role" no se confirmó ($lastDetail).',
        );
      } on TimeoutException {
        lastFailure = RoleClaimFailure.timeout;
        lastDetail =
            'sin confirmación del servidor en '
            '${attemptTimeout.inSeconds} s';
        AppLogger.warn(
          LogTags.firebase,
          '[TERMINAL] Intento $attempts/${policy.maxAttempts}: el servidor no '
          'confirmó el rol "$role" en ${attemptTimeout.inSeconds} s. La '
          'transacción puede confirmarse después; se reintenta.',
        );
      } catch (error) {
        lastFailure = _classifyFailure(error);
        lastDetail = error.toString();
        AppLogger.warn(
          LogTags.firebase,
          '[TERMINAL] Intento $attempts/${policy.maxAttempts}: error al '
          'reservar el rol "$role" (${lastFailure.label}): $error',
        );
        if (!lastFailure.isRetryable) break;
      }
    }

    AppLogger.error(
      LogTags.firebase,
      '[TERMINAL] Rol "$role" no confirmado para $terminalId tras '
      '${stopwatch.elapsed.inSeconds} s ($attempts intento(s), causa: '
      '${lastFailure.label}${lastDetail == null ? '' : ' · $lastDetail'}). '
      'La interfaz local continúa y se reintentará más tarde.',
    );
    return RoleClaimResult.failed(lastFailure, detail: lastDetail);
  }

  /// Ejecuta la transacción atómica sobre `terminales`.
  ///
  /// Se conserva la transacción del nodo completo porque es la única forma
  /// atómica de detectar que otro terminal ya tiene el rol. Las marcas de la
  /// ejecución (conflicto/revocación) se guardan fuera del handler para poder
  /// distinguir un aborto intencional de un fallo del servidor.
  Future<_ClaimAttempt> _runClaimTransaction(String role) async {
    String? conflictingId;
    String? conflictingName;
    var abort = _ClaimAbort.none;
    final now = DateTime.now().millisecondsSinceEpoch;

    final result = await _terminals.runTransaction((data) {
      conflictingId = null;
      conflictingName = null;
      abort = _ClaimAbort.none;
      final terminals = data is Map
          ? Map<Object?, Object?>.from(data)
          : <Object?, Object?>{};
      final orphanedIds = <Object?>[];
      for (final entry in terminals.entries) {
        if (entry.key.toString() == terminalId || entry.value is! Map) continue;
        final terminal = entry.value as Map;
        if (terminal['rol'] != role || terminal['revocado'] == true) continue;
        final seen = terminal['last_seen'] ?? terminal['ultimo_latido'];
        final stale = seen is num && now - seen.toInt() > 180000;
        final inactive =
            terminal['online'] != true && terminal['sesion_activa'] != true;
        if (stale && inactive) {
          orphanedIds.add(entry.key);
          continue;
        }
        conflictingId = entry.key.toString();
        conflictingName = terminal['nombre']?.toString() ?? 'Teléfono';
        abort = _ClaimAbort.roleBusy;
        return Transaction.abort();
      }
      for (final id in orphanedIds) {
        final orphanRaw = terminals[id];
        if (orphanRaw is! Map) continue;
        final orphan = Map<Object?, Object?>.from(orphanRaw);
        orphan['rol'] = '';
        orphan['online'] = false;
        orphan['sesion_activa'] = false;
        terminals[id] = orphan;
      }
      final currentRaw = terminals[terminalId];
      final current = currentRaw is Map
          ? Map<Object?, Object?>.from(currentRaw)
          : <Object?, Object?>{};
      if (current['revocado'] == true) {
        abort = _ClaimAbort.revoked;
        return Transaction.abort();
      }
      current.addAll({
        'nombre': _deviceName,
        'rol': role,
        'online': true,
        'sesion_activa': true,
        'last_seen': ServerValue.timestamp,
        'ultimo_latido': ServerValue.timestamp,
        'revocado': false,
      });
      terminals[terminalId] = current;
      return Transaction.success(terminals);
    });

    return _ClaimAttempt(
      committed: result.committed,
      conflictingId: conflictingId,
      conflictingName: conflictingName,
      abort: abort,
    );
  }

  /// Registra `onDisconnect` con un límite propio.
  ///
  /// El rol ya está confirmado cuando se llama: si la escritura de presencia
  /// tarda o falla, se registra el problema pero la reserva se mantiene.
  Future<void> _configureDisconnectPresence(Duration timeout) async {
    try {
      await _current
          .onDisconnect()
          .update({
            'online': false,
            'sesion_activa': false,
            'last_seen': ServerValue.timestamp,
            'ultimo_latido': ServerValue.timestamp,
          })
          .timeout(timeout);
    } on TimeoutException {
      AppLogger.warn(
        LogTags.firebase,
        '[TERMINAL] Rol confirmado, pero onDisconnect no respondió en '
        '${timeout.inSeconds} s; la presencia se corregirá al cerrar sesión.',
      );
    } catch (error) {
      AppLogger.warn(
        LogTags.firebase,
        '[TERMINAL] Rol confirmado, pero no se pudo registrar onDisconnect: '
        '$error.',
      );
    }
  }

  /// Espera una sesión válida de Firebase Auth y calienta el token en caché.
  Future<bool> _waitForAuthentication(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final user = _currentUser();
      if (user != null) {
        if (user.uid != uid) {
          AppLogger.error(
            LogTags.firebase,
            '[TERMINAL] La sesión activa (uid=${user.uid}) no coincide con '
            'usuarios/$uid; las reglas de RTDB rechazarán la reserva.',
          );
          return false;
        }
        final remaining = deadline.difference(DateTime.now());
        if (remaining > Duration.zero) {
          try {
            await user.getIdToken().timeout(remaining);
          } catch (error) {
            AppLogger.warn(
              LogTags.firebase,
              '[TERMINAL] No se pudo refrescar el token de Auth ($error); se '
              'intentará la transacción con el token en caché.',
            );
          }
        }
        return true;
      }
      if (!DateTime.now().isBefore(deadline)) {
        AppLogger.error(
          LogTags.firebase,
          '[TERMINAL] Sin sesión de Firebase Auth tras '
          '${timeout.inSeconds} s; no se puede escribir en '
          'usuarios/$uid/terminales.',
        );
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  User? _currentUser() {
    try {
      final injected = auth;
      if (injected != null) return injected.currentUser;
      return AppInitializer.safeCurrentUser();
    } catch (_) {
      return null;
    }
  }

  Future<void> heartbeat() => _current.update({
    'online': true,
    'sesion_activa': true,
    'last_seen': ServerValue.timestamp,
    'ultimo_latido': ServerValue.timestamp,
  });

  Future<void> releaseRole() async {
    final snapshot = await _current.get();
    final wasBridge = snapshot.child('rol').value == 'puente';
    final updates = <String, Object?>{
      'usuarios/$uid/terminales/$terminalId/rol': '',
      'usuarios/$uid/terminales/$terminalId/online': false,
      'usuarios/$uid/terminales/$terminalId/sesion_activa': false,
      'usuarios/$uid/terminales/$terminalId/last_seen': ServerValue.timestamp,
      'usuarios/$uid/terminales/$terminalId/ultimo_latido':
          ServerValue.timestamp,
    };
    if (wasBridge) {
      updates['usuarios/$uid/${AppConstants.firebaseDevicePath}/estado/puente_en_linea'] =
          false;
    }
    await _db.ref().update(updates);
    await _current.onDisconnect().cancel();
    AppLogger.info(LogTags.firebase, '[TERMINAL] Rol liberado.');
  }

  Future<void> setOffline() => _current.update({
    'online': false,
    'sesion_activa': false,
    'last_seen': ServerValue.timestamp,
    'ultimo_latido': ServerValue.timestamp,
  });

  Future<void> removeTerminal(String id) async {
    final target = _terminals.child(id);
    final snapshot = await target.get();
    final wasBridge = snapshot.child('rol').value == 'puente';
    final updates = <String, Object?>{'usuarios/$uid/terminales/$id': null};
    if (wasBridge) {
      updates['usuarios/$uid/${AppConstants.firebaseDevicePath}/estado/puente_en_linea'] =
          false;
    }
    await _db.ref().update(updates);
  }

  Future<void> cancelDisconnectPresence() async {
    await _current.onDisconnect().cancel();
    await _db
        .ref(
          'usuarios/$uid/${AppConstants.firebaseDevicePath}/estado/puente_en_linea',
        )
        .onDisconnect()
        .cancel();
  }

  Future<String> _readDeviceName() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final info = await _deviceInfo.androidInfo.timeout(
          const Duration(seconds: 3),
        );
        final manufacturer = info.manufacturer.trim();
        final model = info.model.trim();
        if (manufacturer.isEmpty ||
            model.toLowerCase().startsWith(manufacturer.toLowerCase())) {
          return model.isEmpty ? 'Teléfono Android' : model;
        }
        return '$manufacturer $model';
      }
      final info = await _deviceInfo.deviceInfo.timeout(
        const Duration(seconds: 3),
      );
      return info.data['model']?.toString() ?? 'Teléfono';
    } on TimeoutException {
      AppLogger.warn(
        LogTags.firebase,
        '[TERMINAL] device_info no respondió en 3 s; se usa un nombre genérico.',
      );
      return 'Teléfono';
    } catch (_) {
      return 'Teléfono';
    }
  }

  /// Traduce errores del SDK a causas que el llamador pueda interpretar.
  RoleClaimFailure _classifyFailure(Object error) {
    if (error is FirebaseException) {
      return switch (error.code) {
        'permission-denied' ||
        'permission_denied' => RoleClaimFailure.permissionDenied,
        'unauthenticated' => RoleClaimFailure.unauthenticated,
        'unavailable' ||
        'network-request-failed' ||
        'disconnected' => RoleClaimFailure.offline,
        'timeout' || 'deadline-exceeded' => RoleClaimFailure.timeout,
        _ => _classifyMessage(error.message ?? ''),
      };
    }
    return _classifyMessage(error.toString());
  }

  RoleClaimFailure _classifyMessage(String message) {
    final text = message.toLowerCase();
    if (text.contains('permission') || text.contains('denied')) {
      return RoleClaimFailure.permissionDenied;
    }
    if (text.contains('timeout') || text.contains('timed out')) {
      return RoleClaimFailure.timeout;
    }
    if (text.contains('network') ||
        text.contains('offline') ||
        text.contains('disconnect') ||
        text.contains('unavailable')) {
      return RoleClaimFailure.offline;
    }
    return RoleClaimFailure.unknown;
  }
}

enum _ClaimAbort { none, roleBusy, revoked }

class _ClaimAttempt {
  const _ClaimAttempt({
    required this.committed,
    this.conflictingId,
    this.conflictingName,
    this.abort = _ClaimAbort.none,
  });

  final bool committed;
  final String? conflictingId;
  final String? conflictingName;
  final _ClaimAbort abort;

  bool get revoked => abort == _ClaimAbort.revoked;
}
