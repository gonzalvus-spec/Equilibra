import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_theme.dart';
import '../models/log_entry.dart';
import '../services/app_logger.dart';

enum _LogFilter { todos, errores, bluetooth, firebase }

/// Botón discreto para abrir el visor de registros desde cualquier AppBar.
class LogViewerButton extends StatelessWidget {
  const LogViewerButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Ver registros',
      onPressed: () => LogViewerSheet.show(context),
      icon: const Icon(Icons.terminal_rounded),
    );
  }
}

/// Modal con el historial en vivo, filtros rápidos y copia al portapapeles.
class LogViewerSheet extends StatefulWidget {
  const LogViewerSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) => const FractionallySizedBox(
        heightFactor: 0.82,
        child: LogViewerSheet(),
      ),
    );
  }

  @override
  State<LogViewerSheet> createState() => _LogViewerSheetState();
}

class _LogViewerSheetState extends State<LogViewerSheet> {
  _LogFilter _filter = _LogFilter.todos;

  bool _matches(LogEntry entry) => switch (_filter) {
    _LogFilter.todos => true,
    _LogFilter.errores => entry.level == LogLevel.error,
    _LogFilter.bluetooth => entry.tag == LogTags.bluetooth,
    _LogFilter.firebase => entry.tag == LogTags.firebase,
  };

  Future<void> _copyAll() async {
    final text = AppLogger.allText;
    if (!mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay registros para copiar.')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Registros copiados al portapapeles')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  backgroundColor: AppColors.accentSoft,
                  child: Icon(Icons.terminal_rounded, color: AppColors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Registros de Equilibra',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Text(
                        'Historial en tiempo real · más recientes arriba',
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
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _copyAll,
                    icon: const Icon(Icons.copy_all_rounded, size: 18),
                    label: const Text('Copiar todo'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: AppLogger.clear,
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: const Text('Limpiar'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _FilterChip(
                    label: 'Todos',
                    selected: _filter == _LogFilter.todos,
                    onSelected: () =>
                        setState(() => _filter = _LogFilter.todos),
                  ),
                  _FilterChip(
                    label: 'Errores',
                    selected: _filter == _LogFilter.errores,
                    onSelected: () =>
                        setState(() => _filter = _LogFilter.errores),
                  ),
                  _FilterChip(
                    label: 'Bluetooth',
                    selected: _filter == _LogFilter.bluetooth,
                    onSelected: () =>
                        setState(() => _filter = _LogFilter.bluetooth),
                  ),
                  _FilterChip(
                    label: 'Firebase',
                    selected: _filter == _LogFilter.firebase,
                    onSelected: () =>
                        setState(() => _filter = _LogFilter.firebase),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ValueListenableBuilder<List<LogEntry>>(
                valueListenable: AppLogger.instance.entries,
                builder: (context, entries, _) {
                  final visible = entries
                      .where(_matches)
                      .toList(growable: false);
                  if (visible.isEmpty) {
                    return const Center(
                      child: Text(
                        'Sin registros para este filtro.',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    );
                  }
                  return ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) =>
                        _LogTile(entry: visible[index]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onSelected(),
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = switch (entry.level) {
      LogLevel.info => const Color(0xFF3474A8),
      LogLevel.ok => AppColors.success,
      LogLevel.warn => AppColors.warning,
      LogLevel.error => AppColors.danger,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
      child: Text.rich(
        TextSpan(
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.35,
          ),
          children: [
            TextSpan(
              text: entry.timeLabel,
              style: const TextStyle(color: AppColors.neutral),
            ),
            TextSpan(
              text: ' ${entry.level.label.padRight(5)} ',
              style: TextStyle(color: color, fontWeight: FontWeight.w800),
            ),
            TextSpan(
              text: '[${entry.tag}] ',
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
            TextSpan(
              text: entry.message,
              style: const TextStyle(color: AppColors.textPrimary),
            ),
            if (entry.error != null)
              TextSpan(
                text: '\n↳ ${entry.error}',
                style: TextStyle(color: color, fontSize: 11),
              ),
          ],
        ),
      ),
    );
  }
}
