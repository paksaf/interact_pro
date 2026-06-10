import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/stamp.dart';

/// Bottom sheet that lets the user pick a [Stamp] to apply: predefined
/// catalog, custom text, image, or a dynamic stamp with placeholders.
/// Returns the chosen [Stamp] (or null on cancel) so the viewer can
/// drop into placement mode against the live PDF.
class StampPickerSheet extends ConsumerStatefulWidget {
  const StampPickerSheet({super.key});

  @override
  ConsumerState<StampPickerSheet> createState() => _StampPickerSheetState();
}

class _StampPickerSheetState extends ConsumerState<StampPickerSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  // Custom-text tab state.
  final _textCtrl = TextEditingController(text: 'APPROVED');
  Color _customColor = const Color(0xFFB71C1C);
  double _customOpacity = 1.0;
  bool _includeDate = false;
  bool _includeTime = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  void _pickPredefined(Stamp s) => Navigator.of(context).pop(s);

  void _pickCustom() {
    final raw = _textCtrl.text.trim();
    if (raw.isEmpty) return;
    final dynFields = <DynamicStampField>[
      if (_includeDate) DynamicStampField.date,
      if (_includeTime) DynamicStampField.time,
    ];
    var text = raw;
    if (_includeDate && !text.contains('{date}')) text = '$text · {date}';
    if (_includeTime && !text.contains('{time}')) text = '$text · {time}';
    Navigator.of(context).pop(Stamp(
      id: 'custom-${DateTime.now().millisecondsSinceEpoch}',
      kind: dynFields.isEmpty
          ? StampKind.customText
          : StampKind.dynamic_,
      text: text,
      dynamicFields: dynFields,
      color: _customColor,
      opacity: _customOpacity,
    ),);
  }

  Future<void> _pickImage() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    Navigator.of(context).pop(Stamp(
      id: 'image-${DateTime.now().millisecondsSinceEpoch}',
      kind: StampKind.image,
      text: '',
      dynamicFields: const [],
      color: const Color(0xFF000000),
      opacity: _customOpacity,
      imagePath: path,
    ),);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 520,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    const Icon(Icons.approval_outlined),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Pick a stamp',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              TabBar(
                controller: _tabs,
                tabs: const [
                  Tab(text: 'Predefined'),
                  Tab(text: 'Custom'),
                  Tab(text: 'Image'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    _buildPredefined(),
                    _buildCustom(),
                    _buildImage(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPredefined() {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 2.6,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: PredefinedStamps.all.length,
      itemBuilder: (_, i) {
        final s = PredefinedStamps.all[i];
        return _StampPreview(
          stamp: s,
          onTap: () => _pickPredefined(s),
        );
      },
    );
  }

  Widget _buildCustom() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _textCtrl,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Stamp text',
            hintText: 'e.g. APPROVED, REVIEWED, PAID',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        const Text('Colour', style: TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: const [
            Color(0xFFB71C1C), // red
            Color(0xFF1B5E20), // green
            Color(0xFF0D47A1), // blue
            Color(0xFFE65100), // orange
            Color(0xFF424242), // dark grey
            Color(0xFF4A148C), // purple
          ]
              .map((c) => GestureDetector(
                    onTap: () => setState(() => _customColor = c),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _customColor == c
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                          width: 3,
                        ),
                      ),
                    ),
                  ),)
              .toList(),
        ),
        const SizedBox(height: 16),
        const Text('Opacity', style: TextStyle(fontWeight: FontWeight.w500)),
        Slider(
          value: _customOpacity,
          min: 0.2,
          max: 1.0,
          divisions: 8,
          label: '${(_customOpacity * 100).round()}%',
          onChanged: (v) => setState(() => _customOpacity = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Include today\'s date'),
          subtitle: const Text('Substitutes {date} at place time'),
          value: _includeDate,
          onChanged: (v) => setState(() => _includeDate = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Include current time'),
          value: _includeTime,
          onChanged: (v) => setState(() => _includeTime = v),
        ),
        const SizedBox(height: 16),
        // Live preview rendered the same way the PDF will look.
        Center(
          child: _StampPreviewBox(
            text: _textCtrl.text.isEmpty ? 'PREVIEW' : _textCtrl.text,
            color: _customColor,
            opacity: _customOpacity,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _pickCustom,
          icon: const Icon(Icons.check),
          label: const Text('Use this stamp'),
        ),
      ],
    );
  }

  Widget _buildImage() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Pick a PNG or JPEG to use as a stamp. Transparent backgrounds '
            'work best — the file is drawn as-is on top of the page.',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 16),
          const Text('Opacity', style: TextStyle(fontWeight: FontWeight.w500)),
          Slider(
            value: _customOpacity,
            min: 0.2,
            max: 1.0,
            divisions: 8,
            label: '${(_customOpacity * 100).round()}%',
            onChanged: (v) => setState(() => _customOpacity = v),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _pickImage,
            icon: const Icon(Icons.image_outlined),
            label: const Text('Choose image'),
          ),
        ],
      ),
    );
  }
}

class _StampPreview extends StatelessWidget {
  const _StampPreview({required this.stamp, required this.onTap});
  final Stamp stamp;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: _StampPreviewBox(
        text: stamp.text,
        color: stamp.color,
        opacity: stamp.opacity,
      ),
    );
  }
}

class _StampPreviewBox extends StatelessWidget {
  const _StampPreviewBox({
    required this.text,
    required this.color,
    required this.opacity,
  });
  final String text;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 3),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 18,
              letterSpacing: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}
