/// Causa por la que no se pudo confirmar la reserva de rol.
///
/// [RoleClaimFailure.isRetryable] distingue los fallos de infraestructura
/// (red lenta, timeout, error desconocido) de los definitivos (sesión no
/// válida o reglas de seguridad), que no tiene sentido reintentar.
enum RoleClaimFailure {
  offline,
  unauthenticated,
  timeout,
  permissionDenied,
  unknown;

  bool get isRetryable => switch (this) {
    RoleClaimFailure.offline ||
    RoleClaimFailure.timeout ||
    RoleClaimFailure.unknown => true,
    RoleClaimFailure.unauthenticated ||
    RoleClaimFailure.permissionDenied => false,
  };

  String get label => switch (this) {
    RoleClaimFailure.offline => 'sin conexión con Firebase',
    RoleClaimFailure.unauthenticated => 'sesión de Firebase Auth no válida',
    RoleClaimFailure.timeout => 'tiempo de espera agotado',
    RoleClaimFailure.permissionDenied =>
      'permisos de Realtime Database denegados',
    RoleClaimFailure.unknown => 'error desconocido',
  };
}

/// Resultado de reservar el rol de un terminal en Realtime Database.
///
/// Antes un único `false` mezclaba tres desenlaces muy distintos:
/// - [claimed]: la transacción se confirmó en el servidor.
/// - [occupied]: otro terminal mantiene ese rol activo.
/// - [revoked]: este terminal fue desvinculado de la cuenta.
/// - [failed]: no se pudo verificar (red, timeout, sesión o reglas); el
///   llamador debe conservar la interfaz y reintentar, nunca cerrar sesión.
class RoleClaimResult {
  const RoleClaimResult.claimed()
    : claimed = true,
      revoked = false,
      failure = null,
      detail = null,
      conflictingTerminalId = null,
      conflictingDeviceName = null;

  const RoleClaimResult.occupied({
    required String terminalId,
    required String deviceName,
  }) : claimed = false,
       revoked = false,
       failure = null,
       detail = null,
       conflictingTerminalId = terminalId,
       conflictingDeviceName = deviceName;

  const RoleClaimResult.revoked()
    : claimed = false,
      revoked = true,
      failure = null,
      detail = null,
      conflictingTerminalId = null,
      conflictingDeviceName = null;

  const RoleClaimResult.failed(RoleClaimFailure this.failure, {this.detail})
    : claimed = false,
      revoked = false,
      conflictingTerminalId = null,
      conflictingDeviceName = null;

  final bool claimed;
  final bool revoked;

  /// Causa del fallo; `null` cuando el resultado es definitivo.
  final RoleClaimFailure? failure;

  /// Detalle técnico del último intento fallido, útil para el log.
  final String? detail;

  final String? conflictingTerminalId;
  final String? conflictingDeviceName;

  /// `true` cuando el rol está activo en otro terminal.
  bool get occupied => conflictingTerminalId != null;

  /// `true` cuando no se pudo verificar por infraestructura (reintentable).
  bool get failed => failure != null;

  /// `true` cuando el resultado es concluyente: ocupado, revocado o reservado.
  ///
  /// Un resultado no definitivo nunca debe interpretarse como "cupo lleno".
  bool get definitive => !failed;

  String get failureLabel => failure?.label ?? 'resultado sin confirmar';
}
