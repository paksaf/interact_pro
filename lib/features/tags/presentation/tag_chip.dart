// SPDX-License-Identifier: AGPL-3.0
//
// TagChip — small color-tinted pill rendering a tag. Used in:
//   - the library card (under the title)
//   - the tag picker sheet
//   - the tag manager screen
//   - the filter row

import 'package:flutter/material.dart';

import '../../../core/storage/app_database.dart';

class TagChip extends StatelessWidget {
  const TagChip({
    required this.tag,
    this.selected = false,
    this.onTap,
    this.onDelete,
    this.dense = false,
    super.key,
  });

  final Tag tag;

  /// True when this chip is the active selection (used in pickers).
  /// Renders a filled background instead of an outline.
  final bool selected;

  /// Tap handler — usually used to toggle selection in pickers.
  /// Pass null to render as a static label.
  final VoidCallback? onTap;

  /// If provided, renders an X icon on the trailing side. Used in the
  /// "tags applied" row inside the PDF detail view.
  final VoidCallback? onDelete;

  /// Compact mode for the library card — smaller text + tighter padding.
  final bool dense;

  Color get _baseColor {
    final hex = tag.colorHex.replaceAll('#', '');
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return Colors.blueGrey;
    return Color(0xFF000000 | value);
  }

  @override
  Widget build(BuildContext context) {
    final base = _baseColor;
    final brightness = ThemeData.estimateBrightnessForColor(base);
    final fg = brightness == Brightness.dark ? Colors.white : Colors.black87;
    final pad = dense
        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
        : const EdgeInsets.symmetric(horizontal: 10, vertical: 4);
    final fontSize = dense ? 10.0 : 12.0;

    return Material(
      color: selected ? base : base.withValues(alpha: 0.12),
      shape: StadiumBorder(side: BorderSide(color: base, width: 1)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: pad,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.check, size: fontSize + 2, color: fg),
                ),
              Text(
                tag.name,
                style: TextStyle(
                  color: selected ? fg : base,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (onDelete != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: InkWell(
                    onTap: onDelete,
                    customBorder: const CircleBorder(),
                    child: Icon(
                      Icons.close,
                      size: fontSize + 2,
                      color: selected ? fg : base,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
