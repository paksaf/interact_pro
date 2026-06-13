import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../../../core/sharing/pro_share.dart';

/// Full-screen image viewer with pinch-zoom + pan + share.
///
/// Used as the auto-open target when a peer pushes an `image/*` payload via
/// `/api/comms/send` style LAN transfers (see `IncomingFileBootstrap`). Also
/// reachable from the share-sheet flow when an external app shares an image
/// into Interact Pro.
///
/// Deliberately minimal — no annotation, no OCR. Those features can hang
/// off the AppBar overflow later. The single job is "show the picture
/// the user just received, big and clean, on a TV or phone."
class ImageViewerScreen extends StatelessWidget {
  const ImageViewerScreen({required this.filePath, super.key});

  final String filePath;

  @override
  Widget build(BuildContext context) {
    final file = File(filePath);
    final exists = file.existsSync();
    final basename = p.basename(filePath);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withOpacity(0.4),
        elevation: 0,
        foregroundColor: Colors.white,
        title: Text(
          basename,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share',
            onPressed: exists ? () => _share(context, file) : null,
          ),
        ],
      ),
      body: exists
          ? _ZoomableImage(file: file)
          : const Center(
              child: Text(
                'Image not found',
                style: TextStyle(color: Colors.white70),
              ),
            ),
    );
  }

  Future<void> _share(BuildContext context, File file) async {
    try {
      // Share the file out to other apps. share_plus 12.x uses XFile.
      await ProShare.files(
        [XFile(file.path)],
        text: p.basename(file.path),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: $e')),
        );
      }
    }
  }
}

/// InteractiveViewer wrapper sized to the image's natural aspect.
///
/// Important behaviours:
///   - boundaryMargin lets the user pan past the image edge during a zoom-in
///     (otherwise rapid two-finger flicks feel sticky on TV form factors).
///   - minScale 0.5 / maxScale 6.0 covers "pinch-out a 12MP photo on a phone"
///     through "pinch-in a 320×240 thumbnail on a TV" without clipping.
///   - on TV, double-tap toggles between fit and 2× zoom — useful when the
///     user is navigating with a remote and can't pinch.
class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage({required this.file});

  final File file;

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage>
    with SingleTickerProviderStateMixin {
  final TransformationController _controller = TransformationController();
  late final AnimationController _animController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Matrix4>? _animation;

  @override
  void dispose() {
    _animController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    final scene = _controller.value;
    final atIdentity = scene.isIdentity();
    final target = atIdentity
        ? (Matrix4.identity()
          ..translate(-details.localPosition.dx, -details.localPosition.dy)
          ..scale(2.0))
        : Matrix4.identity();

    _animation = Matrix4Tween(begin: scene, end: target).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    )..addListener(() {
        _controller.value = _animation!.value;
      });
    _animController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: _handleDoubleTapDown,
      onDoubleTap: () {/* handled in onDoubleTapDown */},
      child: InteractiveViewer(
        transformationController: _controller,
        boundaryMargin: const EdgeInsets.all(80),
        minScale: 0.5,
        maxScale: 6.0,
        child: Center(
          child: Image.file(
            widget.file,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) {
              return const Center(
                child: Icon(Icons.broken_image,
                    color: Colors.white54, size: 64,),
              );
            },
          ),
        ),
      ),
    );
  }
}
