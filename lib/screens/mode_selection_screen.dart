import 'package:flutter/material.dart';

import '../core/app_constants.dart';
import '../core/app_theme.dart';
import '../controllers/terminal_controller.dart';
import '../models/app_mode.dart';
import '../services/app_logger.dart';
import '../widgets/log_viewer_sheet.dart';

class ModeSelectionScreen extends StatelessWidget {
  const ModeSelectionScreen({
    super.key,
    required this.onSelected,
    required this.onShowDevices,
    required this.onSignOut,
    required this.controller,
    this.pendingMode,
  });

  final ValueChanged<AppMode> onSelected;
  final VoidCallback onShowDevices;
  final VoidCallback onSignOut;
  final TerminalController controller;

  /// Modo tocado mientras se muestra el indicador de carga de la tarjeta.
  final AppMode? pendingMode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Selecciona un modo'),
        actions: [
          const LogViewerButton(),
          IconButton(
            tooltip: 'Dispositivos vinculados',
            onPressed: onShowDevices,
            icon: const Icon(Icons.devices_rounded),
          ),
          IconButton(
            tooltip: 'Salir',
            onPressed: onSignOut,
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) {
              final keyboard = MediaQuery.viewInsetsOf(context).bottom;
              final minHeight = constraints.hasBoundedHeight
                  ? (constraints.maxHeight - 48)
                        .clamp(0.0, double.infinity)
                        .toDouble()
                  : 0.0;
              return SingleChildScrollView(
                padding: EdgeInsets.only(
                  left: 24,
                  top: 24,
                  right: 24,
                  bottom: 24 + keyboard,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minHeight),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisAlignment: MainAxisAlignment.center,
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
                        '¿Cómo usarás este teléfono?',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      const SizedBox(height: 20),
                      if (pendingMode != null) ...[
                        const LinearProgressIndicator(minHeight: 3),
                        const SizedBox(height: 16),
                      ] else
                        const SizedBox(height: 8),
                      _ModeCard(
                        icon: Icons.bluetooth_connected_rounded,
                        title: 'Estación base',
                        subtitle: 'Este teléfono estará junto a Varayoc_ESP32.',
                        busy: pendingMode == AppMode.bridge,
                        occupiedBy: _occupant('puente'),
                        onTap: () {
                          AppLogger.info(
                            LogTags.modo,
                            'Pulsación en Estación base.',
                          );
                          onSelected(AppMode.bridge);
                        },
                      ),
                      const SizedBox(height: 14),
                      _ModeCard(
                        icon: Icons.mobile_friendly_rounded,
                        title: 'Monitor remoto',
                        subtitle: 'Consulta y controla Equilibra a distancia.',
                        busy: pendingMode == AppMode.monitor,
                        occupiedBy: _occupant('monitor'),
                        onTap: () {
                          AppLogger.info(
                            LogTags.modo,
                            'Pulsación en Monitor remoto.',
                          );
                          onSelected(AppMode.monitor);
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  String? _occupant(String role) {
    for (final terminal in controller.terminals) {
      if (terminal.id != controller.terminalId &&
          terminal.role == role &&
          !terminal.isOrphaned) {
        return terminal.name;
      }
    }
    return null;
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.busy = false,
    this.occupiedBy,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool busy;
  final String? occupiedBy;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.07),
            blurRadius: 24,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: AppColors.accentSoft,
                  foregroundColor: AppColors.primary,
                  child: Icon(icon, size: 30),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                      if (occupiedBy != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.danger.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            'Ocupado por $occupiedBy',
                            style: const TextStyle(
                              color: AppColors.danger,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (busy)
                  const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                else
                  const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
