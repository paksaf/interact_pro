import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/result.dart';
import '../../../viewer/domain/entities/pdf_document.dart';
import '../../data/repositories/editor_repository_impl.dart';
import '../../domain/entities/edit_action.dart';

class EditorState {
  EditorState({
    this.document,
    Queue<EditAction>? undoStack,
    Queue<EditAction>? redoStack,
    this.error,
    this.isApplying = false,
  })  : undoStack = undoStack ?? Queue<EditAction>(),
        redoStack = redoStack ?? Queue<EditAction>();

  final PdfDocument? document;
  final Queue<EditAction> undoStack;
  final Queue<EditAction> redoStack;
  final String? error;
  final bool isApplying;

  bool get canUndo => undoStack.isNotEmpty;
  bool get canRedo => redoStack.isNotEmpty;

  EditorState copyWith({
    PdfDocument? document,
    Queue<EditAction>? undoStack,
    Queue<EditAction>? redoStack,
    String? error,
    bool? isApplying,
  }) =>
      EditorState(
        document: document ?? this.document,
        undoStack: undoStack ?? this.undoStack,
        redoStack: redoStack ?? this.redoStack,
        error: error,
        isApplying: isApplying ?? this.isApplying,
      );
}

class EditorController extends AutoDisposeNotifier<EditorState> {
  @override
  EditorState build() => EditorState();

  void setDocument(PdfDocument doc) {
    state = state.copyWith(document: doc);
  }

  Future<void> apply(EditAction action) async {
    final PdfDocument? current = state.document;
    if (current == null) return;

    state = state.copyWith(isApplying: true, error: null);
    final repo = await ref.read(editorRepositoryProvider.future);
    final Result<PdfDocument> r = await repo.apply(current, action);

    r.fold(
      (PdfDocument updated) {
        final Queue<EditAction> undo = Queue<EditAction>.of(state.undoStack)
          ..addLast(action);
        // Cap undo stack — drop oldest if over limit.
        while (undo.length > AppConstants.undoRedoStackSize) {
          undo.removeFirst();
        }
        // Any new edit invalidates the redo branch.
        state = state.copyWith(
          document: updated,
          undoStack: undo,
          redoStack: Queue<EditAction>(),
          isApplying: false,
        );
      },
      (failure) => state = state.copyWith(
        isApplying: false,
        error: failure.message,
      ),
    );
  }

  Future<void> undo() async {
    if (!state.canUndo || state.document == null) return;
    final EditAction action = state.undoStack.last;
    final repo = await ref.read(editorRepositoryProvider.future);
    final Result<PdfDocument> r = await repo.undo(state.document!, action);
    r.fold(
      (PdfDocument updated) {
        final Queue<EditAction> undo = Queue<EditAction>.of(state.undoStack)
          ..removeLast();
        final Queue<EditAction> redo = Queue<EditAction>.of(state.redoStack)
          ..addLast(action);
        state = state.copyWith(
          document: updated,
          undoStack: undo,
          redoStack: redo,
        );
      },
      (failure) => state = state.copyWith(error: failure.message),
    );
  }

  Future<void> redo() async {
    if (!state.canRedo) return;
    final EditAction action = state.redoStack.last;
    await apply(action);
    // `apply` clears redoStack — re-pop manually.
    final Queue<EditAction> redo = Queue<EditAction>.of(state.redoStack);
    if (redo.isNotEmpty) redo.removeLast();
    state = state.copyWith(redoStack: redo);
  }
}

final AutoDisposeNotifierProvider<EditorController, EditorState>
    editorControllerProvider =
    AutoDisposeNotifierProvider<EditorController, EditorState>(
        EditorController.new,);
