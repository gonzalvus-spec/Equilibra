/// Resultado de una operación iniciada por el usuario.
class OperationResult {
  const OperationResult._({
    required this.success,
    required this.message,
    this.cancelled = false,
    this.canOpenSettings = false,
  });

  const OperationResult.success(String message)
    : this._(success: true, message: message);

  const OperationResult.failure(String message, {bool canOpenSettings = false})
    : this._(
        success: false,
        message: message,
        canOpenSettings: canOpenSettings,
      );

  const OperationResult.cancelled([String message = 'Operación cancelada.'])
    : this._(success: false, message: message, cancelled: true);

  final bool success;
  final String message;
  final bool cancelled;

  /// Indica que el usuario debe conceder un permiso en los ajustes del sistema.
  final bool canOpenSettings;
}
