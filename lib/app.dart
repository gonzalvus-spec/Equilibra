import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'controllers/bridge_controller.dart';
import 'controllers/monitor_controller.dart';
import 'controllers/terminal_controller.dart';
import 'core/app_constants.dart';
import 'core/background_keys.dart';
import 'core/app_theme.dart';
import 'models/app_mode.dart';
import 'models/geo_point.dart';
import 'models/log_entry.dart';
import 'models/remote_device_state.dart';
import 'models/role_claim_result.dart';
import 'screens/bridge_screen.dart';
import 'screens/linked_devices_sheet.dart';
import 'screens/mode_selection_screen.dart';
import 'screens/monitor_screen.dart';
import 'services/app_permissions.dart';
import 'services/app_initializer.dart';
import 'services/app_logger.dart';
import 'services/background_service.dart';
import 'services/bluetooth_preferences.dart';
import 'services/firebase_service.dart';
import 'services/mode_preferences.dart';
import 'services/notification_service.dart';
import 'services/role_claim_policy.dart';
import 'services/terminal_service.dart';

class EquilibraApp extends StatefulWidget {
  const EquilibraApp({
    super.key,
    required this.uid,
    this.email,
    required this.initialMode,
    required this.notificationService,
    this.backgroundService,
    this.preferences,
    this.firebaseService,
    this.modePreferences,
    this.terminalService,
    this.auth,
  });

  final String uid;
  final String? email;
  final AppMode? initialMode;
  final NotificationService notificationService;
  final BackgroundService? backgroundService;
  final SharedPreferences? preferences;
  final FirebaseService? firebaseService;
  final ModePreferences? modePreferences;
  final TerminalService? terminalService;
  final FirebaseAuth? auth;

  @override
  State<EquilibraApp> createState() => _EquilibraAppState();
}

