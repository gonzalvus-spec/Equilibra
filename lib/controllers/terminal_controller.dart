import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/app_mode.dart';
import '../models/role_claim_result.dart';
import '../models/terminal_info.dart';
import '../services/app_initializer.dart';
import '../services/app_logger.dart';
import '../services/terminal_service.dart';

class TerminalController extends ChangeNotifier {
  TerminalController(
    this._service, {
    FirebaseAuth? auth,
    this.beforeSignOut,
    this.onCurrentUnlinked,
  }) : _authOverride = auth;

  final TerminalService _service;
  final FirebaseAuth? _authOverride;
  FirebaseAuth? _auth;
  final Future<void> Function()? beforeSignOut;
  final Future<void> Function()? onCurrentUnlinked;
  StreamSubscription<TerminalInfo?>? _currentSubscription;
  StreamSubscription<List<TerminalInfo>>? _allSubscription;
  Timer? _heartbeatTimer;
  List<TerminalInfo> _terminals = const [];
  bool _ready = false;
  bool _disposed = false;
  bool _signingOut = false;
  bool _hasClaimedRole = false;
  bool _handlingUnlink = false;
  AppMode? _mode;

  List<TerminalInfo> get terminals => _terminals;
  String get terminalId => _service.terminalIdOrNull ?? '';

  /// `null` mientras la inicialización local del terminal no terminó.
  ///
  /// La pantalla de selección se pinta antes de que Firebase responda, así que
  /// nunca se debe forzar el identificador en ese momento.
  String? get terminalIdOrNull => _service.terminalIdOrNull;
  bool get ready => _ready;

  /// `true` cuando este equipo ya reservó con éxito su rol en Firebase.
  bool get hasClaimedRole => _hasClaimedRole;

  TerminalInfo get currentTerminal =>
      _terminals.where((item) => item.id == terminalId).firstOrNull ??
      TerminalInfo(
        id: terminalId,
        name: _service.deviceName,
        role: _mode == AppMode.bridge ? 'puente' : 'monitor',
        online: true,
        revoked: false,
      );

  Future<void> initialize(AppMode? mode) async {
    // Authentication y Realtime Database se usan justo después: si Core no
    // está listo se lanza un error de dominio que el llamador ya registra y
    // absorbe, en lugar de fallar con un `Firebase.app()` sin inicializar.
    await AppInitializer.requireFirebaseReady();
    _auth ??= _authOverride ?? FirebaseAuth.instance;

    final user = _safeCurrentUser();
    if (user == null) {
      AppLogger.warn(
        LogTags.firebase,
        '[TERMINAL] Sin sesión de Firebase Auth activa; la presencia remota '
        'no se sincronizará hasta restaurarla.',
      );
    } else if (user.uid != _service.uid) {
      AppLogger.error(
        LogTags.firebase,
        '[TERMINAL] La sesión activa (uid=${user.uid}) no coincide con '
        'usuarios/${_service.uid}; Realtime Database rechazará las escrituras.',
      );
    }

    await _service.initialize();
    _currentSubscription = _service.watchCurrent().listen(
      (terminal) {
        if (terminal?.revoked == true) {
          unawaited(signOut());
        } else if (terminal == null && _hasClaimedRole && !_handlingUnlink) {
          _handlingUnlink = true;
          _hasClaimedRole = false;
          _heartbeatTimer?.cancel();
          _heartbeatTimer = null;
          AppLogger.warn(
            LogTags.firebase,
            '[TERMINAL] Desvinculación remota detectada.',
          );
          unawaited(_handleCurrentUnlinked());
        }
      },
      onError: (Object error) {
        // Un error de reglas no debe cerrar la sesión ni congelar la UI, pero
        // sí debe quedar en el historial para diagnosticar el dispositivo.
        AppLogger.warn(
          LogTags.firebase,
          '[TERMINAL] Error escuchando el terminal actual: $error.',
        );
      },
    );
    _allSubscription = _service.watchAll().listen(
      (terminals) {
        _terminals = terminals;
        _notify();
      },
      onError: (Object error) {
        // La lista simplemente se queda vacía hasta recuperar la conexión.
        AppLogger.warn(
          LogTags.firebase,
          '[TERMINAL] Error escuchando la lista de terminales: $error.',
        );
      },
    );
    if (mode != null) {
      final result = await setRole(mode);
      if (result.occupied || result.revoked) {
        AppLogger.warn(
          LogTags.firebase,
          '[TERMINAL] No se puede abrir ${mode.label}: '
          '${result.occupied ? 'el rol ya está asignado' : 'terminal revocado'}.',
        );
        await signOut();
        return;
      }
      if (result.failed) {
        // Un fallo de red no invalida la sesión: el módulo reintentará la
        // reserva sin sacar al usuario de la app.
        AppLogger.warn(
          LogTags.firebase,
          '[TERMINAL] Reserva del rol ${mode.label} sin confirmar '
          '(${result.failureLabel}); se mantiene la sesión.',
        );
      }
    }
    _ready = true;
    _notify();
  }

  Future<RoleClaimResult> setRole(AppMode mode) async {
    final result = await _service.claimRole(mode);
    if (result.claimed) {
      _mode = mode;
      _hasClaimedRole = true;
      _handlingUnlink = false;
      _ensureHeartbeat();
      _notify();
    }
    return result;
  }

  Future<void> remove(String id) => _service.removeTerminal(id);

  Future<void> _handleCurrentUnlinked() async {
    try {
      await _service.cancelDisconnectPresence();
    } catch (_) {
      // El nodo ya fue eliminado; el cierre local debe continuar.
    }
    await onCurrentUnlinked?.call();
  }

  Future<void> releaseRoleSafely() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _mode = null;
    _hasClaimedRole = false;
    try {
      await _service.releaseRole().timeout(const Duration(seconds: 3));
    } catch (_) {
      // Un cierre local no debe quedar bloqueado si no hay red.
    }
    _notify();
  }

  /// Marca el terminal como desconectado con un límite de tiempo corto.
  Future<void> setOfflineSafely() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    try {
      await _service.setOffline().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Nunca bloquea el cierre de sesión si no hay internet.
    }
  }

  Future<void> signOut() async {
    if (_signingOut) return;
    _signingOut = true;
    await beforeSignOut?.call();
    await setOfflineSafely();
    try {
      await (_auth ?? _authOverride ?? FirebaseAuth.instance).signOut();
    } catch (_) {
      // La navegación llevará a AuthScreen de todos modos.
    }
  }

  void _ensureHeartbeat() {
    _heartbeatTimer ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_sendHeartbeat()),
    );
  }

  /// Latido con diagnóstico propio: un corte de red no debe generar un error
  /// no capturado cada 30 s ni detener el temporizador.
  Future<void> _sendHeartbeat() async {
    try {
      await _service.heartbeat().timeout(const Duration(seconds: 10));
    } on TimeoutException {
      AppLogger.warn(
        LogTags.firebase,
        '[TERMINAL] Latido de $terminalId sin confirmación en 10 s.',
      );
    } catch (error) {
      AppLogger.warn(
        LogTags.firebase,
        '[TERMINAL] Latido de $terminalId no confirmado: $error',
      );
    }
  }

  /// Usuario de la sesión, sin lanzar si Firebase aún no está disponible.
  User? _safeCurrentUser() {
    try {
      return _auth?.currentUser;
    } catch (_) {
      return null;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _heartbeatTimer?.cancel();
    unawaited(_currentSubscription?.cancel());
    unawaited(_allSubscription?.cancel());
    super.dispose();
  }
}
