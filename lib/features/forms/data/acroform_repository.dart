// SPDX-License-Identifier: AGPL-3.0
//
// AcroFormRepository — Spike D.
//
// Replaces the previous "draw graphics on top of the page" form-fill
// path with TRUE AcroForm field writes via syncfusion_flutter_pdf.
// Result: machine-readable PDFs that downstream systems
// (HR onboarding, tax software, bank KYC pipelines) can actually
// parse — not just images of filled forms.
//
// Surface:
//
//   • detect(pdfPath)               → List<AcroField> describing every
//                                     fillable field in the document
//   • fill(pdfPath, values)         → writes the {fieldName: value}
//                                     map back onto the file in-place
//   • flatten(pdfPath)              → makes the field values
//                                     uneditable by future viewers
//                                     (one-way; call this only after
//                                     the user signs/submits)
//
// Field-type coverage:
//   • Text  (PdfTextBoxField)
//   • Checkbox (PdfCheckBoxField)
//   • Radio button (PdfRadioButtonListField — group)
//   • Combo box (PdfComboBoxField)
//   • List box (PdfListBoxField)
//   • Signature field (PdfSignatureField) — captured by the existing
//     signature pipeline; we only mark the field as "filled" here.
//
// Unsupported (deferred): annotation widgets that exist but aren't
// strictly form fields (e.g., free-text Comments). Those continue to
// flow through annotation_repository_impl.dart.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import '../../../core/utils/logger.dart';
import '../../sync/data/auto_sync_service.dart';

/// Field-type discriminator. The UI uses this to render the right
/// widget (single-line text vs. dropdown vs. checkbox tile) over the
/// page in the overlay layer.
enum AcroFieldType { text, checkbox, radio, comboBox, listBox, signature, unknown }

class AcroField {
  const AcroField({
    required this.name,
    required this.type,
    required this.pageIndex,
    required this.bounds,
    this.value,
    this.options = const [],
    this.isRequired = false,
    this.isReadOnly = false,
  });

  /// PDF-internal field name. Use as the map key in [fill].
  final String name;
  final AcroFieldType type;
  final int pageIndex;

  /// Page-coordinate bounding box: left, top, width, height in
  /// PDF points (1/72 in). Use to position the overlay widget.
  final ({double x, double y, double w, double h}) bounds;

  /// Current value as a string. For checkboxes "true"/"false". For
  /// radios / combos / lists, the export value of the selected item.
  /// Null when the field hasn't been filled yet.
  final String? value;

  /// For radio / combo / list — the choices the user can pick from.
  /// Pair = (exportValue, displayLabel).
  final List<({String value, String label})> options;

  final bool isRequired;
  final bool isReadOnly;
}

class AcroFormRepository {
  AcroFormRepository({AutoSyncService? autoSync}) : _autoSync = autoSync;

  /// Spike F — debounced cloud auto-upload after fill() / flatten().
  /// No-op when the user hasn't opted in OR the caller didn't pass a
  /// documentId. Mirrors the AnnotationRepository / SignatureRepository
  /// wiring so every save site behaves the same way.
  final AutoSyncService? _autoSync;

  /// Returns every fillable field in the PDF. Empty list when the PDF
  /// is plain (no AcroForm) — callers should fall back to the manual
  /// annotation path (ink overlay) in that case.
  Future<List<AcroField>> detect(String pdfPath) async {
    final bytes = await File(pdfPath).readAsBytes();
    final pdf = sf.PdfDocument(inputBytes: bytes);
    try {
      final form = pdf.form;
      final out = <AcroField>[];
      for (var i = 0; i < form.fields.count; i++) {
        final f = form.fields[i];
        out.add(_describe(f, pdf));
      }
      return out;
    } finally {
      pdf.dispose();
    }
  }

  /// Writes [values] back to the named fields. Keys that don't match
  /// any field are ignored (with a warning log). For checkboxes pass
  /// "true"/"false" strings; for radios/combos/lists pass the export
  /// value of the desired option.
  ///
  /// Pass [documentId] when the file corresponds to a row in the
  /// PdfDocuments table — that lets Spike F's AutoSyncService queue
  /// a cloud upload after the save. Anonymous fills (e.g., a one-off
  /// share-and-discard flow) leave [documentId] null and skip the
  /// upload trigger.
  Future<void> fill(
    String pdfPath,
    Map<String, String> values, {
    String? documentId,
  }) async {
    final bytes = await File(pdfPath).readAsBytes();
    final pdf = sf.PdfDocument(inputBytes: bytes);
    try {
      final form = pdf.form;
      final knownNames = <String>{};
      for (var i = 0; i < form.fields.count; i++) {
        knownNames.add(form.fields[i].name ?? '');
      }
      for (final entry in values.entries) {
        final field = _fieldByName(form, entry.key);
        if (field == null) {
          appLogger.w('AcroForm: no field named "${entry.key}" in $pdfPath');
          continue;
        }
        _applyValue(field, entry.value);
      }
      // Mark as not flattened — fill() preserves editability. Use
      // flatten() to lock the values.
      form.setDefaultAppearance(false);
      final out = await pdf.save();
      await File(pdfPath).writeAsBytes(out);
      _afterSave(documentId); // Spike F — queue cloud upload
    } finally {
      pdf.dispose();
    }
  }

