import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../controllers/monitor_controller.dart';
import '../core/app_theme.dart';
import '../models/history_event.dart';
import '../models/operation_result.dart';
import '../services/app_initializer.dart';
import '../services/app_logger.dart';
import '../widgets/account_menu.dart';
import '../widgets/alarm_action_button.dart';
import '../widgets/app_card.dart';
import '../widgets/log_viewer_sheet.dart';
import '../widgets/pulse_orb_indicator.dart';

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({
    super.key,
    required this.controller,
    required this.onChangeMode,
    required this.onShowDevices,
    required this.onSignOut,
    required this.email,
  });

  final MonitorController controller;
  final VoidCallback onChangeMode;
  final VoidCallback onShowDevices;
  final VoidCallback onSignOut;
  final String? email;

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  /// Firebase y los plugins se inicializan fuera del `build`: cualquier fallo
  /// se registra pero nunca saca al usuario de la pantalla.
  Future<void> _initialize() async {
    try {
      await AppInitializer.ensureFirebaseReady();
      if (!mounted) return;
      AppLogger.info(LogTags.boot, 'Montando MonitorScreen (Modo Monitor).');
      await widget.controller.initialize();
    } catch (error, stack) {
      AppLogger.error(
        LogTags.boot,
        'Fallo al abrir el monitor remoto.',
        error,
        stack,
      );
      debugPrint('Equilibra: fallo al abrir el monitor remoto: $error');
    }
  }

  @override
  void dispose() {
    // El controlador es propiedad de EquilibraApp; se dispone desde allí al
    // cambiar de modo o cerrar sesión.
    super.dispose();
  }

  void _showResult(OperationResult result) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(result.message)));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return Scaffold(
          extendBody: true,
          appBar: AppBar(
            title: Text(switch (_tab) {
              0 => 'Alarma',
              1 => 'Mapa',
              _ => 'Historial',
            }),
            actions: [
              const LogViewerButton(),
              IconButton(
                tooltip: 'Cambiar modo',
                onPressed: widget.onChangeMode,
                icon: const Icon(Icons.swap_horiz_rounded),
              ),
              AccountMenu(
                email: widget.email,
                onShowDevices: widget.onShowDevices,
                onSignOut: widget.onSignOut,
              ),
            ],
          ),
          body: IndexedStack(
            index: _tab,
            children: [
              _AlarmTab(controller: widget.controller, onResult: _showResult),
              _MapTab(controller: widget.controller),
              _HistoryTab(
                events: widget.controller.history,
                monitoring: widget.controller.state.hasFreshBridge,
              ),
            ],
          ),
          bottomNavigationBar: _CapsuleNavigation(
            selected: _tab,
            onSelected: (value) => setState(() => _tab = value),
          ),
        );
      },
    );
  }
}

class _AlarmTab extends StatelessWidget {
  const _AlarmTab({required this.controller, required this.onResult});

  final MonitorController controller;
  final ValueChanged<OperationResult> onResult;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final active = state.alarmActive;
    final online = state.hasFreshBridge;
    final color = active
        ? AppColors.danger
        : online
        ? AppColors.primary
        : AppColors.neutral;
    final orbState = active
        ? PulseOrbState.alarm
        : online
        ? PulseOrbState.monitoring
        : PulseOrbState.disconnected;
    if (controller.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
      children: [
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
          child: Column(
            children: [
              PulseOrbIndicator(state: orbState),
              const SizedBox(height: 4),
              Text(
                active
                    ? '¡Alarma activada!'
                    : online
                    ? 'Monitoreando'
                    : 'Sin señal',
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(color: color, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                active
                    ? 'Revisa a la persona.'
                    : online
                    ? 'Estación conectada.'
                    : 'Esperando al teléfono puente.',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        AlarmActionButton(
          active: active,
          busy: controller.busy,
          onPressed: () async => onResult(await controller.deactivateAlarm()),
        ),
        const SizedBox(height: 18),
        Material(
          color: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: AppColors.divider),
          ),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            tileColor: Colors.transparent,
            leading: Icon(
              state.hasFreshBridge
                  ? Icons.wifi_rounded
                  : Icons.wifi_off_rounded,
              color: state.hasFreshBridge
                  ? AppColors.success
                  : AppColors.danger,
            ),
            title: const Text('Teléfono puente'),
            subtitle: Text(state.hasFreshBridge ? 'En línea' : 'Sin señal'),
          ),
        ),
        if (controller.error != null) ...[
          const SizedBox(height: 12),
          Text(
            controller.error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.danger),
          ),
        ],
      ],
    );
  }
}

class _MapTab extends StatefulWidget {
  const _MapTab({required this.controller});

  final MonitorController controller;

