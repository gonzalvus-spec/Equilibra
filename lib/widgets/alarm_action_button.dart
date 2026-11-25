import 'package:flutter/material.dart';

import '../core/app_theme.dart';

class AlarmActionButton extends StatefulWidget {
  const AlarmActionButton({
    super.key,
    required this.active,
    required this.onPressed,
    this.busy = false,
  });

  final bool active;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  State<AlarmActionButton> createState() => _AlarmActionButtonState();
}

class _AlarmActionButtonState extends State<AlarmActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(AlarmActionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final glow = widget.active ? 0.2 + (_pulse.value * 0.22) : 0.08;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          height: 64,
          width: double.infinity,
          decoration: BoxDecoration(
            color: widget.active ? AppColors.danger : AppColors.surfaceTint,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: widget.active ? AppColors.danger : AppColors.divider,
            ),
            boxShadow: [
              BoxShadow(
                color: (widget.active ? AppColors.danger : AppColors.primary)
                    .withValues(alpha: glow),
                blurRadius: widget.active ? 18 + (_pulse.value * 8) : 10,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              onTap: widget.active && !widget.busy ? widget.onPressed : null,
              borderRadius: BorderRadius.circular(18),
              child: Center(
                child: widget.busy
                    ? const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.notifications_off_rounded,
                            color: widget.active
                                ? Colors.white
                                : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            widget.active
                                ? 'DESACTIVAR ALARMA'
                                : 'Alarma en reposo',
                            style: TextStyle(
                              color: widget.active
                                  ? Colors.white
                                  : AppColors.textSecondary,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}
