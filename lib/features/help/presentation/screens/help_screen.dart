// SPDX-License-Identifier: AGPL-3.0
//
// Help — always-accessible feature catalog. Reached from the home
// AppBar's "?" icon. Renders the structured help_content sections as
// expandable cards with steps + remote/touch hints.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/help_content.dart';

class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});
  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  String _query = '';
  late final TextEditingController _searchCtrl;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _matches(HelpItem item) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return item.title.toLowerCase().contains(q) ||
        item.summary.toLowerCase().contains(q) ||
        item.steps.any((s) => s.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final sections = helpSections
        .map((s) => HelpSection(
              title: s.title,
              icon: s.icon,
              items: s.items.where(_matches).toList(),
            ),)
        .where((s) => s.items.isNotEmpty)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Help & guide'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Search help…',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          Expanded(
            child: sections.isEmpty
                ? const Center(child: Text('No help topics match your search.'))
                : ListView.builder(
                    itemCount: sections.length,
                    itemBuilder: (ctx, i) => _SectionTile(section: sections[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({required this.section});
  final HelpSection section;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        elevation: 1,
        child: ExpansionTile(
          initiallyExpanded: true,
          leading: Icon(section.icon, color: Theme.of(context).colorScheme.primary),
          title: Text(section.title, style: const TextStyle(fontWeight: FontWeight.w700)),
          children: section.items.map((it) => _ItemTile(item: it)).toList(),
        ),
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item});
  final HelpItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(item.icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(item.summary, style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...item.steps.asMap().entries.map((e) => Padding(
                  padding: const EdgeInsets.only(left: 28, bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${e.key + 1}.', style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 6),
                      Expanded(child: Text(e.value, style: const TextStyle(fontSize: 13.5, height: 1.35))),
                    ],
                  ),
                ),),
            if (item.remoteHint != null || item.touchHint != null) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (item.remoteHint != null)
                    _Pill(label: 'Remote: ${item.remoteHint!}', icon: Icons.tv_outlined),
                  if (item.touchHint != null)
                    _Pill(label: 'Phone: ${item.touchHint!}',   icon: Icons.smartphone),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.icon});
  final String label;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: theme.colorScheme.onPrimaryContainer),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: theme.colorScheme.onPrimaryContainer, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
