import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../../core/layout/responsive.dart';
import '../../../auth/data/auth_api_client.dart';
import '../../../auth/presentation/providers/auth_provider.dart';

/// Admin panel — visible only to users whose server-side role is `admin`.
/// Today this is a thin scaffold over four `pro.interactpak.com/api/admin`
/// endpoints; the design is deliberately conservative because admin
/// actions are sensitive (they affect every user's billing / access).
///
/// Backend contract:
///
/// `GET  /api/admin/users?cursor=...&query=...`
///   → `200 { users: [{ id, email, phone, displayName, role, planLabel,
///                       proActive, trialEndsAt, createdAt }],
///             nextCursor }`
///   admin-only; 403 for non-admins.
///
/// `POST /api/admin/users/{id}/grant-pro`     body: `{ months: int }`
/// `POST /api/admin/users/{id}/revoke-pro`
/// `POST /api/admin/users/{id}/extend-trial`  body: `{ days: int }`
/// `POST /api/admin/users/{id}/role`          body: `{ role: 'admin'|'user' }`
/// `POST /api/admin/users/{id}/sign-out-everywhere`
///
/// Every endpoint is rate-limited server-side and writes an audit log
/// row including the requesting admin id.
class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  List<_AdminUserRow> _users = [];
  bool _loading = false;
  String _query = '';
  String? _error;

  /// Selected row in tablet master-detail layout. Null = no selection
  /// (detail pane shows an empty placeholder). Phone layout ignores
  /// this — taps push a separate detail screen instead. (Detail screen
  /// not yet built; today the per-row popup menu handles every action.)
  _AdminUserRow? _selectedRow;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await _fetchUsers(query: _query);
    if (!mounted) return;
    if (result.error != null) {
      setState(() {
        _error = result.error;
        _loading = false;
      });
    } else {
      setState(() {
        _users = result.data ?? const [];
        _loading = false;
      });
    }
  }

  Future<({List<_AdminUserRow>? data, String? error})> _act({
    required String url,
    Map<String, dynamic>? body,
  }) async {
    final token = await ref.read(authApiClientProvider).bearerToken();
    if (token == null) {
      return (data: null, error: 'Sign in as admin first.');
    }
    try {
      final resp = await http
          .post(
            Uri.parse(url),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: body == null ? null : jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 403) {
        return (data: null, error: 'Forbidden — admin role required.');
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return (data: null, error: 'Failed (${resp.statusCode})');
      }
      return (data: <_AdminUserRow>[], error: null);
    } catch (e) {
      return (data: null, error: '$e');
    }
  }

  Future<({List<_AdminUserRow>? data, String? error})> _fetchUsers({
    String query = '',
  }) async {
    final auth = ref.read(authApiClientProvider);
    final token = await auth.bearerToken();
    if (token == null) {
      return (data: null, error: 'Sign in first.');
    }
    final uri = Uri.parse(
        '${auth.baseUrl}/api/admin/users?query=${Uri.encodeQueryComponent(query)}',);
    try {
      final resp = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 403) {
        return (data: null, error: 'Forbidden — admin role required.');
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return (data: null, error: 'Failed (${resp.statusCode})');
      }
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final rows = (json['users'] as List<dynamic>)
          .map((e) => _AdminUserRow.fromJson(e as Map<String, dynamic>))
          .toList();
      return (data: rows, error: null);
    } catch (e) {
      return (data: null, error: '$e');
    }
  }

  Future<void> _grantPro(_AdminUserRow row) async {
    final months = await _askMonths();
    if (months == null) return;
    final auth = ref.read(authApiClientProvider);
    final r = await _act(
      url: '${auth.baseUrl}/api/admin/users/${row.id}/grant-pro',
      body: {'months': months},
    );
    if (!mounted) return;
    if (r.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(r.error!)));
      return;
    }
    await _refresh();
  }

  Future<void> _revokePro(_AdminUserRow row) async {
    final auth = ref.read(authApiClientProvider);
    final r = await _act(
      url: '${auth.baseUrl}/api/admin/users/${row.id}/revoke-pro',
    );
    if (!mounted) return;
    if (r.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(r.error!)));
      return;
    }
    await _refresh();
  }

  Future<int?> _askMonths() async {
    final controller = TextEditingController(text: '1');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Grant Pro'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Months',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(
              int.tryParse(controller.text.trim()),
            ),
            child: const Text('Grant'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authUserProvider).asData?.value;
    if (user == null || !user.isAdmin) {
      return const Scaffold(
        body: Center(child: Text('Admin access required.')),
      );
    }
    final isWide = WindowSize.of(context).isTabletOrWider;
    final list = _UserList(
      users: _users,
      loading: _loading,
      error: _error,
      query: _query,
      selectedId: _selectedRow?.id,
      onSearch: (q) {
        _query = q;
        _refresh();
      },
      onSelect: (row) {
        if (isWide) {
          setState(() => _selectedRow = row);
        } else {
          // Phone — until a dedicated detail screen exists, fall back
          // to the existing inline popup actions.
          _showPhoneActions(row);
        }
      },
    );

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Admin'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              // TV remote D-pad lands here on entry — always-present target
              // even when the user list is empty / loading.
              autofocus: true,
              onPressed: _refresh,
            ),
          ],
          // Two-tab pivot — Users (existing scaffold) + Renewals (new
          // pending-trial-renewal-requests pane wired 2026-05-13 as the
          // bridge between trial expiry and Play Store / App Store IAP
          // launch).
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.people_outline), text: 'Users'),
              Tab(icon: Icon(Icons.update), text: 'Renewals'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 360, child: list),
                      VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      Expanded(
                        child: _selectedRow == null
                            ? const _DetailEmpty()
                            : _UserDetail(
                                row: _selectedRow!,
                                onGrantPro: () => _grantPro(_selectedRow!),
                                onRevokePro: () => _revokePro(_selectedRow!),
                              ),
                      ),
                    ],
                  )
                : list,
            const _RenewalsPane(),
          ],
        ),
      ),
    );
  }

  void _showPhoneActions(_AdminUserRow row) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.workspace_premium),
              title: const Text('Grant Pro'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                _grantPro(row);
              },
            ),
            if (row.proActive)
              ListTile(
                leading: const Icon(Icons.lock_open_outlined),
                title: const Text('Revoke Pro'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _revokePro(row);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _UserList extends StatelessWidget {
  const _UserList({
    required this.users,
    required this.loading,
    required this.error,
    required this.query,
    required this.selectedId,
    required this.onSearch,
    required this.onSelect,
  });
  final List<_AdminUserRow> users;
  final bool loading;
  final String? error;
  final String query;
  final String? selectedId;
  final ValueChanged<String> onSearch;
  final ValueChanged<_AdminUserRow> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search by email / phone / id',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: onSearch,
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(error!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error,),),
          ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : ListView.separated(
                  itemCount: users.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final row = users[i];
                    final isSel = row.id == selectedId;
                    return ListTile(
                      selected: isSel,
                      selectedTileColor: Theme.of(context)
                          .colorScheme
                          .primaryContainer
                          .withOpacity(0.4),
                      leading: CircleAvatar(
                        backgroundColor: row.proActive
                            ? Colors.green
                            : Theme.of(context).colorScheme.outline,
                        child: Icon(
                          row.proActive
                              ? Icons.workspace_premium
                              : Icons.person_outline,
                          color: Colors.white,
                        ),
                      ),
                      title: Text(row.displayName),
                      subtitle: Text([
                        if (row.email != null) row.email!,
                        if (row.phone != null) row.phone!,
                        row.planLabel,
                      ].join(' · '),),
                      onTap: () => onSelect(row),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _DetailEmpty extends StatelessWidget {
  const _DetailEmpty();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.person_outline, size: 80, color: cs.outline),
          const SizedBox(height: 12),
          Text('Pick a user to manage them',
              style: TextStyle(color: cs.outline),),
        ],
      ),
    );
  }
}

