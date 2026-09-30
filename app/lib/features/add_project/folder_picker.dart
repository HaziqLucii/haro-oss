import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/haro_api.dart';
import '../../api/models/models.dart';
import '../../data/workspace_store.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_text_field.dart';
import '../new_workspace/creation_widgets.dart';

enum FolderPickerMode {
  /// Pick a git repo to add. Only repos get an action.
  project,

  /// Pick any folder as a location; the footer selects the current one and new folders
  /// can be created in it.
  directory,
}

/// Browses folders through the backend's `/fs` endpoint (confined to its browse root), the
/// same way `FolderPicker.tsx` does. No native file dialog: none is available without a
/// new package, and the backend may not be on this machine.
class FolderPicker extends ConsumerStatefulWidget {
  const FolderPicker({
    super.key,
    required this.mode,
    required this.title,
    required this.onPick,
    required this.onBack,
    this.startPath,
    this.error,
  });

  final FolderPickerMode mode;
  final String title;

  /// Called with the chosen folder's path.
  final ValueChanged<String> onPick;
  final VoidCallback onBack;
  final String? startPath;

  /// Failure of whatever the parent did with the picked folder, shown in the footer.
  final String? error;

  @override
  ConsumerState<FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends ConsumerState<FolderPicker> {
  final _newName = TextEditingController();
  FsListing? _listing;
  bool _loading = true;
  bool _creating = false;
  String? _error;

  bool get _dirMode => widget.mode == FolderPickerMode.directory;
  HaroApi get _api => ref.read(haroApiProvider);

  @override
  void initState() {
    super.initState();
    _go(widget.startPath);
  }

  @override
  void dispose() {
    _newName.dispose();
    super.dispose();
  }

  Future<void> _go(String? path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final l = await _api.browseFs(path);
      if (!mounted) return;
      setState(() => _listing = l);
    } on HaroApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createFolder() async {
    final name = _newName.text.trim();
    final at = _listing;
    if (name.isEmpty || at == null || _creating) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      await _api.mkdirFs(at.path, name);
      _newName.clear();
      await _go(at.path);
    } on HaroApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _listing;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 14),
          child: Row(
            children: [
              HaroButton(
                key: const Key('fp-back'),
                width: CreationMetrics.closeSize,
                height: CreationMetrics.closeSize,
                padding: EdgeInsets.zero,
                label: 'Back',
                tooltip: 'Back',
                onPressed: widget.onBack,
                child: const Center(child: Text('←')),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HaroText.ui(size: 20, weight: FontWeight.w500),
                ),
              ),
              const OverlayCloseButton(),
            ],
          ),
        ),
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 28),
          decoration: const BoxDecoration(
            border: Border.symmetric(
              horizontal: BorderSide(color: HaroTokens.line12),
            ),
          ),
          child: Row(
            children: [
              HaroButton(
                key: const Key('fp-up'),
                label: 'Up',
                tooltip: 'Up one folder',
                variant: HaroButtonVariant.tertiary,
                height: 28,
                padding: const EdgeInsets.only(right: 12),
                onPressed: l?.parent == null ? null : () => _go(l!.parent),
                child: const Text('↑'),
              ),
              Expanded(
                child: Text(
                  l?.path ?? '…',
                  key: const Key('fp-path'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HaroText.mono(
                    size: 12,
                    tracking: 0,
                    color: HaroTokens.ink66,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 280, child: _list(l)),
        if (_dirMode)
          Container(
            padding: const EdgeInsets.fromLTRB(28, 10, 28, 10),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: HaroTokens.line08)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: HaroTextField(
                    key: const Key('fp-newname'),
                    controller: _newName,
                    mono: true,
                    hintText: 'new-folder-name',
                    enabled: l != null && !_creating,
                    onSubmitted: (_) => _createFolder(),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                HaroButton(
                  key: const Key('fp-mkdir'),
                  label: _creating ? 'Creating…' : 'New folder',
                  onPressed: _newName.text.trim().isEmpty || _creating
                      ? null
                      : _createFolder,
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: HaroTokens.line12)),
          ),
          child: Row(
            children: [
              Expanded(child: _footerText(l)),
              if (_dirMode)
                HaroButton(
                  key: const Key('fp-use'),
                  label: 'Use this folder',
                  variant: HaroButtonVariant.primary,
                  onPressed: l == null ? null : () => widget.onPick(l.path),
                )
              else if (l != null && l.isGitRepo)
                HaroButton(
                  key: const Key('fp-add-here'),
                  label: 'Add this folder',
                  variant: HaroButtonVariant.primary,
                  onPressed: () => widget.onPick(l.path),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _footerText(FsListing? l) {
    final String text;
    final shown = widget.error ?? (l != null ? _error : null);
    if (shown != null) {
      return ErrorLine(shown);
    } else if (_dirMode) {
      text = 'Pick where the folder goes.';
    } else if (l == null) {
      text = 'Loading…';
    } else if (l.isGitRepo) {
      text = 'This folder is a git repository.';
    } else {
      text = 'Not a git repository. Open one, or start a new project.';
    }
    return Text(text, style: HaroText.ui(size: 12.5, color: HaroTokens.ink42));
  }

  Widget _list(FsListing? l) {
    if (_loading && l == null) return const _Message('Loading…');
    if (_error != null && l == null) return _Message(_error!, error: true);
    if (l == null) return const SizedBox.shrink();
    if (l.entries.isEmpty) return const _Message('No sub-folders here.');
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      itemCount: l.entries.length,
      itemBuilder: (context, i) => _Row(
        entry: l.entries[i],
        showAdd: !_dirMode && l.entries[i].isGitRepo,
        onOpen: () => _go(l.entries[i].path),
        onAdd: () => widget.onPick(l.entries[i].path),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      text,
      style: HaroText.ui(
        size: 13,
        color: error ? HaroTokens.fail : HaroTokens.ink42,
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({
    required this.entry,
    required this.showAdd,
    required this.onOpen,
    required this.onAdd,
  });

  final FsEntry entry;
  final bool showAdd;
  final VoidCallback onOpen;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 34,
    child: Row(
      children: [
        Expanded(
          child: HaroPressable(
            onTap: onOpen,
            semanticLabel: entry.name,
            builder: (context, hovered) => AnimatedContainer(
              duration: HaroTokens.fadeFast,
              curve: HaroTokens.curve,
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: hovered ? HaroTokens.raised : HaroTokens.transparent,
                borderRadius: BorderRadius.circular(HaroTokens.radius),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HaroText.ui(size: 14, color: HaroTokens.ink86),
                    ),
                  ),
                  if (entry.isGitRepo)
                    Text(
                      'GIT REPO',
                      style: HaroText.mono(
                        size: 10,
                        tracking: .14,
                        color: HaroTokens.ink42,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (showAdd) ...[
          const SizedBox(width: 8),
          HaroButton(
            key: Key('fp-add-${entry.name}'),
            label: 'Add',
            height: 26,
            onPressed: onAdd,
          ),
        ],
      ],
    ),
  );
}
