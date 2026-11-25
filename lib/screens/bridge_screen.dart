import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/bridge_controller.dart';
import '../core/app_theme.dart';
import '../models/equilibra_event.dart';
import '../models/operation_result.dart';
import '../services/app_alerts.dart';
import '../services/app_initializer.dart';
import '../services/app_logger.dart';
import '../screens/bluetooth_scan_sheet.dart';
import '../widgets/alarm_action_button.dart';
import '../widgets/app_card.dart';
import '../widgets/log_viewer_sheet.dart';
import '../widgets/pulse_orb_indicator.dart';

class BridgeScreen extends StatefulWidget {
  const BridgeScreen({
    super.key,
    required this.controller,
    required this.onChangeMode,
    required this.onShowDevices,
    required this.onSignOut,
    required this.onAccount,
  });

  final BridgeController controller;
  final VoidCallback onChangeMode;
  final VoidCallback onShowDevices;
  final VoidCallback onSignOut;
  final VoidCallback onAccount;

  @override
  State<BridgeScreen> createState() => _BridgeScreenState();
}

class _BridgeScreenState extends State<BridgeScreen> {
  late final StreamSubscription<EquilibraEvent> _events;

  @override
  void initState() {
    super.initState();
    _events = widget.controller.events.listen(_showEvent);
    unawaited(_initialize());
  }

  /// Firebase y los plugins se inicializan fuera del `build`: cualquier fallo
  /// se registra pero nunca saca al usuario de la pantalla.
  Future<void> _initialize() async {
    try {
      await AppInitializer.ensureFirebaseReady();
      if (!mounted) return;
      AppLogger.info(LogTags.boot, 'Montando BridgeScreen (Modo Puente).');
      await widget.controller.initialize();
    } catch (error, stack) {
      AppLogger.error(
        LogTags.boot,
        'Fallo al abrir la estación base.',
        error,
        stack,
      );
      debugPrint('Equilibra: fallo al abrir la estación base: $error');
    }
  }

  Future<void> _showEvent(EquilibraEvent event) async {
    if (!mounted) return;
    if (event.type == EquilibraEventType.alarmActivated) {
      await AppAlerts.warning(context, title: event.title, text: event.message);
    } else {
      await AppAlerts.info(context, title: event.title, text: event.message);
    }
  }

  void _showResult(OperationResult result) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(result.message)));
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    // El controlador es propiedad de EquilibraApp: se dispone desde allí al
    // cambiar de modo o cerrar sesión. Aquí sólo se libera la suscripción local.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final alarm = controller.alarmStatus.isActivated;
        final point = controller.locationPoint;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Estación base'),
            actions: [
              const LogViewerButton(),
              IconButton(
                tooltip: 'Dispositivos vinculados',
                onPressed: widget.onShowDevices,
                icon: const Icon(Icons.devices_rounded),
              ),
              IconButton(
                tooltip: 'Cambiar modo',
                onPressed: widget.onChangeMode,
                icon: const Icon(Icons.swap_horiz_rounded),
              ),
              IconButton(
                tooltip: 'Cuenta',
                onPressed: widget.onAccount,
                icon: const Icon(Icons.account_circle_outlined),
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 34),
              children: [
                _AlarmPanel(active: alarm, connected: controller.isConnected),
                const SizedBox(height: 18),
                AlarmActionButton(
                  active: alarm,
                  busy: controller.isBusy,
                  onPressed: controller.isConnected
                      ? () async =>
                            _showResult(await controller.deactivateAlarm())
                      : null,
                ),
                const SizedBox(height: 18),
                _BluetoothCard(
                  controller: controller,
                  onResult: _showResult,
                  onScan: () => BluetoothScanSheet.show(
                    context: context,
                    controller: controller,
                    onResult: _showResult,
                  ),
                  locationText: point == null
                      ? 'GPS pendiente · se enviará al conectar'
                      : 'GPS en la nube · ${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
                ),
                const SizedBox(height: 14),
                const _ServiceCard(active: true),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BluetoothCard extends StatelessWidget {
  const _BluetoothCard({
    required this.controller,
    required this.onResult,
    required this.onScan,
    required this.locationText,
  });

  final BridgeController controller;
  final ValueChanged<OperationResult> onResult;
  final VoidCallback onScan;
  final String locationText;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: AppColors.accentSoft,
                  child: Icon(
                    controller.isConnected
                        ? Icons.bluetooth_connected_rounded
                        : Icons.bluetooth_searching_rounded,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Conexión Bluetooth',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        controller.isConnected
                            ? 'Conectado a ${controller.device?.displayName}'
                            : 'Varayoc_ESP32 sin conexión',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 14),
            child: FilledButton.icon(
              onPressed: controller.isBusy ? null : onScan,
              icon: const Icon(Icons.search_rounded),
              label: Text(
                controller.isConnected
                    ? 'Cambiar equipo'
                    : 'Buscar dispositivo Bluetooth',
              ),
            ),
          ),
          if (controller.isConnected)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: OutlinedButton.icon(
                onPressed: controller.isBusy
                    ? null
                    : () async => onResult(await controller.disconnect()),
                icon: const Icon(Icons.link_off_rounded),
                label: const Text('Desconectar puente'),
              ),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  Icons.cloud_done_rounded,
                  color: controller.locationPoint == null
                      ? AppColors.textSecondary
                      : AppColors.success,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    locationText,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: AppColors.divider),
    ),
    clipBehavior: Clip.antiAlias,
    child: ListTile(
      tileColor: Colors.transparent,
      leading: Icon(
        active ? Icons.bolt_rounded : Icons.info_outline_rounded,
        color: active ? AppColors.success : AppColors.warning,
      ),
      title: const Text('Supervisión en segundo plano'),
      subtitle: Text(
        active
            ? 'Activa · la alarma se alertará aunque minimices la app'
            : 'Inactiva · revisa los permisos del teléfono',
      ),
    ),
  );
}

class _AlarmPanel extends StatelessWidget {
  const _AlarmPanel({required this.active, required this.connected});

  final bool active;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? AppColors.danger
        : connected
        ? AppColors.primary
        : AppColors.neutral;
    final orbState = active
        ? PulseOrbState.alarm
        : connected
        ? PulseOrbState.monitoring
        : PulseOrbState.disconnected;
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
      child: Column(
        children: [
          PulseOrbIndicator(state: orbState),
          const SizedBox(height: 4),
          Text(
            active
                ? '¡Alarma activada!'
                : connected
                ? 'Monitoreando'
                : 'Sin conexión',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            active
                ? 'Revisa a la persona.'
                : connected
                ? 'Sistema listo.'
                : 'Conecta un equipo Bluetooth.',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
