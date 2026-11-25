import 'package:flutter/material.dart';

import '../controllers/terminal_controller.dart';
import '../core/app_theme.dart';
import '../models/terminal_info.dart';

class LinkedDevicesSheet extends StatelessWidget {
  const LinkedDevicesSheet({
    super.key,
    required this.controller,
    required this.onSignOut,
  });

  final TerminalController controller;
  final VoidCallback onSignOut;

  Future<void> _remove(BuildContext context, TerminalInfo terminal) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remover dispositivo'),
        content: Text('Se cerrará la sesión en ${terminal.name}.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.remove(terminal.id);
      if (context.mounted && terminal.id == controller.terminalId) {
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            // `currentTerminal` lee el identificador del terminal, que aún no
            // existe hasta que termina `TerminalController.initialize()`.
            // Construirlo antes de `ready` lanzaba un error de nulabilidad al
            // abrir la lista de dispositivos justo después de iniciar sesión.
            final terminals = !controller.ready
                ? const <TerminalInfo>[]
                : controller.terminals.isEmpty
                ? [controller.currentTerminal]
                : controller.terminals;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.divider,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Dispositivos vinculados',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 14),
                if (!controller.ready)
                  const Center(child: CircularProgressIndicator())
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: terminals.length,
                      separatorBuilder: (_, _) => const Divider(),
                      itemBuilder: (context, index) {
                        final terminal = terminals[index];
                        final isCurrent = terminal.id == controller.terminalId;
                        return Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceTint,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: AppColors.divider),
                          ),
                          child: Row(
                            children: [
                              const CircleAvatar(
                                backgroundColor: AppColors.accentSoft,
                                child: Icon(Icons.smartphone_rounded),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(child: Text(terminal.name)),
                                        if (isCurrent) ...[
                                          const SizedBox(width: 7),
                                          const _Badge(label: 'Este equipo'),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 7,
                                      runSpacing: 5,
                                      children: [
                                        _Badge(label: terminal.roleLabel),
                                        _Badge(
                                          label: terminal.online
                                              ? 'En línea'
                                              : 'Desconectado',
                                          online: terminal.online,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'Remover',
                                onPressed: () => _remove(context, terminal),
                                icon: const Icon(Icons.delete_outline_rounded),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.accentSoft,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.add_to_home_screen_rounded,
                        color: AppColors.primary,
                      ),
                      SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Vincula un segundo teléfono',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Instala Equilibra e inicia sesión con esta misma cuenta. Luego elige Monitor remoto.',
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
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    side: const BorderSide(color: AppColors.danger),
                  ),
                  onPressed: onSignOut,
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Cerrar sesión'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, this.online});

  final String label;
  final bool? online;

  @override
  Widget build(BuildContext context) {
    final color = online == null
        ? AppColors.primary
        : online!
        ? AppColors.success
        : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
