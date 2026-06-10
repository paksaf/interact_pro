import 'package:flutter/material.dart';

/// Single horizontal shelf with wood-textured base. The parent passes
/// the books as children; this widget handles the wood / shadow / depth.
///
/// Layout: books stand on top of the shelf board, the board is a thin
/// brown strip with a darker shadow underneath. We fake wood grain with
/// a vertical gradient + a darker top edge so the shelf feels grounded
/// without us shipping a wood texture asset.
class ShelfRow extends StatelessWidget {
  const ShelfRow({
    required this.books,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    super.key,
  });

  final List<Widget> books;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Books stand on top of the board.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final b in books) Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: b,
                ),
              ],
            ),
          ),
          // Wood board.
          Container(
            height: 14,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF5C3B1E),
                  Color(0xFF7C5530),
                  Color(0xFF4F3017),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.35),
                  blurRadius: 6,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
          ),
          // Faux floor shadow under the shelf — adds depth between rows.
          Container(
            height: 8,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.22),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
