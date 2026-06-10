import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/labeled_icon_button.dart';
import '../providers/cast_provider.dart';
import 'cast_sheet.dart';

/// AppBar action that opens the cast sheet. Icon swaps to [Icons.cast_connected]
/// + accent colour while a session is active so the user has an at-a-glance
/// indicator that mirroring is on.
///
/// Uses LabeledIconButton so TV / tablet users see a "Cast" label under
/// the icon when "Show icon labels" is on (task #4b). Color override on
/// the icon is preserved so the active-cast accent still shows.
class CastButton extends ConsumerWidget {
  const CastButton({
    required this.pdfPath,
    required this.documentTitle,
    required this.currentPage,
    required this.totalPages,
    super.key,
  });

  final String pdfPath;
  final String documentTitle;
  final int currentPage;
  final int totalPages;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCasting = ref.watch(isCastingProvider);
    final cs = Theme.of(context).colorScheme;
    return LabeledIconButton(
      tooltip: isCasting ? 'Casting — tap to manage' : 'Cast to TV / AirPlay',
      label: 'Cast',
      // Icon gets the active-cast accent inline. LabeledIconButton's
      // own `color` prop is intentionally not used here so the icon-
      // level color override survives independently of the label text
      // (which always picks up the default theme color).
      icon: Icon(
        isCasting ? Icons.cast_connected : Icons.cast,
        color: isCasting ? cs.primary : null,
      ),
      onPressed: () {
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => CastSheet(
            pdfPath: pdfPath,
            documentTitle: documentTitle,
            currentPage: currentPage,
            totalPages: totalPages,
          ),
        );
      },
    );
  }
}
