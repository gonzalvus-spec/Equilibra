import 'package:flutter/material.dart';

import '../core/app_theme.dart';

/// Menú de cuenta reutilizable en el AppBar de ambos modos.
class AccountMenu extends StatelessWidget {
  const AccountMenu({
    super.key,
    required this.email,
    required this.onShowDevices,
    required this.onSignOut,
  });

  final String? email;
  final VoidCallback onShowDevices;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Cuenta',
    icon: const Icon(Icons.account_circle_outlined),
    onSelected: (value) {
      if (value == 'devices') onShowDevices();
      if (value == 'signout') onSignOut();
    },
    itemBuilder: (context) => [
      PopupMenuItem<String>(
        enabled: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Sesión iniciada',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              Text(
                email ?? 'Cuenta Equilibra',
                style: const TextStyle(fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem<String>(
        value: 'devices',
        child: Row(
          children: [
            Icon(Icons.devices_rounded, size: 20),
            SizedBox(width: 12),
            Text('Dispositivos vinculados'),
          ],
        ),
      ),
      const PopupMenuItem<String>(
        value: 'signout',
        child: Row(
          children: [
            Icon(Icons.logout_rounded, size: 20, color: AppColors.danger),
            SizedBox(width: 12),
            Text('Cerrar sesión', style: TextStyle(color: AppColors.danger)),
          ],
        ),
      ),
    ],
  );
}
