import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/history_event.dart';
import '../models/operation_result.dart';
import '../models/remote_device_state.dart';
import '../services/app_initializer.dart';
import '../services/app_logger.dart';
import '../services/firebase_service.dart';
import '../services/notification_service.dart';

class MonitorController extends ChangeNotifier {
  MonitorController({
    required FirebaseService firebaseService,
    required NotificationService notificationService,
  }) : _firebase = firebaseService,
       _notifications = notificationService;

  final FirebaseService _firebase;
  final NotificationService _notifications;
  StreamSubscription<List<HistoryEvent>>? _historySubscription;
  Timer? _freshnessTimer;

  RemoteDeviceState _state = const RemoteDeviceState.initial();
  List<HistoryEvent> _history = const [];
  bool _loading = true;
  bool _busy = false;
  bool _disposed = false;
  bool _baseDisposed = false;
  bool _remoteOffPending = false;
  bool? _lastAlarmState;
  String? _error;

  /// Actualiza el estado remoto notificado por el servicio en segundo plano.
  void setRemoteState(RemoteDeviceState next) {
    if (_lastAlarmState != next.alarmActive) {
      _lastAlarmState = next.alarmActive;
      final message =
          'Cambio de alarma remota desde el isolate: ${next.alarmActive}.';
      if (next.alarmActive) {
        AppLogger.warn(LogTags.firebase, message);
      } else {
        AppLogger.info(LogTags.firebase, message);
      }
    }
    if (_remoteOffPending && !next.alarmActive) {
      _remoteOffPending = false;
    }
    final visibleState = _remoteOffPending && next.alarmActive
        ? RemoteDeviceState(
            alarmActive: false,
            bridgeOnline: next.bridgeOnline,
            location: next.location,
            lastHeartbeat: next.lastHeartbeat,
          )
        : next;
    if (_sameState(_state, visibleState)) {
      if (_loading) {
        _loading = false;
        _error = null;
        _notify();
      }
      return;
    }
    _state = visibleState;
    _loading = false;
    _error = null;
    _notify();
  }

  RemoteDeviceState get state => _state;
  List<HistoryEvent> get history => _history;
  bool get loading => _loading;
  bool get busy => _busy;
  String? get error => _error;

  Future<void> initialize() async {
    AppLogger.info(
      LogTags.firebase,
      'Monitor remoto: suscribiéndose al estado y al historial…',
    );
    // El permiso de notificaciones lo solicita `EquilibraApp` antes de abrir el
    // módulo; aquí sólo se preparan los canales para no abrir un diálogo
    // duplicado mientras el sistema ya muestra otro.
    unawaited(_prepareNotifications());
    try {
      await AppInitializer.ensureFirebaseReady();
      await _historySubscription?.cancel();
      _freshnessTimer?.cancel();
      _historySubscription = _firebase.watchHistory().listen((events) {
        _history = events;
        AppLogger.info(
          LogTags.firebase,
          'Historial remoto recibido: ${events.length} eventos.',
        );
        _notify();
      }, onError: _handleError);
      _freshnessTimer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => _notify(),
      );
    } catch (error) {
      _handleError(error);
    }
  }

  /// Prepara los canales de notificación sin solicitar permisos.
  Future<void> _prepareNotifications() async {
    try {
      await _notifications.initialize();
    } catch (error) {
      AppLogger.warn(
        LogTags.notificaciones,
        'No se pudieron preparar los canales de notificación: $error',
      );
    }
  }

  Future<OperationResult> deactivateAlarm() async {
    if (!_state.alarmActive) {
      return const OperationResult.failure('La alarma ya está desactivada.');
    }
    final previousState = _state;
    _busy = true;
    _remoteOffPending = true;
    _state = RemoteDeviceState(
      alarmActive: false,
      bridgeOnline: previousState.bridgeOnline,
      location: previousState.location,
      lastHeartbeat: previousState.lastHeartbeat,
    );
    _notify();
    try {
      AppLogger.warn(
        LogTags.firebase,
        'Solicitando apagado remoto (comandos/off_request)…',
      );
      await _firebase.requestRemoteOff(_state.location);
      AppLogger.ok(LogTags.firebase, 'Orden remota enviada correctamente.');
      return const OperationResult.success('Orden remota enviada.');
    } catch (error, stack) {
      _remoteOffPending = false;
      _state = previousState;
      AppLogger.error(
        LogTags.firebase,
        'No se pudo enviar la orden remota.',
        error,
        stack,
      );
      return const OperationResult.failure('No se pudo enviar la orden.');
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _handleError(Object error) {
    AppLogger.error(
      LogTags.firebase,
      'No se pudo conectar con Firebase Realtime Database.',
      error,
    );
    _loading = false;
    _error = 'No se pudo conectar con Equilibra.';
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Garantiza que `super.dispose()` se ejecute una sola vez, incluso si el
  /// cierre lo inició `disposeAsync()` desde `EquilibraApp`.
  void _disposeBase() {
    if (_baseDisposed) return;
    _baseDisposed = true;
    super.dispose();
  }

  /// Cierra streams y temporizadores antes de descartar el controlador.
  Future<void> disposeAsync() async {
    if (_disposed) return;
    _disposed = true;
    _disposeBase();
    _freshnessTimer?.cancel();
    final history = _historySubscription;
    _historySubscription = null;
    if (history != null) await history.cancel();
  }

  @override
  void dispose() {
    if (_disposed) return;
    unawaited(disposeAsync());
    if (!_baseDisposed) super.dispose();
  }
}

bool _sameState(RemoteDeviceState previous, RemoteDeviceState next) =>
    previous.alarmActive == next.alarmActive &&
    previous.bridgeOnline == next.bridgeOnline &&
    previous.lastHeartbeat == next.lastHeartbeat &&
    previous.location?.latitude == next.location?.latitude &&
    previous.location?.longitude == next.location?.longitude;
