import 'package:flutter/material.dart';

import '../controllers/bridge_controller.dart';
import '../core/app_theme.dart';
import '../models/device_info.dart';
import '../models/operation_result.dart';

/// Ventana emergente de búsqueda y vinculación del ESP32.
class BluetoothScanSheet extends StatefulWidget {
  const BluetoothScanSheet({
    super.key,
    required this.controller,
    required this.onResult,
  });

  final BridgeController controller;
  final ValueChanged<OperationResult> onResult;

  static Future<void> show({
    required BuildContext context,
    required BridgeController controller,
    required ValueChanged<OperationResult> onResult,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.82,
        child: BluetoothScanSheet(controller: controller, onResult: onResult),
      ),
    );
  }

  @override
  State<BluetoothScanSheet> createState() => _BluetoothScanSheetState();
}

class _BluetoothScanSheetState extends State<BluetoothScanSheet> {
  bool _connecting = false;
  String? _connectingAddress;
  bool? _bluetoothEnabled;
  bool _checkingBluetooth = false;
  bool _enablingBluetooth = false;

  @override
  void initState() {
    super.initState();
    _refreshBluetoothState();
  }

  Future<bool> _refreshBluetoothState() async {
    if (mounted) setState(() => _checkingBluetooth = true);
    final enabled = await widget.controller.isBluetoothEnabled();
    if (mounted) {
      setState(() {
        _bluetoothEnabled = enabled;
        _checkingBluetooth = false;
      });
    }
    return enabled;
  }

  Future<void> _rescan() async {
    if (!await _refreshBluetoothState()) return;
    final result = await widget.controller.stopDiscovery();
    final next = await widget.controller.startDiscovery();
    if (!next.success) widget.onResult(result);
    widget.onResult(next);
  }

  Future<void> _enableBluetooth() async {
    if (_enablingBluetooth) return;
    setState(() => _enablingBluetooth = true);
    final result = await widget.controller.enableBluetooth();
    if (!mounted) return;
    if (!result.success) widget.onResult(result);
    final enabled = await widget.controller.isBluetoothEnabled();
    if (!mounted) return;
    setState(() {
      _bluetoothEnabled = enabled;
      _enablingBluetooth = false;
    });
  }

  Future<void> _connect(DeviceInfo device) async {
    if (_connecting) return;
    setState(() {
      _connecting = true;
      _connectingAddress = device.address;
    });
    final result = await widget.controller.connectTo(device);
    if (!mounted) return;
    widget.onResult(result);
    if (result.success) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _connecting = false;
      _connectingAddress = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final equilibraDevices = controller.devices
            .where(_isEquilibraDevice)
            .toList(growable: false);
        final otherDevices = controller.devices
            .where((device) => !_isEquilibraDevice(device))
            .toList(growable: false);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const CircleAvatar(
                      backgroundColor: AppColors.accentSoft,
                      child: Icon(
                        Icons.bluetooth_searching_rounded,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Equipos Bluetooth',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const Text(
                            'Busca y conecta tu Varayoc_ESP32',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_bluetoothEnabled == false) ...[
                  const SizedBox(height: 16),
                  _BluetoothOffCard(
                    busy: _enablingBluetooth,
                    onEnable: _enableBluetooth,
                  ),
                ],
                const SizedBox(height: 16),
                if (controller.isScanning) ...[
                  const LinearProgressIndicator(minHeight: 3),
                  const SizedBox(height: 6),
                  const Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Buscando equipos cercanos...',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            controller.isBusy ||
                                _checkingBluetooth ||
                                _enablingBluetooth
                            ? null
                            : _rescan,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Buscar'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: controller.isScanning
                            ? () async => widget.onResult(
                                await controller.stopDiscovery(),
                              )
                            : null,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('Detener'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: ListView(
                    children: [
                      _SectionTitle(
                        label: 'Dispositivos ESP32 / Equilibra',
                        count: equilibraDevices.length,
                      ),
                      if (equilibraDevices.isEmpty)
                        const _EmptyHint(
                          text: 'No se detectaron módulos ESP32 cercanos.',
                        )
                      else
                        for (final device in equilibraDevices)
                          _DeviceTile(
                            device: device,
                            connecting: _connecting,
                            busy: _connectingAddress == device.address,
                            onTap: () => _connect(device),
                          ),
                      const SizedBox(height: 16),
                      _SectionTitle(
                        label: 'Todos los dispositivos Bluetooth',
                        count: otherDevices.length,
                      ),
                      if (otherDevices.isEmpty)
                        const _EmptyHint(
                          text: 'No se detectaron otros dispositivos.',
                        )
                      else
                        for (final device in otherDevices)
                          _DeviceTile(
                            device: device,
                            connecting: _connecting,
                            busy: _connectingAddress == device.address,
                            onTap: () => _connect(device),
                          ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BluetoothOffCard extends StatelessWidget {
  const _BluetoothOffCard({required this.busy, required this.onEnable});

  final bool busy;
  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.accentSoft,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.accentStrong),
    ),
    child: Row(
      children: [
        const CircleAvatar(
          backgroundColor: Colors.white,
          child: Icon(
            Icons.bluetooth_disabled_rounded,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Text(
            'El Bluetooth está apagado',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: busy ? null : onEnable,
          child: busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Encender'),
        ),
      ],
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(color: AppColors.primary, fontWeight: FontWeight.w800),
        ),
        const SizedBox(width: 8),
        _Badge(label: '$count'),
      ],
    ),
  );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surfaceTint,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Text(
      text,
      style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
    ),
  );
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.connecting,
    required this.busy,
    required this.onTap,
  });

  final DeviceInfo device;
  final bool connecting;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final recommended = _isEquilibraDevice(device);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: recommended ? AppColors.accentSoft : AppColors.surfaceTint,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: recommended ? AppColors.accentStrong : AppColors.divider,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          tileColor: Colors.transparent,
          leading: CircleAvatar(
            backgroundColor: Colors.white,
            child: Icon(
              recommended
                  ? Icons.health_and_safety_rounded
                  : Icons.bluetooth_rounded,
              color: AppColors.primary,
            ),
          ),
          title: Text(
            device.displayName,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            '${device.address} · ${device.isPaired ? 'Vinculado' : 'Nuevo'}',
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),
          trailing: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : (connecting
                    ? const Icon(Icons.bluetooth_connected_rounded)
                    : const Icon(Icons.chevron_right_rounded)),
          onTap: connecting ? null : onTap,
        ),
      ),
    );
  }
}

bool _isEquilibraDevice(DeviceInfo device) {
  final name = device.name.toLowerCase();
  return const [
    'esp32',
    'equilibra',
    'varayoc',
    'hc-05',
    'hc-06',
    'ble',
  ].any(name.contains);
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: AppColors.primary.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      label,
      style: const TextStyle(
        color: AppColors.primary,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
