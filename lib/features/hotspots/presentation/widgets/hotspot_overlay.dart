import 'package:flutter/material.dart';

import '../../domain/hotspot.dart';

/// Renders translucent tappable rectangles over a PDF page. The host (viewer)
/// is responsible for sizing this widget exactly to the rendered page.
class HotspotOverlay extends StatelessWidget {
  const HotspotOverlay({
    required this.hotspots,
    required this.pageSize, // PDF user units (1/72")
    required this.onActivate,
    super.key,
  });

  final List<Hotspot> hotspots;
  final Size pageSize;
  final void Function(Hotspot hotspot) onActivate;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaleX = constraints.maxWidth / pageSize.width;
        final scaleY = constraints.maxHeight / pageSize.height;
        return Stack(
          children: hotspots.map((h) {
            final left = h.bounds[0] * scaleX;
            final top = h.bounds[1] * scaleY;
            final right = h.bounds[2] * scaleX;
            final bottom = h.bounds[3] * scaleY;
            return Positioned(
              left: left,
              top: top,
              width: right - left,
              height: bottom - top,
              child: GestureDetector(
                onLongPress: () => onActivate(h),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.18),
                    border: Border.all(color: Colors.amber.shade700, width: 1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}
