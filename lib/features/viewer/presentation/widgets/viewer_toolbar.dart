import 'package:flutter/material.dart';

import '../providers/viewer_controller.dart';

/// Bottom toolbar mapping to the PRD's overlay row:
/// `[Select] [Highlight] [Sign] [Stamp] [Edit] [Search]`.
class ViewerToolbar extends StatelessWidget {
  const ViewerToolbar({
    required this.tool,
    required this.onChanged,
    super.key,
  });

  final ViewerTool tool;
  final ValueChanged<ViewerTool> onChanged;

  @override
  Widget build(BuildContext context) {
    return BottomAppBar(
      padding: EdgeInsets.zero,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: <Widget>[
          _ToolButton(
            icon: Icons.text_fields,
            label: 'Select',
            active: tool == ViewerTool.select,
            onTap: () => onChanged(ViewerTool.select),
          ),
          _ToolButton(
            icon: Icons.format_color_fill,
            label: 'Highlight',
            active: tool == ViewerTool.highlight,
            onTap: () => onChanged(ViewerTool.highlight),
          ),
          _ToolButton(
            icon: Icons.draw_outlined,
            label: 'Sign',
            active: tool == ViewerTool.sign,
            onTap: () => onChanged(ViewerTool.sign),
          ),
          _ToolButton(
            icon: Icons.approval_outlined,
            label: 'Stamp',
            active: tool == ViewerTool.stamp,
            onTap: () => onChanged(ViewerTool.stamp),
          ),
          _ToolButton(
            icon: Icons.edit_note,
            label: 'Edit',
            active: tool == ViewerTool.edit,
            onTap: () => onChanged(ViewerTool.edit),
          ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, color: active ? cs.primary : cs.onSurfaceVariant),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: active ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
