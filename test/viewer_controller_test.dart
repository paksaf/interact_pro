import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:interact_pro/features/viewer/presentation/providers/viewer_controller.dart';

void main() {
  group('ViewerController', () {
    test('starts with no document and `none` tool', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      final ViewerState state = container.read(viewerControllerProvider);
      expect(state.document, isNull);
      expect(state.tool, ViewerTool.none);
      expect(state.isLoading, isFalse);
    });

    test('setTool updates state', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      container
          .read(viewerControllerProvider.notifier)
          .setTool(ViewerTool.highlight);

      expect(
        container.read(viewerControllerProvider).tool,
        ViewerTool.highlight,
      );
    });
  });
}
