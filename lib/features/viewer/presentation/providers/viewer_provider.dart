import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/result.dart';
import '../../data/repositories/pdf_repository_impl.dart';
import '../../domain/entities/pdf_document.dart';
import 'viewer_controller.dart';

/// Re-export so feature code can `import 'viewer_provider.dart'` without
/// pulling the controller file separately.
export 'viewer_controller.dart' show ViewerTool;

/// One source of truth for the viewer's currently selected tool.
///
/// Used by [ViewerScreen] / [ViewerToolbar]; flips between Select / Highlight
/// / Sign / Stamp / Edit. Reset to [ViewerTool.none] on screen pop.
final viewerModeProvider = StateProvider.autoDispose<ViewerTool>((ref) {
  return ViewerTool.none;
});

/// 1-indexed current page in the active document. Drives the page-number
/// chip, "read aloud current page", and any per-page caches (translation /
/// OCR overlays).
final currentPageProvider = StateProvider.autoDispose<int>((ref) => 1);

/// All locally available PDFs. Watched by Home → RecentDocuments.
///
/// Backed by drift via [PdfRepository.listLocal].
final allDocumentsProvider = FutureProvider<List<PdfDocument>>((ref) async {
  final repo = await ref.watch(pdfRepositoryProvider.future);
  final Result<List<PdfDocument>> r = await repo.listLocal();
  return r.fold(
    (docs) => docs..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
    (failure) => throw failure,
  );
});
