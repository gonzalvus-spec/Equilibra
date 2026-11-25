import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../core/app_constants.dart';
import '../core/app_theme.dart';
import '../models/app_mode.dart';
import '../services/app_initializer.dart';
import '../services/app_logger.dart';
import '../services/auth_service.dart';
import '../services/mode_preferences.dart';
import '../services/notification_service.dart';
import '../widgets/app_card.dart';
import '../widgets/log_viewer_sheet.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, this.authService, this.preferences});

  /// Inyectable para pruebas. En producción se usa Firebase Authentication.
  final AuthService? authService;
  final SharedPreferences? preferences;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  /// Tiempo máximo que el arranque mantiene el indicador de sesión.
  ///
  /// Firebase se sigue inicializando en segundo plano; pasado este plazo la
  /// pantalla de inicio de sesión queda usable aunque Core aún no responda.
  static const Duration _bootFirebaseWait = Duration(seconds: 3);

  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  AuthService? _resolvedAuth;
  StreamSubscription<User?>? _authSubscription;
  bool _registering = false;
  bool _busy = false;
  bool _hidePassword = true;
  bool _openingApp = false;
  late bool _checkingSavedSession;
  SharedPreferences? _preferences;
  String? _error;

  AuthService get _authService =>
      widget.authService ?? (_resolvedAuth ??= FirebaseAuthService());

  @override
  void initState() {
    super.initState();
    _preferences = widget.preferences;
    _checkingSavedSession =
        widget.authService == null &&
        (ModePreferences(widget.preferences).cachedHasActiveSession ?? true);
    AppLogger.info(LogTags.boot, 'Montando AuthScreen (inicio de sesión).');
    unawaited(_watchSession());
  }

  /// Escucha `authStateChanges` dentro de esta pantalla.
  ///
  /// Si ya hay una sesión en caché se abre el modo guardado sin pasar por
  /// ningún splash. Con un servicio inyectado (pruebas) no se toca Firebase.
  ///
  /// La espera de Firebase Core está acotada a [_bootFirebaseWait]: si el
  /// dispositivo o la red son lentos, el formulario se libera y la
  /// inicialización continúa en segundo plano. Cuando termina, se conecta la
  /// escucha de sesión sin bloquear ni dejar la pantalla colgada.
  Future<void> _watchSession() async {
    if (widget.authService != null) return;

    try {
      _preferences ??= await SharedPreferences.getInstance();
      final hasActiveSession = ModePreferences(_preferences)
          .cachedHasActiveSession;
      if (hasActiveSession == false && mounted && _checkingSavedSession) {
        setState(() => _checkingSavedSession = false);
      }
    } catch (_) {
      // Sin preferencias se confirma el estado directamente con Firebase.
    }

    AppLogger.info(
      LogTags.boot,
      'Esperando Firebase Core para restaurar la sesión '
      '(máx. ${_bootFirebaseWait.inSeconds} s)…',
    );
    try {
      await AppInitializer.ensureFirebaseReady().timeout(_bootFirebaseWait);
    } on TimeoutException {
      AppLogger.warn(
        LogTags.boot,
        'Firebase Core aún no responde; se libera la pantalla de inicio de '
        'sesión y la inicialización continúa en segundo plano.',
      );
    }

    if (!AppInitializer.isReady) {
      // La UI nunca queda esperando a Firebase: se retira el indicador y se
      // sigue intentando por detrás (incluye el reintento de AppInitializer).
      _finishSessionCheck();
      AppLogger.info(
        LogTags.boot,
        'La inicialización de Firebase continúa en segundo plano; la escucha '
        'de sesión se conectará cuando termine.',
      );
      await AppInitializer.ensureFirebaseReady();
      if (!mounted) return;
    }

    if (!AppInitializer.isReady) {
      AppLogger.warn(
        LogTags.auth,
        'Firebase no está disponible todavía; el formulario sigue operativo '
        'y se reintentará la inicialización al iniciar sesión.',
      );
      _finishSessionCheck();
      return;
    }

    AppLogger.info(LogTags.boot, 'Firebase Core listo; restaurando sesión…');
    if (!mounted) return;

    try {
      final auth = FirebaseAuth.instance;
      _authSubscription = auth.authStateChanges().listen(
        (user) => unawaited(_handleUser(user)),
        onError: (_) {
          // Se mantiene el formulario; no se congela el flujo.
        },
      );
      final cached = auth.currentUser;
      AppLogger.info(
        LogTags.auth,
        cached == null
            ? 'currentUser: no hay sesión activa; se muestra el formulario.'
            : 'currentUser detectado (${cached.uid}); abriendo la app.',
      );
      if (cached != null) unawaited(_handleUser(cached));
    } catch (error, stack) {
      // Firebase Auth no disponible: se conserva el formulario en lugar de
      // dejar el indicador de carga para siempre.
      AppLogger.error(
        LogTags.auth,
        'Firebase Auth no está disponible; se mantiene el formulario.',
        error,
        stack,
      );
      _finishSessionCheck();
    }
  }

  /// Cierra el indicador de sesión sin dejar la pantalla bloqueada.
  void _finishSessionCheck() {
    if (!mounted || !_checkingSavedSession) return;
    setState(() => _checkingSavedSession = false);
  }

  Future<void> _handleUser(User? user) async {
    if (!mounted) return;
    AppLogger.info(
      LogTags.auth,
      user == null
          ? 'authStateChanges: sesión cerrada.'
          : 'authStateChanges: sesión activa (${user.uid}).',
    );
    if (user == null) {
      await _saveSessionFlag(false);
      if (!mounted) return;
      setState(() => _checkingSavedSession = false);
      // Sesión cerrada o expirada: se vuelve al formulario.
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.popUntil((route) => route.isFirst);
      }
      return;
    }
    if (!_checkingSavedSession) {
      setState(() => _checkingSavedSession = true);
    }
    await _saveSessionFlag(true);
    await _openApp(user);
  }

  Future<void> _saveSessionFlag(bool active) async {
    try {
      _preferences ??= await SharedPreferences.getInstance();
      await ModePreferences(_preferences).saveHasActiveSession(active);
    } catch (_) {
      // Firebase sigue siendo la fuente de verdad si falla el almacenamiento.
    }
  }

  Future<void> _openApp(User user) async {
    if (_openingApp || !mounted) return;
    _openingApp = true;

    SharedPreferences? preferences;
    AppMode? mode;
    try {
      preferences =
          _preferences ??
          await SharedPreferences.getInstance().timeout(
            const Duration(seconds: 2),
          );
      _preferences = preferences;
      // Lectura sincrónica desde la caché ya precargada en `main()`: evita un
      // `await` entre el inicio de sesión y la construcción de `EquilibraApp`.
      mode = ModePreferences(preferences).cachedMode;
    } catch (_) {
      // Sin preferencias se abre la selección de modo.
    }

    // La sesión pudo cerrarse mientras se leían las preferencias. Se usa el
    // acceso seguro para no lanzar si Firebase Core aún no estuviera listo.
    final current = AppInitializer.safeCurrentUser();
    if (!mounted || current?.uid != user.uid) {
      _openingApp = false;
      return;
    }

    AppLogger.info(
      LogTags.modo,
      'Navegando a EquilibraApp con modo ${mode?.storageValue ?? 'sin guardar'}.',
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => EquilibraApp(
          key: ValueKey(user.uid),
          uid: user.uid,
          email: user.email,
          notificationService: NotificationService(),
          initialMode: mode,
          preferences: preferences,
        ),
      ),
    );

    _openingApp = false;
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.authService == null) {
        // Verifica (y si hace falta espera/reintenta) Firebase Core antes de
        // construir `FirebaseAuthService` o tocar Firebase Auth.
        await AppInitializer.requireFirebaseReady();
      }
      final email = _emailController.text.trim();
      final password = _passwordController.text;
      AppLogger.info(
        LogTags.auth,
        _registering
            ? 'Registrando cuenta $email…'
            : 'Iniciando sesión $email…',
      );
      if (_registering) {
        await _authService.register(email: email, password: password);
      } else {
        await _authService.signIn(email: email, password: password);
      }
      await _saveSessionFlag(true);
      AppLogger.ok(
        LogTags.auth,
        _registering ? 'Cuenta $email creada.' : 'Sesión iniciada: $email.',
      );
    } on FirebaseInitializationException catch (error) {
      AppLogger.error(
        LogTags.auth,
        'Inicio de sesión detenido: Firebase Core no está inicializado '
        'todavía.',
        error,
      );
      if (mounted) {
        setState(
          () => _error =
              'No se pudo conectar con Firebase. Revisa tu conexión a '
              'internet e inténtalo de nuevo.',
        );
      }
    } catch (error, stack) {
      AppLogger.error(
        LogTags.auth,
        _registering
            ? 'Fallo al registrar la cuenta.'
            : 'Fallo al iniciar sesión.',
        error,
        stack,
      );
      if (mounted) setState(() => _error = authErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSavedSession) return _buildSessionLoading();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        actions: const [LogViewerButton()],
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFE9F8FC),
              AppColors.background,
              Color(0xFFF8FBFD),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                left: 24,
                top: 24,
                right: 24,
                bottom: 24 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 92,
                          height: 92,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(26),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.primary.withValues(alpha: 0.2),
                                blurRadius: 28,
                                offset: const Offset(0, 12),
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Image.asset(
                            AppConstants.logoAsset,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        _registering ? 'Crea tu cuenta' : 'Bienvenido',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _registering
                            ? 'Protege y acompaña desde cualquier lugar.'
                            : 'Tu red de asistencia, siempre cerca.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                      const SizedBox(height: 24),
                      AppCard(
                        child: Column(
                          children: [
                            TextFormField(
                              controller: _emailController,
                              keyboardType: TextInputType.emailAddress,
                              autofillHints: const [AutofillHints.email],
                              decoration: const InputDecoration(
                                labelText: 'Correo',
                                prefixIcon: Icon(Icons.email_outlined),
                              ),
                              validator: (value) {
                                final email = value?.trim() ?? '';
                                if (!email.contains('@') ||
                                    !email.contains('.')) {
                                  return 'Ingresa un correo válido.';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _passwordController,
                              obscureText: _hidePassword,
                              autofillHints: _registering
                                  ? const [AutofillHints.newPassword]
                                  : const [AutofillHints.password],
                              decoration: InputDecoration(
                                labelText: 'Contraseña',
                                prefixIcon: const Icon(
                                  Icons.lock_outline_rounded,
                                ),
                                suffixIcon: IconButton(
                                  onPressed: () => setState(
                                    () => _hidePassword = !_hidePassword,
                                  ),
                                  icon: Icon(
                                    _hidePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                ),
                              ),
                              validator: (value) => (value?.length ?? 0) < 6
                                  ? 'Usa al menos 6 caracteres.'
                                  : null,
                            ),
                            if (_registering) ...[
                              const SizedBox(height: 14),
                              TextFormField(
                                controller: _confirmController,
                                obscureText: true,
                                decoration: const InputDecoration(
                                  labelText: 'Repite la contraseña',
                                  prefixIcon: Icon(Icons.lock_reset_rounded),
                                ),
                                validator: (value) =>
                                    value != _passwordController.text
                                    ? 'Las contraseñas no coinciden.'
                                    : null,
                              ),
                            ],
                            if (_error != null) ...[
                              const SizedBox(height: 14),
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: AppColors.danger),
                              ),
                            ],
                            const SizedBox(height: 20),
                            FilledButton(
                              onPressed: _busy ? null : _submit,
                              child: _busy
                                  ? const SizedBox.square(
                                      dimension: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(
                                      _registering
                                          ? 'Crear cuenta'
                                          : 'Iniciar sesión',
                                    ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _registering = !_registering;
                                _error = null;
                              }),
                        child: Text(
                          _registering
                              ? 'Ya tengo una cuenta'
                              : 'Crear una cuenta',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSessionLoading() {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFE9F8FC),
              AppColors.background,
              Color(0xFFF8FBFD),
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.2),
                      blurRadius: 28,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.asset(AppConstants.logoAsset, fit: BoxFit.cover),
              ),
              const SizedBox(height: 24),
              const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(height: 16),
              const Text(
                'Preparando la conexión…',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