  @override
  State<_MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<_MapTab> {
  final MapController _mapController = MapController();

  void _center() {
    final point = widget.controller.state.location;
    if (point == null) return;
    _mapController.move(LatLng(point.latitude, point.longitude), 16);
  }

  @override
  Widget build(BuildContext context) {
    final location = widget.controller.state.location;
    const fallback = LatLng(-12.0464, -77.0428);
    final point = location == null
        ? fallback
        : LatLng(location.latitude, location.longitude);
    final heartbeat = widget.controller.state.lastHeartbeat;
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: point,
            initialZoom: location == null ? 11 : 16,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.equilibra.equilibra',
            ),
            if (location != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: point,
                    width: 56,
                    height: 56,
                    child: const Icon(
                      Icons.location_pin,
                      color: AppColors.danger,
                      size: 52,
                    ),
                  ),
                ],
              ),
          ],
        ),
        if (location == null)
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: AppCard(
              padding: const EdgeInsets.all(15),
              child: Row(
                children: [
                  const Icon(
                    Icons.gps_not_fixed_rounded,
                    color: AppColors.warning,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Esperando señal GPS del teléfono puente...',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          heartbeat == null
                              ? 'Aún no se recibió una conexión.'
                              : 'Última conexión: ${DateFormat('dd/MM · HH:mm').format(heartbeat)}',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        Positioned(
          right: 18,
          bottom: 112,
          child: FloatingActionButton.small(
            heroTag: 'center-map',
            onPressed: location == null ? null : _center,
            tooltip: 'Centrar',
            child: const Icon(Icons.my_location_rounded),
          ),
        ),
      ],
    );
  }
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab({required this.events, required this.monitoring});

  final List<HistoryEvent> events;
  final bool monitoring;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(18, 30, 18, 120),
        children: [
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 34),
            child: Column(
              children: [
                Container(
                  width: 78,
                  height: 78,
                  decoration: const BoxDecoration(
                    color: AppColors.accentSoft,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.history_toggle_off_rounded,
                    size: 42,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Sin alertas registradas',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Aquí aparecerán las detecciones de caída y apagados del equipo.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: monitoring
                        ? AppColors.successSoft
                        : AppColors.warningSoft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        monitoring
                            ? Icons.shield_rounded
                            : Icons.cloud_off_rounded,
                        color: monitoring
                            ? AppColors.success
                            : AppColors.warning,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        monitoring
                            ? 'Monitoreo activo'
                            : 'Esperando a la estación',
                        style: TextStyle(
                          color: monitoring
                              ? AppColors.success
                              : AppColors.warning,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 120),
      itemCount: events.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final event = events[index];
        final hasCoordinates =
            event.latitude != null && event.longitude != null;
        return Material(
          color: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: AppColors.divider),
          ),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            tileColor: Colors.transparent,
            leading: CircleAvatar(
              backgroundColor: event.type == 'caida_impacto'
                  ? AppColors.dangerSoft
                  : AppColors.accentSoft,
              child: Icon(
                event.type == 'caida_impacto'
                    ? Icons.warning_amber_rounded
                    : Icons.notifications_off_rounded,
                color: event.type == 'caida_impacto'
                    ? AppColors.danger
                    : AppColors.primary,
              ),
            ),
            title: Text(event.label),
            subtitle: Text(
              '${DateFormat('dd/MM/yyyy · HH:mm').format(event.timestamp)}'
              '${hasCoordinates ? '\n${event.latitude!.toStringAsFixed(5)}, ${event.longitude!.toStringAsFixed(5)}' : ''}',
            ),
            isThreeLine: hasCoordinates,
          ),
        );
      },
    );
  }
}

class _CapsuleNavigation extends StatelessWidget {
  const _CapsuleNavigation({required this.selected, required this.onSelected});

  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.notifications_rounded, 'Alarma'),
      (Icons.map_rounded, 'Mapa'),
      (Icons.history_rounded, 'Historial'),
    ];
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(28, 0, 28, 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.primaryDark, AppColors.primary],
          ),
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(
              color: AppColors.primaryDark.withValues(alpha: 0.24),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(32),
          child: SizedBox(
            height: 68,
            child: Row(
              children: [
                for (var index = 0; index < items.length; index++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(25),
                        onTap: () => onSelected(index),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          decoration: BoxDecoration(
                            color: selected == index
                                ? Colors.white.withValues(alpha: 0.13)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(25),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                items[index].$1,
                                color: selected == index
                                    ? AppColors.accent
                                    : Colors.white70,
                              ),
                              Text(
                                items[index].$2,
                                style: TextStyle(
                                  color: selected == index
                                      ? AppColors.accent
                                      : Colors.white70,
                                  fontSize: 12,
                                  fontWeight: selected == index
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
