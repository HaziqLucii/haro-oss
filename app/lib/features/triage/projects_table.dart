import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../data/workspace_store.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../settings/controls/select.dart';
import '../settings/controls/toggle.dart';
import '../settings/settings_controller.dart' show baseBranchChoices;
import 'pull_status.dart';

/// Newest automatic-sync result per project (`GET /projects/{id}/sync`): a read of what the
/// background poll last found, with no git call.
final projectSyncProvider = FutureProvider.autoDispose
    .family<ProjectSync?, String>((ref, projectId) async {
      try {
        return await ref.watch(haroApiProvider).projectSyncStatus(projectId);
      } catch (_) {
        return null;
      }
    });

/// Branches a project can follow: what `GET /projects/{id}/branches` lists after its own
/// fetch. Kept for a minute so a dashboard revisit does not fetch again.
final projectBranchesProvider = FutureProvider.autoDispose
    .family<List<String>, String>((ref, projectId) async {
      final link = ref.keepAlive();
      final timer = Timer(const Duration(seconds: 60), link.close);
      ref.onDispose(timer.cancel);
      try {
        return (await ref.watch(haroApiProvider).listBranches(projectId))
            .branches;
      } catch (_) {
        return const [];
      }
    });

const _branchWidth = 150.0;
const _statusWidth = 168.0;
const _autoWidth = 56.0;
const _buttonWidth = 96.0;

/// One row per project: the branch its checkout follows, how it stands against origin, the
/// auto pull switch, and a button that pulls right now whatever the switch says.
class ProjectsTable extends ConsumerStatefulWidget {
  const ProjectsTable({super.key, required this.projects});

  final List<Project> projects;

  @override
  ConsumerState<ProjectsTable> createState() => _ProjectsTableState();
}

class _ProjectsTableState extends ConsumerState<ProjectsTable> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // The backend polls every two minutes; this only re-reads its last answer.
    _poll = Timer.periodic(const Duration(seconds: 60), (_) {
      for (final p in widget.projects) {
        ref.invalidate(projectSyncProvider(p.id));
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const _ColumnLabels(),
      for (final p in widget.projects)
        _ProjectRow(key: ValueKey('project-row-${p.id}'), project: p),
    ],
  );
}

class _ColumnLabels extends StatelessWidget {
  const _ColumnLabels();

  @override
  Widget build(BuildContext context) {
    final style = HaroText.mono(size: 10, color: HaroTokens.ink42);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Text('PROJECT', style: style)),
          SizedBox(
            width: _branchWidth,
            child: Text('PULL BRANCH', style: style),
          ),
          SizedBox(
            width: _statusWidth,
            child: Text('STATUS', style: style),
          ),
          SizedBox(
            width: _autoWidth,
            child: Text('AUTO', style: style, textAlign: TextAlign.center),
          ),
          const SizedBox(width: _buttonWidth + 12),
        ],
      ),
    );
  }
}

class _ProjectRow extends ConsumerStatefulWidget {
  const _ProjectRow({super.key, required this.project});

  final Project project;

  @override
  ConsumerState<_ProjectRow> createState() => _ProjectRowState();
}

class _ProjectRowState extends ConsumerState<_ProjectRow> {
  bool _pulling = false;
  String? _error;

  Project get _p => widget.project;
  bool get _linked => _p.remoteUrl != null;

  Future<void> _setBranch(String branch) => _run(
    () => ref.read(haroApiProvider).setPullSettings(_p.id, pullBranch: branch),
  );

  Future<void> _setAuto(bool on) => _run(
    () => ref.read(haroApiProvider).setPullSettings(_p.id, autoPull: on),
  );

  Future<void> _pullNow() async {
    setState(() {
      _pulling = true;
      _error = null;
    });
    try {
      await ref.read(haroApiProvider).syncProject(_p.id);
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      ref.invalidate(projectSyncProvider(_p.id));
      if (mounted) setState(() => _pulling = false);
    }
  }

  String _message(Object e) =>
      e is HaroApiException ? e.message : 'Could not reach the backend.';

  Future<void> _run(Future<Object?> Function() save) async {
    setState(() => _error = null);
    try {
      await save();
      await ref.read(workspaceStoreProvider.notifier).reload();
      ref.invalidate(projectSyncProvider(_p.id));
    } catch (e) {
      if (mounted) {
        setState(() => _error = _message(e));
      }
    }
  }

  List<(String, String)> _branchOptions() {
    final raw = _linked
        ? ref.watch(projectBranchesProvider(_p.id)).value ?? const <String>[]
        : const <String>[];
    return [
      ('', 'default · ${_p.defaultBranch}'),
      for (final b in baseBranchChoices(raw, _p.pullBranch)) (b, b),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(projectSyncProvider(_p.id)).value;
    final status = pullStatus(_p, sync);
    final statusColor = switch (status.tone) {
      PullTone.ok => HaroTokens.ink66,
      PullTone.note => HaroTokens.ink42,
      PullTone.fail => HaroTokens.fail,
    };
    final text = Text(
      status.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: HaroText.ui(size: 13, color: statusColor),
    );
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: HaroTokens.line08)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HaroText.ui(size: 14),
                ),
              ),
              SizedBox(
                width: _branchWidth,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Opacity(
                    opacity: _linked ? 1 : .4,
                    child: SettingSelect<String>(
                      key: ValueKey('pull-branch-${_p.id}'),
                      minWidth: _branchWidth - 12,
                      value: _p.pullBranch,
                      options: _branchOptions(),
                      onChanged: _linked ? _setBranch : null,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: _statusWidth,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: status.detail == null
                      ? text
                      : Tooltip(message: status.detail!, child: text),
                ),
              ),
              SizedBox(
                width: _autoWidth,
                child: Center(
                  child: SettingToggle(
                    key: ValueKey('auto-pull-${_p.id}'),
                    value: _linked && _p.autoPull,
                    semanticLabel: 'Auto pull ${_p.name}',
                    onChanged: _linked ? _setAuto : null,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: _buttonWidth,
                child: HaroButton(
                  key: ValueKey('pull-now-${_p.id}'),
                  label: _pulling ? 'Pulling…' : 'Pull now',
                  height: 28,
                  fontSize: 12,
                  spread: true,
                  onPressed: _linked && !_pulling ? _pullNow : null,
                ),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _error!,
                key: ValueKey('pull-error-${_p.id}'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: HaroText.ui(size: 12, color: HaroTokens.fail),
              ),
            ),
        ],
      ),
    );
  }
}
