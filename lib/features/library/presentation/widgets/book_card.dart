
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/thumbnail_service.dart';

/// One "book" on the shelf. Renders the first-page thumbnail when ready,
/// a coloured placeholder before then, and the PDF's filename centred
/// below as the spine label.
///
/// Tap → open in viewer.
/// Long-press → context menu (the parent provides the callback so this
/// widget stays decoupled from routing).
///
/// TV-aware: wraps the touch GestureDetector in a FocusableActionDetector
/// so D-pad OK / Enter / Space / GameButtonA fires onTap, plus paints a
/// cyan ring + 1.04× scale when focused so the user can see which book
/// is currently selected on the shelf. Without this the bookshelf was
/// effectively unusable from a TV remote — focus went somewhere
/// invisible and OK did nothing.
class BookCard extends ConsumerStatefulWidget {
  const BookCard({
    required this.pdfPath,
    required this.onTap,
    this.onLongPress,
    this.height = 180,
    this.autofocus = false,
    super.key,
  });

  final String pdfPath;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double height;
  final bool autofocus;

  @override
  ConsumerState<BookCard> createState() => _BookCardState();
}

class _BookCardState extends ConsumerState<BookCard> {
  bool _focused = false;

  static const _activateShortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
  };

  @override
  Widget build(BuildContext context) {
    final pdfPath = widget.pdfPath;
    final height = widget.height;
    final thumb = ref.watch(
      thumbnailFileProvider(
        ThumbnailRequest(pdfPath: pdfPath, size: ThumbSize.small),
      ),
    );
    final cs = Theme.of(context).colorScheme;
    final width = height * 0.72; // typical book aspect ratio
    final ringColor = _focused ? const Color(0xFF22D3EE) : Colors.transparent;

    final inner = GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: width,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Drop shadow / book-on-shelf depth.
                Positioned(
                  left: 4,
                  right: 0,
                  bottom: 4,
                  top: 6,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.25),
                      borderRadius: const BorderRadius.only(
                        topRight: Radius.circular(3),
                        bottomRight: Radius.circular(3),
                      ),
                    ),
                  ),
                ),
                // Cover.
                ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(2),
                    topRight: Radius.circular(4),
                    bottomLeft: Radius.circular(2),
                    bottomRight: Radius.circular(4),
                  ),
                  child: thumb.when(
                    data: (file) {
                      if (file == null) return _Placeholder(name: pdfPath);
                      return Image.file(
                        file,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      );
                    },
                    loading: () => _Placeholder(name: pdfPath, shimmer: true),
                    error: (_, __) => _Placeholder(name: pdfPath),
                  ),
                ),
                // Subtle "spine" gutter on the left edge to evoke a
                // bound book rather than a flat photograph.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 3,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.black.withOpacity(0.35),
                          Colors.black.withOpacity(0.05),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: width + 6,
            child: Text(
              p.basenameWithoutExtension(pdfPath),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                height: 1.2,
                color: cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );

    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      shortcuts: _activateShortcuts,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: AnimatedScale(
        scale: _focused ? 1.04 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ringColor, width: 2),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: ringColor.withValues(alpha: 0.5),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ]
                : const [],
          ),
          child: inner,
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.name, this.shimmer = false});
  final String name;
  final bool shimmer;

  /// Pick a deterministic colour from the file name so a placeholder for
  /// the same PDF always uses the same cover hue. Saves us from solid
  /// grey while real thumbs render.
  Color _coverColor(BuildContext context) {
    final h = name.hashCode.abs();
    final hues = [
      const Color(0xFF7B4B94), // purple
      const Color(0xFF1B6B7A), // teal
      const Color(0xFFA84E47), // brick
      const Color(0xFF3F6F3A), // forest
      const Color(0xFF8A6A2C), // mustard
      const Color(0xFF2F4858), // navy
    ];
    return hues[h % hues.length];
  }

  @override
  Widget build(BuildContext context) {
    final base = _coverColor(context);
    final highlight = Color.alphaBlend(
      Colors.white.withOpacity(shimmer ? 0.18 : 0.08),
      base,
    );
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base, highlight],
        ),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(6),
      child: Text(
        p.basenameWithoutExtension(name).toUpperCase(),
        textAlign: TextAlign.center,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 10,
          height: 1.2,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
