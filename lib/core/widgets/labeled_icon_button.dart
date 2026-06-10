// SPDX-License-Identifier: AGPL-3.0
//
// LabeledIconButton — drop-in replacement for IconButton that adds an
// optional small text label below the icon when the user has enabled
// "Show icon labels" in Settings.
//
// On phones with labels off (the default): renders as a plain IconButton.
// On TV / when labels are on: renders the icon over a tiny label so
// D-pad users + tablet users can identify the button without having to
// hover for a tooltip.
//
// API mirrors IconButton's most-used args so adoption is search-and-replace.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/ui_preferences.dart';

class LabeledIconButton extends ConsumerWidget {
  const LabeledIconButton({
    required this.icon,
    required this.onPressed,
    this.label,
    this.tooltip,
    this.color,
    this.iconSize,
    this.padding,
    super.key,
  });

  /// The icon widget (typically `Icon(Icons.foo)`).
  final Widget icon;

  /// Press handler. Pass null to disable the button.
  final VoidCallback? onPressed;

  /// Short label rendered under the icon when icon-labels are on. When
  /// null, falls back to [tooltip] (truncated to ~10 chars). Pass an
  /// explicit short string when the tooltip would be too long
  /// (e.g. "Sign / approve (long-press: view chain)" → "Sign").
  final String? label;

  /// Tooltip shown on hover/long-press. Same as IconButton.tooltip.
  /// Always rendered (regardless of labels-on/off) so accessibility
  /// services + non-TV mouse users still see the full hint.
  final String? tooltip;

  /// Icon color override. Same as IconButton.color.
  final Color? color;

  /// Icon size override. Same as IconButton.iconSize.
  final double? iconSize;

  /// Padding around the icon. Same as IconButton.padding. Defaults to
  /// EdgeInsets.all(8) when labels are off (matches IconButton), tighter
  /// when labels are on so the icon+text combo doesn't bloat the bar.
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showLabels = ref.watch(uiPreferencesProvider).showIconLabels;
    if (!showLabels) {
      return IconButton(
        icon: icon,
        onPressed: onPressed,
        tooltip: tooltip,
        color: color,
        iconSize: iconSize,
        padding: padding ?? const EdgeInsets.all(8),
      );
    }

    final labelText = (label ?? tooltip ?? '').trim();
    final shortLabel = _truncate(labelText, 10);

    // Render icon + label as a single tappable column. Wrapped in
    // Tooltip so the full text is still discoverable for sighted
    // users / accessibility tools. Disabled state matches IconButton's
    // visual: half-opacity icon + non-interactive.
    final disabled = onPressed == null;
    final iconColor = color ??
        (disabled
            ? Theme.of(context).disabledColor
            : Theme.of(context).iconTheme.color);

    return Tooltip(
      message: tooltip ?? '',
      child: InkResponse(
        onTap: onPressed,
        radius: 24,
        child: Padding(
          padding: padding ?? const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconTheme(
                data: IconThemeData(
                  color: iconColor,
                  size: iconSize ?? 22,
                ),
                child: icon,
              ),
              if (shortLabel.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  shortLabel,
                  style: TextStyle(
                    fontSize: 9,
                    color: iconColor,
                    height: 1.0,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Trim a label to [maxChars]. Drops trailing parens groups first
  /// (so "Sign (long-press: view chain)" → "Sign") then hard-truncates.
  static String _truncate(String s, int maxChars) {
    if (s.isEmpty) return s;
    final parenIdx = s.indexOf('(');
    final cleaned = parenIdx > 0 ? s.substring(0, parenIdx).trim() : s;
    if (cleaned.length <= maxChars) return cleaned;
    return '${cleaned.substring(0, maxChars - 1)}…';
  }
}