  /// One-way: makes the form fields uneditable in any future viewer.
  /// Useful right before generating a final signed PDF so a recipient
  /// can't tamper with the answers.
  Future<void> flatten(String pdfPath, {String? documentId}) async {
    final bytes = await File(pdfPath).readAsBytes();
    final pdf = sf.PdfDocument(inputBytes: bytes);
    try {
      pdf.form.flattenAllFields();
      final out = await pdf.save();
      await File(pdfPath).writeAsBytes(out);
      _afterSave(documentId); // Spike F — queue cloud upload
    } finally {
      pdf.dispose();
    }
  }

  /// Single hook called from every save site. Idempotent when
  /// AutoSync is disabled or the doc id is empty/null.
  void _afterSave(String? documentId) {
    if (documentId == null || documentId.isEmpty) return;
    // ignore: discarded_futures
    _autoSync?.triggerForDocument(documentId);
  }

  // ── helpers ────────────────────────────────────────────────────────────

  // NOTE 2026-06-10: syncfusion_flutter_pdf (33.x) does not expose the
  // AcroForm "required" (/Ff bit 2) flag on PdfField — unlike the .NET
  // API. AcroField.isRequired therefore stays at its `false` default;
  // the fill UI treats every field as optional. Revisit if Syncfusion
  // adds the getter.
  AcroField _describe(sf.PdfField f, sf.PdfDocument pdf) {
    final pageIndex = _pageIndexOf(f, pdf);
    final r = f.bounds;
    final bounds = (x: r.left, y: r.top, w: r.width, h: r.height);
    if (f is sf.PdfTextBoxField) {
      return AcroField(
        name: f.name ?? '',
        type: AcroFieldType.text,
        pageIndex: pageIndex,
        bounds: bounds,
        value: f.text,
        isReadOnly: f.readOnly,
      );
    }
    if (f is sf.PdfCheckBoxField) {
      return AcroField(
        name: f.name ?? '',
        type: AcroFieldType.checkbox,
        pageIndex: pageIndex,
        bounds: bounds,
        value: f.isChecked ? 'true' : 'false',
        isReadOnly: f.readOnly,
      );
    }
    if (f is sf.PdfRadioButtonListField) {
      final opts = <({String value, String label})>[];
      for (var i = 0; i < f.items.count; i++) {
        final item = f.items[i];
        final v = item.value;
        opts.add((value: v, label: v));
      }
      return AcroField(
        name: f.name ?? '',
        type: AcroFieldType.radio,
        pageIndex: pageIndex,
        bounds: bounds,
        value: f.selectedValue,
        options: opts,
        isReadOnly: f.readOnly,
      );
    }
    if (f is sf.PdfComboBoxField) {
      final opts = <({String value, String label})>[];
      for (var i = 0; i < f.items.count; i++) {
        final item = f.items[i];
        opts.add((value: item.value, label: item.text));
      }
      return AcroField(
        name: f.name ?? '',
        type: AcroFieldType.comboBox,
        pageIndex: pageIndex,
        bounds: bounds,
        value: f.selectedValue,
        options: opts,
        isReadOnly: f.readOnly,
      );
    }
    if (f is sf.PdfListBoxField) {
      final opts = <({String value, String label})>[];
      for (var i = 0; i < f.items.count; i++) {
        final item = f.items[i];
        opts.add((value: item.value, label: item.text));
      }
      return AcroField(
        name: f.name ?? '',
        type: AcroFieldType.listBox,
        pageIndex: pageIndex,
        bounds: bounds,
        value: f.selectedValues.isNotEmpty ? f.selectedValues.first : null,
        options: opts,
        isReadOnly: f.readOnly,
      );
    }
    if (f is sf.PdfSignatureField) {
      return AcroField(
        name: f.name ?? '',
        type: AcroFieldType.signature,
        pageIndex: pageIndex,
        bounds: bounds,
        value: f.signature == null ? null : 'signed',
        isReadOnly: f.readOnly,
      );
    }
    return AcroField(
      name: f.name ?? '',
      type: AcroFieldType.unknown,
      pageIndex: pageIndex,
      bounds: bounds,
    );
  }

  void _applyValue(sf.PdfField field, String v) {
    if (field is sf.PdfTextBoxField) {
      field.text = v;
    } else if (field is sf.PdfCheckBoxField) {
      field.isChecked = v.toLowerCase() == 'true' || v == '1';
    } else if (field is sf.PdfRadioButtonListField) {
      field.selectedValue = v;
    } else if (field is sf.PdfComboBoxField) {
      field.selectedValue = v;
    } else if (field is sf.PdfListBoxField) {
      field.selectedValues = <String>[v];
    }
    // Signature fields are filled by the existing signing pipeline
    // (signature_repository.dart). We intentionally don't write into
    // them here — handing that to a "fill" call would skip the
    // cryptographic chain.
  }

  sf.PdfField? _fieldByName(sf.PdfForm form, String name) {
    for (var i = 0; i < form.fields.count; i++) {
      if (form.fields[i].name == name) return form.fields[i];
    }
    return null;
  }

  int _pageIndexOf(sf.PdfField f, sf.PdfDocument pdf) {
    final page = f.page;
    if (page == null) return 0;
    for (var i = 0; i < pdf.pages.count; i++) {
      if (identical(pdf.pages[i], page)) return i;
    }
    return 0;
  }
}

/// Riverpod provider — wires the AutoSync service so fill()/flatten()
/// trigger the cloud-upload pipeline when the user has opted in. Read
/// from the AcroForm UI overlay widget once that lands.
final acroFormRepositoryProvider = Provider<AcroFormRepository>((ref) {
  return AcroFormRepository(
    autoSync: ref.watch(autoSyncServiceProvider),
  );
});
