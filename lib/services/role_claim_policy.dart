import 'dart:math' as math;

/// Política de la campaña de reserva de rol en Realtime Database.
///
/// Sustituye al corte abrupto de 10 s: cada intento tiene su propio límite y,
/// entre intentos, se aplica un backoff exponencial acotado. [overallTimeout]
/// mantiene un techo claro para que la pantalla de selección no quede
/// esperando indefinidamente.
///
/// La distinción entre "rol ocupado" y "fallo de red" no depende del tiempo:
/// la transacción sólo devuelve `RoleClaimResult.occupied` cuando detecta
/// otro terminal activo con el mismo rol.
class RoleClaimPolicy {
  const RoleClaimPolicy({
    this.maxAttempts = 3,
    this.attemptTimeout = const Duration(seconds: 7),
    this.overallTimeout = const Duration(seconds: 20),
    this.authTimeout = const Duration(seconds: 6),
    this.connectionTimeout = const Duration(seconds: 5),
    this.retryConnectionTimeout = const Duration(seconds: 2),
    this.presenceTimeout = const Duration(seconds: 4),
    this.firstBackoff = const Duration(milliseconds: 600),
    this.maxBackoff = const Duration(milliseconds: 2500),
  }) : assert(maxAttempts > 0, 'Se requiere al menos un intento.');

  /// Política usada por la app; centralizarla evita números mágicos dispersos.
  static const RoleClaimPolicy standard = RoleClaimPolicy();

  /// Intentos máximos de la transacción (incluye el primero).
  final int maxAttempts;

  /// Límite de una transacción concreta, ya con conexión confirmada.
  final Duration attemptTimeout;

  /// Techo de la campaña de reintentos, sin contar [authTimeout].
  final Duration overallTimeout;

  /// Espera máxima a que Firebase Auth restaure la sesión y el token.
  final Duration authTimeout;

  /// Espera a `.info/connected` antes del primer intento.
  final Duration connectionTimeout;

  /// Espera a `.info/connected` en los reintentos (más corta).
  final Duration retryConnectionTimeout;

  /// Límite para registrar `onDisconnect` después de un commit; nunca
  /// invalida una reserva ya confirmada.
  final Duration presenceTimeout;

  /// Pausa base del backoff exponencial.
  final Duration firstBackoff;

  /// Tope del backoff para no alargar la campaña.
  final Duration maxBackoff;

  /// Pausa antes del intento [failedAttempt] + 1.
  ///
  /// 600 ms → 1,2 s → 2,4 s → 2,5 s (tope)…
  Duration backoffFor(int failedAttempt) {
    if (failedAttempt < 1) return Duration.zero;
    final exponent = math.min(failedAttempt - 1, 10);
    final millis = firstBackoff.inMilliseconds * (1 << exponent);
    return Duration(milliseconds: math.min(millis, maxBackoff.inMilliseconds));
  }

  /// Tiempo restante de la campaña; nunca negativo.
  Duration remainingBudget(Duration elapsed) {
    final remaining = overallTimeout - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Envolvente máxima de una campaña completa: autenticación, reintentos,
  /// presencia posterior al commit y un margen para el trabajo nativo.
  Duration get totalBudget =>
      authTimeout +
      overallTimeout +
      presenceTimeout +
      const Duration(seconds: 2);
}