class _EquilibraAppState extends State<EquilibraApp>
    with WidgetsBindingObserver {
  AppMode? _mode;
  late final FirebaseService _firebase =
      widget.firebaseService ?? FirebaseService(uid: widget.uid);
  late final ModePreferences _preferences =
      widget.modePreferences ?? ModePreferences(widget.preferences);
  late final BackgroundService _background =
      widget.backgroundService ?? BackgroundService();
  late final TerminalController _terminals = TerminalController(
    widget.terminalService ??
        TerminalService(uid: widget.uid, auth: widget.auth),
    beforeSignOut: _stopBackgroundServices,
    onCurrentUnlinked: _handleRemoteUnlinked,
  );
  late final Future<void> _terminalInitialization;
  BridgeController? _bridgeController;
  MonitorController? _monitorController;
  StreamSubscription<Map<String, dynamic>?>? _backgroundAlarm;
  StreamSubscription<Map<String, dynamic>?>? _backgroundState;
  StreamSubscription<Map<String, dynamic>?>? _backgroundLog;
  bool? _lastAlarmState;
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  BuildContext? _devicesSheetContext;

  /// Modo tocado mientras se pinta el indicador de carga de la selección.
  AppMode? _pendingMode;

  /// `true` mientras se valida el modo guardado antes del primer frame útil.
  ///
  /// Sin esta bandera la pantalla de selección se mostraba durante el viaje de
  /// ida y vuelta a Firebase y, al terminar, saltaba al módulo guardado: la
  /// "doble carga" de las dos opciones al reabrir la app.
  bool _restoringMode = false;

  /// Invalida tareas de preparación en segundo plano si el usuario cambia de
  /// modo o cierra sesión antes de que terminen.
  int _modeSession = 0;

  /// Reabre el modo guardado en `shared_preferences` sin pintar antes la
  /// pantalla de selección.
  Future<void> _restoreMode(AppMode mode) async {
    final session = ++_modeSession;
    bool stillActive() => mounted && _modeSession == session && _mode == null;

    AppLogger.info(
      LogTags.modo,
      'Reabriendo ${mode.label} guardado; validando rol y permisos…',
    );

    try {
      await AppInitializer.ensureFirebaseReady();
      if (!stillActive()) return;

      final claim = await _claimRole(mode);
      if (!stillActive()) return;

      if (!claim.claimed && !claim.failed) {
        // El rol lo ocupa otro teléfono o este terminal fue revocado: es un
        // resultado definitivo, no un problema de red.
        await _preferences.clear();
        if (!mounted) return;
        setState(() => _restoringMode = false);
        await _showRoleBlocked(mode, claim);
        return;
      }
      if (claim.failed) {
        AppLogger.warn(
          LogTags.firebase,
          'No se pudo verificar el rol al reabrir (${claim.failureLabel}); se '
          'continúa en ${mode.label} y se reintentará al preparar el módulo.',
        );
      } else {
        await _persistMode(mode);
      }
      if (!stillActive()) return;

      // Los permisos se resuelven antes de construir la pantalla: el módulo
      // toca el adaptador Bluetooth al montarse y no puede hacerlo mientras el
      // sistema muestra otro diálogo.
      await _requestModePermissions(mode);
      if (!stillActive()) return;

      setState(() {
        _mode = mode;
        _restoringMode = false;
      });
      unawaited(_prepareMode(mode, session));
    } catch (error, stack) {
      AppLogger.error(
        LogTags.modo,
        'Fallo al reabrir el modo guardado; se muestra la selección.',
        error,
        stack,
      );
      if (!mounted) return;
      setState(() => _restoringMode = false);
    }
  }

  /// Reserva el rol con una campaña acotada de reintentos y backoff.
  ///
  /// La política vive en [RoleClaimPolicy]: cada intento tiene su límite y la
  /// transacción falla rápido si Realtime Database no está conectada, en lugar
  /// de esperar a un corte ciego de 10 s. [RoleClaimPolicy.totalBudget] es la
  /// única envolvente que se aplica aquí como red de seguridad.
  Future<RoleClaimResult> _claimRole(AppMode mode) async {
    final stopwatch = Stopwatch()..start();
    final policy = RoleClaimPolicy.standard;
    AppLogger.info(
      LogTags.firebase,
      'Reserva de rol ${mode.label}: terminal='
      '${_terminals.terminalIdOrNull ?? 'pendiente'}, '
      'FirebaseCore=${AppInitializer.isReady ? 'listo' : 'no listo'}, '
      'usuario=${_sessionUser()?.uid ?? 'sin sesión'}.',
    );

    // Nunca se toca RTDB antes de que Core y la sesión estén disponibles.
    try {
      await AppInitializer.requireFirebaseReady();
    } on FirebaseInitializationException catch (error) {
      AppLogger.error(
        LogTags.firebase,
        'Firebase Core no está listo para reservar el rol de ${mode.label}: '
        '${error.message}',
      );
      return const RoleClaimResult.failed(
        RoleClaimFailure.offline,
        detail: 'Firebase Core no inicializado',
      );
    } catch (error, stack) {
      AppLogger.error(
        LogTags.firebase,
        'Fallo al preparar Firebase para reservar el rol de ${mode.label}.',
        error,
        stack,
      );
      return const RoleClaimResult.failed(RoleClaimFailure.unknown);
    }

    final user = _sessionUser();
    if (user == null) {
      AppLogger.error(
        LogTags.firebase,
        'Sin sesión de Firebase Auth al reservar el rol de ${mode.label}; '
        'las reglas de RTDB no autorizarían la escritura.',
      );
      return const RoleClaimResult.failed(RoleClaimFailure.unauthenticated);
    }
    if (user.uid != widget.uid) {
      AppLogger.error(
        LogTags.firebase,
        'La sesión activa (uid=${user.uid}) no coincide con el usuario de la '
        'app (uid=${widget.uid}) al reservar el rol de ${mode.label}.',
      );
      return const RoleClaimResult.failed(
        RoleClaimFailure.unauthenticated,
        detail: 'uid de la sesión distinto al de la app',
      );
    }

    try {
      final result = await _terminals.setRole(mode).timeout(policy.totalBudget);
      AppLogger.info(
        LogTags.firebase,
        'Reserva de rol ${mode.label} para '
        '${_terminals.terminalIdOrNull ?? 'terminal pendiente'}: '
        '${result.claimed ? 'confirmada' : result.failureLabel} en '
        '${stopwatch.elapsedMilliseconds} ms.',
      );
      return result;
    } on TimeoutException {
      AppLogger.error(
        LogTags.firebase,
        'Timeout global de ${policy.totalBudget.inSeconds} s al reservar el '
        'rol de ${mode.label} para ${_terminals.terminalIdOrNull ?? 'terminal'}; '
        'el servidor no confirmó la transacción.',
      );
      return const RoleClaimResult.failed(
        RoleClaimFailure.timeout,
        detail: 'envolvente global de la campaña agotada',
      );
    } catch (error, stack) {
      AppLogger.error(
        LogTags.firebase,
        'No se pudo reservar el rol de ${mode.label} para '
        '${_terminals.terminalIdOrNull ?? 'terminal'}.',
        error,
        stack,
      );
      return const RoleClaimResult.failed(RoleClaimFailure.unknown);
    }
  }

  /// Usuario de la sesión activa, tolerante a Firebase aún no inicializado.
  ///
  /// Se prefiere el [FirebaseAuth] inyectado para que las pruebas y los
  /// overrides de sesión no dependan de la instancia global.
  User? _sessionUser() {
    try {
      return widget.auth?.currentUser ?? AppInitializer.safeCurrentUser();
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _terminalInitialization = _initializeTerminal();
    if (widget.initialMode case final initialMode?) {
      // El modo ya se leyó de `shared_preferences` antes de construir este
      // widget: se resuelve una sola vez y se pinta un arranque neutro hasta
      // conocer el resultado, en lugar de mostrar la selección y saltar.
      _restoringMode = true;
      // Tras el primer frame la actividad ya está enfocada, que es lo que el
      // sistema exige para mostrar diálogos de permisos.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_restoreMode(initialMode));
      });
    }
    _backgroundAlarm = _background
        .on(BackgroundKeys.alarm)
        .listen((_) => _handleBackgroundAlarm());
    _backgroundState = _background.on(BackgroundKeys.state).listen((event) {
      final active = event?['active'] as bool?;
      if (active == null) return;
      if (_lastAlarmState != active) {
        _lastAlarmState = active;
        final message =
            'Cambio de alarma_activa desde el servicio en segundo plano: '
            '$active.';
        if (active) {
          AppLogger.warn(LogTags.firebase, message);
        } else {
          AppLogger.info(LogTags.firebase, message);
        }
      }
      if (_mode == AppMode.monitor) {
        final latitude = event?['latitude'] as num?;
        final longitude = event?['longitude'] as num?;
        final heartbeat = event?['last_heartbeat'] as num?;
        _getMonitorController().setRemoteState(
          RemoteDeviceState(
            alarmActive: active,
            bridgeOnline: event?['bridge_online'] == true,
            lastHeartbeat: heartbeat == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(heartbeat.toInt()),
            location: latitude == null || longitude == null
                ? null
                : GeoPoint(
                    latitude: latitude.toDouble(),
                    longitude: longitude.toDouble(),
                  ),
          ),
        );
      }
    });
    _backgroundLog = _background
        .on(BackgroundKeys.log)
        .listen(_handleIsolateLog);
  }

  /// Reenvía al historial principal los registros producidos en el isolate.
  void _handleIsolateLog(Map<String, dynamic>? event) {
    if (event == null) return;
    final level = switch (event[BackgroundKeys.logLevel] as String?) {
      'OK' => LogLevel.ok,
      'WARN' => LogLevel.warn,
      'ERROR' => LogLevel.error,
      _ => LogLevel.info,
    };
    final tag = event[BackgroundKeys.logTag] as String? ?? LogTags.bgService;
    final message =
        event[BackgroundKeys.logMessage] as String? ?? 'Evento del servicio.';
    final error = event[BackgroundKeys.logError] as String?;
    AppLogger.instance.addFromIsolate(level, tag, message, error);
  }

  void _handleBackgroundAlarm() {
    AppLogger.warn(
      LogTags.bgService,
      'Alarma recibida desde el isolate del servicio en primer plano.',
    );
    if (_mode == AppMode.bridge) {
      _getBridgeController().markAlarmActivated();
    } else if (_mode == AppMode.monitor) {
      // El evento `state` es la única fuente de verdad del monitor. `alarm`
      // sólo conserva compatibilidad con avisos del puente.
    }
  }

  Future<void> _initializeTerminal() async {
    AppLogger.info(
      LogTags.firebase,
      'Registrando/verificando terminal en usuarios/{uid}/terminales/'
      '{terminalId}.',
    );
    try {
      await _terminals.initialize(null).timeout(const Duration(seconds: 15));
      AppLogger.ok(LogTags.firebase, 'Terminal registrado/verificado.');
    } on TimeoutException {
      AppLogger.warn(
        LogTags.firebase,
        'Timeout (15 s) al registrar/verificar el terminal; la reserva de rol '
        'se autoinicializa cuando el usuario elige un modo.',
      );
      // Firebase puede estar lento o las reglas pueden denegar la lectura;
      // la interfaz debe seguir disponible.
      return;
    } catch (error, stack) {
      AppLogger.error(
        LogTags.firebase,
        'Fallo al registrar/verificar el terminal.',
        error,
        stack,
      );
      return;
    }
  }

  Future<void> _showRoleBlocked(AppMode mode, RoleClaimResult result) async {
    if (!mounted) return;
    final roleName = mode == AppMode.bridge
        ? 'Estación Base'
        : 'Monitor Remoto';
    final name = result.conflictingDeviceName ?? 'otro teléfono';
    final revoked = result.revoked;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(revoked ? 'Dispositivo desvinculado' : '$roleName ocupado'),
        content: Text(
          revoked
              ? 'Este equipo ya no está vinculado a la cuenta. Vuelve a '
                    'iniciar sesión o pide acceso desde la cuenta principal.'
              : 'Ya hay un dispositivo vinculado como $roleName ($name). '
                    'Elimínalo desde la lista de Dispositivos vinculados antes '
                    'de asignar este equipo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _showDevices();
            },
            child: const Text('Administrar dispositivos'),
          ),
        ],
      ),
    );
  }

  /// Mensaje para un fallo de red/timeout (nunca para "rol ocupado").
  String _claimFailureMessage(RoleClaimResult result) =>
      switch (result.failure) {
        RoleClaimFailure.offline =>
          'Sin conexión con Firebase. Revisa tu internet e inténtalo de nuevo.',
        RoleClaimFailure.unauthenticated =>
          'Tu sesión de Firebase no está lista. Vuelve a iniciar sesión.',
        RoleClaimFailure.timeout =>
          'Firebase tardó demasiado en confirmar el rol. Reintenta en unos '
              'segundos.',
        RoleClaimFailure.permissionDenied =>
          'La base de datos rechazó la reserva del rol. Revisa las reglas de '
              'seguridad.',
        _ => 'No se pudo verificar el cupo. Inténtalo nuevamente.',
      };

  Future<void> _selectMode(AppMode mode) async {
    if (_mode != null || _pendingMode != null || _restoringMode) return;

    AppLogger.info(
      LogTags.modo,
      'Modo ${mode.label} seleccionado; preparando permisos y servicio.',
    );

    // 1) Feedback inmediato: la tarjeta elegida muestra un indicador breve.
    setState(() => _pendingMode = mode);

    try {
      final claim = await _claimRole(mode);
      if (!mounted) return;
      if (!claim.claimed) {
        setState(() => _pendingMode = null);
        if (claim.occupied || claim.revoked) {
          await _showRoleBlocked(mode, claim);
        } else {
          _showMessage(_claimFailureMessage(claim));
        }
        return;
      }
      final session = ++_modeSession;
      // Los diálogos de permisos se muestran sobre la selección de modo, antes
      // de montar la pantalla del módulo (que consulta Bluetooth al iniciar).
      await _requestModePermissions(mode);
      if (!mounted) return;
      setState(() {
        _bridgeController = null;
        _monitorController = null;
        _mode = mode;
        _pendingMode = null;
      });
      unawaited(_persistMode(mode));
      unawaited(_prepareMode(mode, session));
    } catch (error, stack) {
      AppLogger.error(
        LogTags.modo,
        'No se pudo abrir ${mode.label}.',
        error,
        stack,
      );
      if (mounted) {
        setState(() => _pendingMode = null);
        _showMessage('No se pudo verificar el cupo. Inténtalo nuevamente.');
      }
    }
  }

  Future<void> _persistMode(AppMode mode) async {
    try {
      await _preferences.save(mode).timeout(const Duration(seconds: 2));
    } catch (_) {
      // La selección ya está aplicada; la preferencia sólo se usa al reabrir.
    }
  }

  /// Pide los permisos que necesita [mode] **antes** de montar su pantalla.
  ///
  /// Nunca lanza: un permiso denegado o un diálogo bloqueado sólo produce un
  /// aviso, nunca impide entrar al módulo.
  Future<PermissionReport> _requestModePermissions(AppMode mode) async {
    final needsBluetooth = mode == AppMode.bridge;
    AppLogger.info(
      LogTags.permisos,
      'Solicitando permisos para ${mode.label} '
      '(ubicación y Bluetooth: $needsBluetooth)…',
    );
    final report = await const AppPermissions().requestAll(
      location: needsBluetooth,
      bluetooth: needsBluetooth,
    );
    if (report.granted) {
      AppLogger.ok(LogTags.permisos, 'Todos los permisos concedidos.');
    } else {
      AppLogger.warn(
        LogTags.permisos,
        report.message ?? 'No se pudieron verificar los permisos del sistema.',
      );
      _showMessage(
        report.message ?? 'No se pudieron verificar los permisos del sistema.',
      );
    }
    return report;
  }

  /// Prepara el terminal y el servicio en segundo plano.
  ///
  /// Cualquier fallo se informa con un aviso, pero nunca saca al usuario del
  /// módulo que ya está viendo.
  Future<void> _prepareMode(AppMode mode, int session) async {
    bool stillActive() => mounted && _mode == mode && _modeSession == session;

    await AppInitializer.ensureFirebaseReady();
    if (!stillActive()) return;

    // Al reabrir, la reserva del rol puede haber fallado por falta de red.
    // Se reintenta aquí, ya con el módulo visible.
    if (!_terminals.hasClaimedRole) {
      final retry = await _claimRole(mode);
      if (!stillActive()) return;
      if (!retry.claimed) {
        if (!retry.failed) {
          // Otro equipo tomó el rol mientras se abría la app, o este terminal
          // fue revocado: es definitivo, no un fallo de red.
          await _preferences.clear();
          if (!mounted) return;
          setState(() {
            _mode = null;
            _pendingMode = null;
          });
          await _showRoleBlocked(mode, retry);
          return;
        }
        AppLogger.warn(
          LogTags.firebase,
          'El rol sigue sin verificarse (${retry.failureLabel}); el módulo '
          'local continúa activo.',
        );
      } else {
        unawaited(_persistMode(mode));
      }
    }

    try {
      await _terminalInitialization.timeout(const Duration(seconds: 6));
      AppLogger.ok(LogTags.firebase, 'Terminal listo para ${mode.label}.');
    } on TimeoutException {
      AppLogger.error(
        LogTags.firebase,
        'Timeout (6 s) esperando la inicialización del terminal.',
      );
    } catch (error, stack) {
      AppLogger.error(
        LogTags.firebase,
        'Fallo en la inicialización del terminal; la pantalla sigue activa.',
        error,
        stack,
      );
    }
    if (!stillActive()) return;

    AppLogger.info(
      LogTags.bgService,
      'Configurando e iniciando el servicio en primer plano (${mode.label})…',
    );
    try {
      // Android/MagicOS pueden restringir el servicio en primer plano: el
      // módulo ya está abierto y debe seguir siendo usable.
      await _background
          .start(mode, terminalId: _terminals.terminalIdOrNull)
          .timeout(const Duration(seconds: 8));
      AppLogger.ok(LogTags.bgService, 'Servicio en primer plano iniciado.');
    } on TimeoutException {
      AppLogger.error(
        LogTags.bgService,
        'Timeout (8 s) al iniciar el servicio en primer plano.',
      );
    } catch (error, stack) {
      AppLogger.error(
        LogTags.bgService,
        'No se pudo iniciar el servicio en primer plano.',
        error,
        stack,
      );
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    _messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _changeMode() async {
    final previousMode = _mode;
    _modeSession++;
    _background.notifyBridgeDisconnected();
    await _background.stop();
    await _stopControllers();
    await _terminals.releaseRoleSafely();
    await _preferences.clear();
    if (previousMode == AppMode.bridge) {
      await BluetoothPreferences().clearAddress();
    }
    _lastAlarmState = null;
    if (mounted) {
      setState(() {
        _mode = null;
        _pendingMode = null;
      });
    }
  }

  Future<void> _handleRemoteUnlinked() async {
    AppLogger.warn(
      LogTags.firebase,
      '[TERMINAL] Este dispositivo fue desvinculado.',
    );
    _modeSession++;
    _background.notifyBridgeDisconnected();
    await _background.stop();
    await _stopControllers();
    await _preferences.clear();
    if (!mounted) return;
    final sheetContext = _devicesSheetContext;
    if (sheetContext != null && sheetContext.mounted) {
      Navigator.of(sheetContext).pop();
    }
    setState(() {
      _mode = null;
      _pendingMode = null;
    });
    _showMessage('Este dispositivo fue desvinculado');
  }

  Future<void> _stopControllers() async {
    final bridge = _bridgeController;
    final monitor = _monitorController;
    _bridgeController = null;
    _monitorController = null;
    final bridgeFuture = bridge == null
        ? Future<void>.value()
        : _disposeBridge(bridge);
    final monitorFuture = monitor == null
        ? Future<void>.value()
        : monitor.disposeAsync();
    await Future.wait([bridgeFuture, monitorFuture]);
  }

  Future<void> _disposeBridge(BridgeController bridge) async {
    try {
      await bridge.prepareForSignOut();
    } catch (_) {
      // El cierre continúa aunque la red o Bluetooth no respondan.
    }
    bridge.dispose();
    await BluetoothPreferences().clearAddress();
  }

  Future<void> _stopBackgroundServices({bool clearMode = false}) async {
    _modeSession++;
    AppLogger.info(
      LogTags.bgService,
      'Cierre de sesión: deteniendo el servicio en primer plano…',
    );
    await _background.stop();
    AppLogger.info(
      LogTags.bluetooth,
      'Cierre de sesión: desconectando Bluetooth y cerrando controladores…',
    );
    await _stopControllers();
    if (clearMode) await _preferences.clear();
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cerrar sesión'),
        content: const Text(
          'Se detendrá la supervisión en segundo plano y se cerrará la sesión en este equipo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cerrar sesión'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    AppLogger.info(LogTags.auth, 'Cierre de sesión confirmado por el usuario.');
    await _terminalInitialization;
    try {
      await _preferences.saveHasActiveSession(false);
    } catch (_) {
      // El almacenamiento local nunca debe impedir un cierre solicitado.
    }
    await _stopBackgroundServices();
    AppLogger.info(
      LogTags.firebase,
      'Cierre de sesión: publicando online: false en el terminal…',
    );
    await _terminals.releaseRoleSafely();
    await _preferences.clear();
    AppLogger.info(
      LogTags.auth,
      'Cierre de sesión: llamando a signOut() de Firebase Auth…',
    );
    try {
      await (widget.auth ?? FirebaseAuth.instance).signOut();
      AppLogger.ok(LogTags.auth, 'Sesión cerrada correctamente.');
    } catch (error, stack) {
      AppLogger.error(
        LogTags.auth,
        'Fallo al cerrar la sesión; la UI volverá a AuthScreen de todos modos.',
        error,
        stack,
      );
    }
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _showDevices() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (context) {
        _devicesSheetContext = context;
        return LinkedDevicesSheet(
          controller: _terminals,
          onSignOut: _confirmSignOut,
        );
      },
    ).whenComplete(() => _devicesSheetContext = null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.detached) return;
    _background.notifyBridgeDisconnected();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_backgroundAlarm?.cancel());
    unawaited(_backgroundState?.cancel());
    unawaited(_backgroundLog?.cancel());
    unawaited(_stopControllers());
    _terminals.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      scaffoldMessengerKey: _messengerKey,
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: _buildHome(),
      ),
    );
  }

  /// Resuelve la pantalla raíz sin mostrar la selección de modo cuando ya hay
  /// un modo guardado pendiente de validar.
  Widget _buildHome() {
    if (_restoringMode) {
      return const _RestoringModeScreen(key: ValueKey('restoring-mode'));
    }
    return switch (_mode) {
      null => ModeSelectionScreen(
        key: const ValueKey('mode-selection'),
        pendingMode: _pendingMode,
        onSelected: _selectMode,
        onShowDevices: _showDevices,
        onSignOut: _confirmSignOut,
        controller: _terminals,
      ),
      AppMode.bridge => BridgeScreen(
        key: ValueKey('bridge-${_bridgeController?.hashCode ?? 0}'),
        controller: _getBridgeController(),
        onChangeMode: _changeMode,
        onShowDevices: _showDevices,
        onSignOut: _confirmSignOut,
        onAccount: () => _showAccountSheet(context),
      ),
      AppMode.monitor => MonitorScreen(
        key: ValueKey('monitor-${_monitorController?.hashCode ?? 0}'),
        controller: _getMonitorController(),
        onChangeMode: _changeMode,
        onShowDevices: _showDevices,
        onSignOut: _confirmSignOut,
        email: widget.email,
      ),
    };
  }

  BridgeController _getBridgeController() =>
      _bridgeController ??= BridgeController(
        firebaseService: _firebase,
        notificationService: widget.notificationService,
      );

  MonitorController _getMonitorController() =>
      _monitorController ??= MonitorController(
        firebaseService: _firebase,
        notificationService: widget.notificationService,
      );

  void _showAccountSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Cuenta', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.person_outline_rounded),
                ),
                title: Text(widget.email ?? 'Cuenta Equilibra'),
                subtitle: const Text('Sesión iniciada'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _showDevices();
                },
                icon: const Icon(Icons.devices_rounded),
                label: const Text('Dispositivos vinculados'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  side: const BorderSide(color: AppColors.danger),
                ),
                onPressed: () {
                  Navigator.pop(context);
                  _confirmSignOut();
                },
                icon: const Icon(Icons.logout_rounded),
                label: const Text('Cerrar sesión'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Arranque neutro mientras se valida el modo guardado.
///
/// Reemplaza a la pantalla de selección durante un instante para que al reabrir
/// la app no aparezcan las dos opciones antes del módulo ya elegido.
class _RestoringModeScreen extends StatelessWidget {
  const _RestoringModeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(AppConstants.logoAsset, height: 84),
            const SizedBox(height: 22),
            const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 14),
            const Text(
              'Abriendo Equilibra…',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
