import 'dart:async';

import 'package:cool_alert/cool_alert.dart';
import 'package:flutter/material.dart';

import '../core/app_theme.dart';

/// Elección del usuario en un aviso con acción secundaria.
enum AlertChoice { confirm, secondary }

/// Alertas estilizadas de la app basadas en `cool_alert`.
abstract final class AppAlerts {
  static Future<void> success(
    BuildContext context, {
    required String title,
    required String text,
  }) {
    return _show(
      context,
      type: CoolAlertType.success,
      title: title,
      text: text,
      headerColor: AppColors.primary,
      buttonColor: AppColors.primary,
      confirmText: 'Entendido',
    );
  }

  static Future<void> info(
    BuildContext context, {
    required String title,
    required String text,
  }) {
    return _show(
      context,
      type: CoolAlertType.info,
      title: title,
      text: text,
      headerColor: AppColors.primary,
      buttonColor: AppColors.primary,
      confirmText: 'Entendido',
    );
  }

  static Future<void> warning(
    BuildContext context, {
    required String title,
    required String text,
  }) {
    return _show(
      context,
      type: CoolAlertType.warning,
      title: title,
      text: text,
      headerColor: AppColors.warning,
      buttonColor: AppColors.warning,
      confirmText: 'Entendido',
    );
  }

  static Future<void> error(
    BuildContext context, {
    required String title,
    required String text,
  }) {
    return _show(
      context,
      type: CoolAlertType.error,
      title: title,
      text: text,
      headerColor: AppColors.danger,
      buttonColor: AppColors.danger,
      confirmText: 'Cerrar',
    );
  }

  /// Aviso de error con una acción secundaria (por defecto «Ver registro»).
  ///
  /// Devuelve [AlertChoice.secondary] cuando el usuario pide ver el registro y
  /// [AlertChoice.confirm] cuando acepta la acción principal.
  static Future<AlertChoice> failure(
    BuildContext context, {
    required String title,
    required String text,
    String confirmText = 'Cerrar',
    String secondaryText = 'Ver registro',
    bool confirmIsDanger = false,
  }) async {
    final completer = Completer<AlertChoice>();

    await CoolAlert.show(
      context: context,
      type: CoolAlertType.error,
      title: title,
      text: text,
      barrierDismissible: false,
      showCancelBtn: true,
      confirmBtnText: confirmText,
      cancelBtnText: secondaryText,
      confirmBtnColor: confirmIsDanger ? AppColors.danger : AppColors.primary,
      backgroundColor: AppColors.danger,
      borderRadius: 24,
      titleTextStyle: _titleStyle,
      textTextStyle: _textStyle,
      confirmBtnTextStyle: _buttonStyle,
      cancelBtnTextStyle: _cancelStyle,
      onConfirmBtnTap: () {
        if (!completer.isCompleted) completer.complete(AlertChoice.confirm);
      },
      onCancelBtnTap: () {
        if (!completer.isCompleted) completer.complete(AlertChoice.secondary);
      },
    );

    if (!completer.isCompleted) completer.complete(AlertChoice.confirm);
    return completer.future;
  }

  /// Alerta de carga que la pantalla cierra manualmente al terminar la búsqueda.
  static Future<void> searchingDevices(BuildContext context) async {
    await CoolAlert.show(
      context: context,
      type: CoolAlertType.loading,
      text: 'Consultando dispositivos…',
      barrierDismissible: false,
      borderRadius: 18,
      backgroundColor: AppColors.primary,
    );
  }

  /// Confirmación con botones "Cancelar" / [confirmText].
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String text,
    String confirmText = 'Confirmar',
    String cancelText = 'Cancelar',
  }) async {
    final completer = Completer<bool>();

    await CoolAlert.show(
      context: context,
      type: CoolAlertType.warning,
      title: title,
      text: text,
      barrierDismissible: false,
      showCancelBtn: true,
      confirmBtnText: confirmText,
      cancelBtnText: cancelText,
      confirmBtnColor: AppColors.danger,
      backgroundColor: AppColors.primary,
      borderRadius: 18,
      titleTextStyle: _titleStyle,
      textTextStyle: _textStyle,
      confirmBtnTextStyle: _buttonStyle,
      cancelBtnTextStyle: _cancelStyle,
      onConfirmBtnTap: () {
        if (!completer.isCompleted) completer.complete(true);
      },
      onCancelBtnTap: () {
        if (!completer.isCompleted) completer.complete(false);
      },
    );

    if (!completer.isCompleted) completer.complete(false);
    return completer.future;
  }

  static Future<void> _show(
    BuildContext context, {
    required CoolAlertType type,
    required String title,
    required String text,
    required Color headerColor,
    required Color buttonColor,
    required String confirmText,
  }) async {
    await CoolAlert.show(
      context: context,
      type: type,
      title: title,
      text: text,
      confirmBtnText: confirmText,
      confirmBtnColor: buttonColor,
      backgroundColor: headerColor,
      borderRadius: 24,
      titleTextStyle: _titleStyle,
      textTextStyle: _textStyle,
      confirmBtnTextStyle: _buttonStyle,
    );
  }

  static const TextStyle _titleStyle = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 20,
    fontWeight: FontWeight.w700,
  );

  static const TextStyle _textStyle = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 14,
    height: 1.45,
  );

  static const TextStyle _buttonStyle = TextStyle(
    color: Colors.white,
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle _cancelStyle = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );
}
