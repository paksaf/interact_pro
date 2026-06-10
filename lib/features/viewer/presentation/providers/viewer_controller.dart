import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../../../../core/utils/result.dart';
import '../../domain/entities/pdf_document.dart';
import '../../data/repositories/pdf_repository_impl.dart';

/// Selected toolbar tool — drives what tap/long-press does on the page.
enum ViewerTool { none, select, highlight, sign, stamp, edit, redact }

class ViewerState {
  const ViewerState({
    this.document,
    this.tool = ViewerTool.none,
    this.searchQuery = '',
    this.errorMessage,
    this.isLoading = false,
  });

  final PdfDocument? document;
  final ViewerTool tool;
  final String searchQuery;
  final String? errorMessage;
  final bool isLoading;

  ViewerState copyWith({
    PdfDocument? document,
    ViewerTool? tool,
    String? searchQuery,
    String? errorMessage,
    bool? isLoading,
  }) =>
      ViewerState(
        document: document ?? this.document,
        tool: tool ?? this.tool,
        searchQuery: searchQuery ?? this.searchQuery,
        errorMessage: errorMessage,
        isLoading: isLoading ?? this.isLoading,
      );
}

class ViewerController extends AutoDisposeNotifier<ViewerState> {
  final PdfViewerController pdfController = PdfViewerController();

  @override
  ViewerState build() {
    ref.onDispose(pdfController.dispose);
    return const ViewerState();
  }

  Future<void> openPath(String path) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    final repo = await ref.read(pdfRepositoryProvider.future);
    final Result<PdfDocument> r = await repo.open(path);
    r.fold(
      (PdfDocument doc) =>
          state = state.copyWith(document: doc, isLoading: false),
      (failure) => state = state.copyWith(
        isLoading: false,
        errorMessage: failure.message,
      ),
    );
  }

  void setTool(ViewerTool tool) => state = state.copyWith(tool: tool);

  void search(String q) {
    state = state.copyWith(searchQuery: q);
    if (q.isNotEmpty) pdfController.searchText(q);
  }

  void jumpToPage(int page) => pdfController.jumpToPage(page);
}

final AutoDisposeNotifierProvider<ViewerController, ViewerState>
    viewerControllerProvider =
    AutoDisposeNotifierProvider<ViewerController, ViewerState>(
        ViewerController.new,);
