import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/conversion.dart';

/// Converts values between units across nine categories.
///
/// Layout: horizontal-scroll category chips at the top → from-unit
/// dropdown + value input → swap button → to-unit dropdown + live
/// result. Result auto-recomputes on every keystroke and on every
/// dropdown change. Long-press the result to copy to clipboard.
class UnitConverterScreen extends StatefulWidget {
  const UnitConverterScreen({super.key});

  @override
  State<UnitConverterScreen> createState() => _UnitConverterScreenState();
}

class _UnitConverterScreenState extends State<UnitConverterScreen> {
  late ConversionCategory _category;
  late Unit _from;
  late Unit _to;
  final _valueCtrl = TextEditingController(text: '1');

  @override
  void initState() {
    super.initState();
    _category = Converters.all.first;
    _from = _category.units.first;
    _to = _category.units.length > 1 ? _category.units[1] : _category.units.first;
  }

  @override
  void dispose() {
    _valueCtrl.dispose();
    super.dispose();
  }

  void _selectCategory(ConversionCategory c) {
    setState(() {
      _category = c;
      _from = c.units.first;
      _to = c.units.length > 1 ? c.units[1] : c.units.first;
    });
  }

  void _swap() {
    setState(() {
      final t = _from;
      _from = _to;
      _to = t;
    });
  }

  double? _parseInput() {
    final raw = _valueCtrl.text.trim();
    if (raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  String _formatResult(double v) {
    if (v.isInfinite || v.isNaN) return '—';
    final abs = v.abs();
    // Use scientific notation only for very small/large numbers, otherwise
    // round to a sensible precision based on magnitude.
    if (abs != 0 && (abs < 1e-4 || abs >= 1e15)) {
      return v.toStringAsExponential(6);
    }
    final precision = abs >= 100
        ? 4
        : abs >= 1
            ? 6
            : 8;
    var formatted = v.toStringAsFixed(precision);
    // Strip trailing zeros and a dangling decimal point.
    if (formatted.contains('.')) {
      formatted = formatted.replaceFirst(RegExp(r'0+$'), '');
      formatted = formatted.replaceFirst(RegExp(r'\.$'), '');
    }
    return formatted;
  }

  Future<void> _copyResult(String s) async {
    await Clipboard.setData(ClipboardData(text: s));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied: $s')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final value = _parseInput();
    final result = value == null
        ? null
        : convert(value: value, from: _from, to: _to, category: _category);
    final resultText = result == null ? '—' : _formatResult(result);

    return Scaffold(
      appBar: AppBar(title: const Text('Converter')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final c in Converters.all) ...[
                  _CategoryChip(
                    category: c,
                    selected: c.id == _category.id,
                    onTap: () => _selectCategory(c),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          // ── From ────────────────────────────────────────────────────
          _UnitField(
            label: 'From',
            unit: _from,
            units: _category.units,
            onUnitChanged: (u) => setState(() => _from = u ?? _from),
            valueController: _valueCtrl,
            onValueChanged: () => setState(() {}),
          ),
          const SizedBox(height: 8),
          Center(
            child: IconButton.filledTonal(
              icon: const Icon(Icons.swap_vert),
              tooltip: 'Swap from / to',
              onPressed: _swap,
            ),
          ),
          const SizedBox(height: 8),
          // ── To ──────────────────────────────────────────────────────
          _UnitField(
            label: 'To',
            unit: _to,
            units: _category.units,
            onUnitChanged: (u) => setState(() => _to = u ?? _to),
            resultText: resultText,
            onCopyResult: () => _copyResult(resultText),
          ),
          const SizedBox(height: 24),
          // Compact "1 X = Y Z" summary for the current pair.
          _LiveSummary(
            from: _from,
            to: _to,
            category: _category,
          ),
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.category,
    required this.selected,
    required this.onTap,
  });
  final ConversionCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      avatar: Icon(
        category.icon,
        size: 18,
        color: selected
            ? Theme.of(context).colorScheme.onPrimary
            : Theme.of(context).colorScheme.primary,
      ),
      label: Text(category.name),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

/// One row of the converter — label + unit dropdown + value field
/// (or read-only result display, when [resultText] is provided).
class _UnitField extends StatelessWidget {
  const _UnitField({
    required this.label,
    required this.unit,
    required this.units,
    required this.onUnitChanged,
    this.valueController,
    this.onValueChanged,
    this.resultText,
    this.onCopyResult,
  });

  final String label;
  final Unit unit;
  final List<Unit> units;
  final ValueChanged<Unit?> onUnitChanged;
  final TextEditingController? valueController;
  final VoidCallback? onValueChanged;
  final String? resultText;
  final VoidCallback? onCopyResult;

  @override
  Widget build(BuildContext context) {
    final isResult = resultText != null;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            DropdownButtonFormField<Unit>(
              initialValue: unit,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: units
                  .map(
                    (u) => DropdownMenuItem(
                      value: u,
                      child: Text('${u.name} (${u.symbol})'),
                    ),
                  )
                  .toList(),
              onChanged: onUnitChanged,
            ),
            const SizedBox(height: 12),
            if (isResult)
              GestureDetector(
                onLongPress: onCopyResult,
                onTap: onCopyResult,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          '$resultText ${unit.symbol}',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w500,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      Icon(
                        Icons.copy,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              )
            else
              TextField(
                controller: valueController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                inputFormatters: [
                  // Accept digits, one decimal point, leading minus.
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9\.\-]')),
                ],
                style: const TextStyle(
                  fontSize: 24,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixText: unit.symbol,
                ),
                onChanged: (_) => onValueChanged?.call(),
              ),
          ],
        ),
      ),
    );
  }
}

/// "1 m = 100 cm" style summary line under the converter — useful when
/// the user just wants the conversion factor at a glance.
class _LiveSummary extends StatelessWidget {
  const _LiveSummary({
    required this.from,
    required this.to,
    required this.category,
  });
  final Unit from;
  final Unit to;
  final ConversionCategory category;

  @override
  Widget build(BuildContext context) {
    final r = convert(value: 1, from: from, to: to, category: category);
    final s = r.isFinite
        ? r.toStringAsFixed(r.abs() >= 1 ? 4 : 8)
            .replaceFirst(RegExp(r'(\.[0-9]*?)0+$'), r'$1')
            .replaceFirst(RegExp(r'\.$'), '')
        : '—';
    return Center(
      child: Text(
        '1 ${from.symbol} = $s ${to.symbol}',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 13,
        ),
      ),
    );
  }
}
