// SPDX-License-Identifier: AGPL-3.0
//
// AnnotationToolPalette — floating bottom-anchored bar with tool +
// color + stroke pickers (#261, 2026-05-20). Auto-hides when
// AnnotationEditState.tool is None.
//
// Lives ABOVE the page in the viewer's Stack so it's always
// reachable. Doesn't capture pointer events outside the palette
// chrome — taps on the page go through to the EditOverlay painter
// behind it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../annotation_edit_controller.dart';

class AnnotationToolPalette extends ConsumerWidget {
  const AnnotationToolPalette({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(annotationEditControllerProvider);
    if (!s.isEditing) return const SizedBox.shrink();
    final ctrl = ref.read(annotationEditControllerProvider.notifier);
    final cs = Theme.of(context).colorScheme;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 24,
      child: Center(
        child: Material(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.96),
          elevation: 8,
          shadowColor: Colors.black.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(28),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ToolGroup(state: s, ctrl: ctrl),
                _Divider(cs: cs),
                _ColorSwatchRow(state: s, ctrl: ctrl),
                _Divider(cs: cs),
                _StrokeRow(state: s, ctrl: ctrl),
                _Divider(cs: cs),
                _FocusableToolButton(
                  tooltip: 'Exit editing',
                  onTap: ctrl.exit,
                  child: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolGroup extends StatelessWidget {
  const _ToolGroup({required this.state, required this.ctrl});
  final AnnotationEditState state;
  final AnnotationEditController ctrl;

  static const _tools = <(AnnotationTool, IconData, String)>[
    (AnnotationTool.highlighter, Icons.format_color_fill, 'Highlight'),
    (AnnotationTool.pen, Icons.edit, 'Pen'),
    (AnnotationTool.eraser, Icons.cleaning_services_outlined, 'Eraser'),
    (AnnotationTool.circle, Icons.circle_outlined, 'Circle'),
    (AnnotationTool.rectangle, Icons.rectangle_outlined, 'Rectangle'),
    (AnnotationTool.arrow, Icons.north_east, 'Arrow'),
    (AnnotationTool.text, Icons.notes, 'Note'),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _tools.length; i++)
          _FocusableToolButton(
            tooltip: _tools[i].$3,
            selected: state.tool == _tools[i].$1,
            // Autofocus the FIRST tool button when the palette appears
            // so a TV-remote user lands on something immediately and
            // doesn't have to dance the D-pad to find a target.
            autofocus: i == 0,
            onTap: () => ctrl.selectTool(_tools[i].$1),
            child: Icon(_tools[i].$2, size: 20),
          ),
      ],
    );
  }
}

/// Tiny focusable button used everywhere in the palette — tool icons,
/// color swatches, stroke previews, close. D-pad lands cleanly on
/// each one via FocusableActionDetector + the same activator set that
/// _TvNavTile uses (Select/Enter/NumpadEnter/Space/GameButtonA).
class _FocusableToolButton extends StatefulWidget {
  const _FocusableToolButton({
    required this.child,
    required this.onTap,
    this.tooltip,
    this.selected = false,
    this.autofocus = false,
  });

  final Widget child;
  final VoidCallback onTap;
  final String? tooltip;
  final bool selected;
  final bool autofocus;

  @override
  State<_FocusableToolButton> createState() => _FocusableToolButtonState();
}

class _FocusableToolButtonState extends State<_FocusableToolButton> {
  bool _focused = false;

  static const _activate = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ring = _focused ? const Color(0xFF22D3EE) : Colors.transparent;
    final bg = widget.selected
        ? cs.primaryContainer
        : Colors.transparent;
    final inner = AnimatedScale(
      scale: _focused ? 1.06 : 1.0,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ring, width: 2),
          boxShadow: _focused
              ? [
                  BoxShadow(
                    color: ring.withValues(alpha: 0.5),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ]
              : const [],
        ),
        child: IconTheme(
          data: IconThemeData(
            color: widget.selected
                ? cs.onPrimaryContainer
                : cs.onSurface,
          ),
          child: widget.child,
        ),
      ),
    );
    final wrapped = FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      shortcuts: _activate,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      mouseCursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: inner,
      ),
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: wrapped)
        : wrapped;
  }
}

class _ColorSwatchRow extends StatelessWidget {
  const _ColorSwatchRow({required this.state, required this.ctrl});
  final AnnotationEditState state;
  final AnnotationEditController ctrl;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final c in annotationSwatches)
          _FocusableToolButton(
            selected: state.color == c,
            onTap: () => ctrl.setColor(c),
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                  color: state.color == c
                      ? Colors.black87
                      : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _StrokeRow extends StatelessWidget {
  const _StrokeRow({required this.state, required this.ctrl});
  final AnnotationEditState state;
  final AnnotationEditController ctrl;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final s in StrokePreset.values)
          _FocusableToolButton(
            selected: state.stroke == s,
            onTap: () => ctrl.setStroke(s),
            child: SizedBox(
              width: 22,
              height: 22,
              child: Center(
                child: Container(
                  width: 18,
                  height: s.width,
                  decoration: BoxDecoration(
                    color: state.stroke == s
                        ? cs.onPrimaryContainer
                        : cs.onSurface.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.cs});
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Container(
        width: 1,
        height: 24,
        color: cs.outlineVariant.withValues(alpha: 0.55),
      ),
    );
  }
}