class _UserDetail extends StatelessWidget {
  const _UserDetail({
    required this.row,
    required this.onGrantPro,
    required this.onRevokePro,
  });
  final _AdminUserRow row;
  final VoidCallback onGrantPro;
  final VoidCallback onRevokePro;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: row.proActive
                    ? Colors.green
                    : Theme.of(context).colorScheme.outline,
                child: Icon(
                  row.proActive
                      ? Icons.workspace_premium
                      : Icons.person_outline,
                  size: 32,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.displayName,
                        style: Theme.of(context).textTheme.headlineSmall,),
                    const SizedBox(height: 4),
                    Text([
                      if (row.email != null) row.email!,
                      if (row.phone != null) row.phone!,
                    ].join(' · '),),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      children: [
                        Chip(
                          label: Text(row.role),
                          visualDensity: VisualDensity.compact,
                        ),
                        Chip(
                          label: Text(row.planLabel),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: onGrantPro,
                icon: const Icon(Icons.workspace_premium),
                label: const Text('Grant Pro'),
              ),
              if (row.proActive)
                OutlinedButton.icon(
                  onPressed: onRevokePro,
                  icon: const Icon(Icons.lock_open_outlined),
                  label: const Text('Revoke Pro'),
                ),
            ],
          ),
          const SizedBox(height: 32),
          Text(
            'User ID: ${row.id}',
            style: TextStyle(
              fontFamily: 'monospace',
              color: Theme.of(context).colorScheme.outline,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminUserRow {
  const _AdminUserRow({
    required this.id,
    required this.email,
    required this.phone,
    required this.displayName,
    required this.role,
    required this.planLabel,
    required this.proActive,
  });
  final String id;
  final String? email;
  final String? phone;
  final String displayName;
  final String role;
  final String planLabel;
  final bool proActive;

  factory _AdminUserRow.fromJson(Map<String, dynamic> j) => _AdminUserRow(
        id: j['id'] as String,
        email: j['email'] as String?,
        phone: j['phone'] as String?,
        displayName: (j['displayName'] as String?) ?? 'User',
        role: (j['role'] as String?) ?? 'user',
        planLabel: (j['planLabel'] as String?) ?? 'Free',
        proActive: (j['proActive'] as bool?) ?? false,
      );
}

// ── Renewals pane ─────────────────────────────────────────────────────
//
// Lists pending trial-renewal requests from users whose 7-day trial
// has lapsed. Each row has Approve (default extend = 30 days, admin
// can tweak) and Decline (optional reason).
//
// Wired 2026-05-13 alongside the user-side "Ask admin" button on the
// trial banner. This is the bridge between trial-end and Play Store
// / App Store IAP launch — once IAP is live we still keep this for
// edge cases (corporate trials, user can't access Play Store, etc.)
// since admin-mediated extension is a useful safety valve.

class _RenewalsPane extends ConsumerStatefulWidget {
  const _RenewalsPane();

  @override
  ConsumerState<_RenewalsPane> createState() => _RenewalsPaneState();
}

class _RenewalsPaneState extends ConsumerState<_RenewalsPane> {
  List<RenewalRequest> _items = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await ref.read(authRepositoryProvider).listPendingRenewals();
    if (!mounted) return;
    res.fold(
      (list) => setState(() {
        _items = list;
        _loading = false;
      }),
      (failure) => setState(() {
        _error = failure.message;
        _loading = false;
      }),
    );
  }

  Future<void> _approve(RenewalRequest r) async {
    final days = await _askForDays();
    if (days == null) return;
    if (!mounted) return;
    final res =
        await ref.read(authRepositoryProvider).approveRenewal(r.id, extendDays: days);
    if (!mounted) return;
    res.fold(
      (_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Renewed ${r.displayName} for $days days.')),
        );
        _refresh();
      },
      (failure) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.message)),
      ),
    );
  }

  Future<void> _decline(RenewalRequest r) async {
    final reason = await _askForReason();
    if (reason == null) return;
    if (!mounted) return;
    final res = await ref
        .read(authRepositoryProvider)
        .declineRenewal(r.id, reason: reason);
    if (!mounted) return;
    res.fold(
      (_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Declined ${r.displayName}.')),
        );
        _refresh();
      },
      (failure) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.message)),
      ),
    );
  }

  Future<int?> _askForDays() async {
    final controller = TextEditingController(text: '30');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Extend trial by'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(suffixText: 'days'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = int.tryParse(controller.text.trim());
              Navigator.of(ctx).pop(parsed);
            },
            child: const Text('Approve'),
          ),
        ],
      ),
    );
  }

  Future<String?> _askForReason() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Decline renewal'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Reason (shown to the user; optional)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Decline'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,),
              const SizedBox(height: 8),
              Text(_error!),
              const SizedBox(height: 12),
              FilledButton(onPressed: _refresh, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox_outlined, size: 48),
              SizedBox(height: 8),
              Text(
                'No pending renewal requests.',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 4),
              Text(
                'When a user\'s trial expires they can tap "Ask admin" '
                'on the trial banner to land here.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _RenewalCard(
          request: _items[i],
          onApprove: () => _approve(_items[i]),
          onDecline: () => _decline(_items[i]),
        ),
      ),
    );
  }
}

class _RenewalCard extends StatelessWidget {
  const _RenewalCard({
    required this.request,
    required this.onApprove,
    required this.onDecline,
  });

  final RenewalRequest request;
  final VoidCallback onApprove;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final contact = request.email ?? request.phone ?? '(no contact)';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              request.displayName,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
            const SizedBox(height: 2),
            Text(
              contact,
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(height: 6),
            Text(
              'Requested ${_relative(request.requestedAt)}'
              '${request.trialEndsAt == null ? '' : ' · trial ended '
                  '${_relative(request.trialEndsAt!)}'}',
              style: const TextStyle(fontSize: 12),
            ),
            if (request.note != null && request.note!.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(request.note!),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onDecline, child: const Text('Decline')),
                const SizedBox(width: 8),
                FilledButton(onPressed: onApprove, child: const Text('Approve')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _relative(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.isNegative) {
      final abs = -diff.inHours;
      if (abs < 24) return 'in ${(-diff.inHours)}h';
      return 'in ${(-diff.inDays)}d';
    }
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
