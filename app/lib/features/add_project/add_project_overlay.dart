import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/haro_api.dart';
import '../../data/workspace_store.dart';
import '../../overlays/overlay.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_text_field.dart';
import '../new_workspace/creation_widgets.dart';
import 'clone_path.dart';
import 'clone_runner.dart';
import 'folder_picker.dart';

Future<void> showAddProject(BuildContext context) => showHaroOverlay<void>(
  context,
  width: 560,
  child: const AddProjectOverlay(),
);

enum _Stage { choose, open, clone, create, pickCloneDest, pickCreateParent }

const _rows = [
  (
    stage: _Stage.open,
    title: 'Open a folder on disk',
    detail: 'Any git repo you already have',
  ),
  (
    stage: _Stage.clone,
    title: 'Clone from GitHub',
    detail: 'Paste a URL, or owner/repo',
  ),
  (
    stage: _Stage.create,
    title: 'Start a new project',
    detail: 'Make a folder, git init, optionally link a remote',
  ),
];

/// §6.5. Every path ends at `/first-run?project=<id>` once the project is registered.
///
/// Not built: the "or drop a folder here" zone. Desktop drag-and-drop needs a package
/// (`desktop_drop`) and this build adds none.
class AddProjectOverlay extends ConsumerStatefulWidget {
  const AddProjectOverlay({super.key});

  @override
  ConsumerState<AddProjectOverlay> createState() => _AddProjectOverlayState();
}

class _AddProjectOverlayState extends ConsumerState<AddProjectOverlay> {
  _Stage _stage = _Stage.choose;
  bool _busy = false;
  String? _error;

  final _cloneUrl = TextEditingController();
  final _cloneDest = TextEditingController();
  final _name = TextEditingController();
  final _parent = TextEditingController();
  final _remote = TextEditingController();

  HaroApi get _api => ref.read(haroApiProvider);

  /// The running clone, so closing the overlay or "Cancel clone" can kill git.
  CloneHandle? _handle;

  /// `url` and target of the last clone that finished, so a failed registration retries
  /// without cloning into a folder that is no longer empty.
  String? _clonedKey;

  @override
  void dispose() {
    _handle?.cancel();
    for (final c in [_cloneUrl, _cloneDest, _name, _parent, _remote]) {
      c.dispose();
    }
    super.dispose();
  }

  void _go(_Stage s) {
    setState(() {
      _stage = s;
      _error = null;
    });
    if ((s == _Stage.clone || s == _Stage.create) && _needsRoot(s)) {
      _fillDefaultParent(s);
    }
  }

  bool _needsRoot(_Stage s) =>
      (s == _Stage.clone ? _cloneDest : _parent).text.isEmpty;

  Future<void> _fillDefaultParent(_Stage s) async {
    try {
      final root = (await _api.browseFs()).root;
      if (!mounted) return;
      final c = s == _Stage.clone ? _cloneDest : _parent;
      if (c.text.isEmpty) setState(() => c.text = root);
    } on HaroApiException {
      // The user can still type or browse to a folder.
    }
  }

  String _join(String parent, String name) =>
      '${parent.trim().replaceAll(RegExp(r'/+$'), '')}/$name';

  /// Registers [path] (optionally `git init`), then opens First run for it.
  Future<void> _register(
    String path, {
    String? name,
    bool init = false,
    String? remoteUrl,
    Future<void> Function()? before,
  }) async {
    if (_busy) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final store = ref.read(workspaceStoreProvider.notifier);
    GoRouter? router;
    try {
      router = GoRouter.of(context);
    } catch (_) {
      router = null;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await before?.call();
      if (!mounted) return;
      final p = await _api.createProject(
        path,
        name: name,
        init: init,
        remoteUrl: remoteUrl,
      );
      await store.reload();
      if (!mounted) return;
      navigator.pop();
      router?.go('/first-run?project=${Uri.encodeQueryComponent(p.id)}');
    } on CloneCancelled {
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is HaroApiException ? e.message : e.toString();
      });
    }
  }

  String? _home() => ref.read(homeDirProvider);

  /// The folder git clones into, or null with the reason in [ClonePathException].
  String _cloneTarget(String url) => resolveCloneTarget(
    parent: _cloneDest.text,
    folder: repoFolderName(url),
    home: _home(),
  );

  Future<void> _submitClone() async {
    if (_busy) return;
    final url = normalizeCloneUrl(_cloneUrl.text);
    if (url.isEmpty || _cloneDest.text.trim().isEmpty) return;
    final String dest;
    try {
      dest = _cloneTarget(url);
    } on ClonePathException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    final key = '$url\n$dest';
    if (_clonedKey != key) {
      final state = await ref.read(cloneTargetProbeProvider)(dest);
      if (!mounted) return;
      if (state == TargetState.notEmpty) {
        setState(() => _error = '$dest already exists and is not empty.');
        return;
      }
    }
    await _register(
      dest,
      before: _clonedKey == key
          ? null
          : () async {
              final handle = CloneHandle();
              setState(() => _handle = handle);
              try {
                await ref.read(cloneRunnerProvider)(url, dest, handle);
              } finally {
                if (identical(_handle, handle)) {
                  if (mounted) {
                    setState(() => _handle = null);
                  } else {
                    _handle = null;
                  }
                }
              }
              _clonedKey = key;
            },
    );
  }

  void _cancelClone() => _handle?.cancel();

  static final _unsafe = RegExp(r'[/\\]+');

  String get _folder => _name.text
      .trim()
      .replaceAll(_unsafe, '-')
      .replaceAll(RegExp(r'\s+'), '-');

  void _submitCreate() {
    if (_folder.isEmpty || _parent.text.trim().isEmpty) return;
    _register(
      _join(_parent.text, _folder),
      name: _name.text.trim(),
      init: true,
      remoteUrl: _remote.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) => switch (_stage) {
    _Stage.choose => _choose(),
    _Stage.open => FolderPicker(
      mode: FolderPickerMode.project,
      title: 'Open a folder',
      error: _error,
      onBack: () => _go(_Stage.choose),
      onPick: (path) => _register(path),
    ),
    _Stage.pickCloneDest => FolderPicker(
      mode: FolderPickerMode.directory,
      title: 'Clone into',
      startPath: _cloneDest.text.isEmpty ? null : _cloneDest.text,
      onBack: () => _go(_Stage.clone),
      onPick: (path) {
        _cloneDest.text = path;
        _go(_Stage.clone);
      },
    ),
    _Stage.pickCreateParent => FolderPicker(
      mode: FolderPickerMode.directory,
      title: 'Choose location',
      startPath: _parent.text.isEmpty ? null : _parent.text,
      onBack: () => _go(_Stage.create),
      onPick: (path) {
        _parent.text = path;
        _go(_Stage.create);
      },
    ),
    _Stage.clone => _cloneForm(),
    _Stage.create => _createForm(),
  };

  Widget _header(String title, {VoidCallback? onBack}) => Row(
    children: [
      if (onBack != null) ...[
        HaroButton(
          key: const Key('ap-back'),
          width: CreationMetrics.closeSize,
          height: CreationMetrics.closeSize,
          padding: EdgeInsets.zero,
          label: 'Back',
          tooltip: 'Back',
          onPressed: _busy ? null : onBack,
          child: const Center(child: Text('←')),
        ),
        const SizedBox(width: 14),
      ],
      Expanded(
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: HaroText.ui(size: 22, weight: FontWeight.w500),
        ),
      ),
      const OverlayCloseButton(),
    ],
  );

  Widget _choose() => Padding(
    padding: const EdgeInsets.fromLTRB(28, 24, 28, 26),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header('Add a project'),
        const SizedBox(height: 18),
        Container(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: HaroTokens.line12)),
          ),
          child: Column(
            children: [
              for (final r in _rows)
                _ChoiceRow(row: r, onTap: () => _go(r.stage)),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    bool mono = true,
    VoidCallback? onBrowse,
    bool autofocus = false,
    VoidCallback? onSubmit,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: CreationMetrics.rowGap),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MonoCaption(label),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: HaroTextField(
                controller: controller,
                mono: mono,
                height: 34,
                hintText: hint,
                autofocus: autofocus,
                enabled: !_busy,
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: onSubmit == null ? null : (_) => onSubmit(),
              ),
            ),
            if (onBrowse != null) ...[
              const SizedBox(width: 8),
              HaroButton(
                key: Key(
                  'ap-browse-${label.toLowerCase().replaceAll(' ', '-')}',
                ),
                label: 'Browse…',
                height: 34,
                onPressed: _busy ? null : onBrowse,
              ),
            ],
          ],
        ),
      ],
    ),
  );

  Widget _form({
    required String title,
    required List<Widget> fields,
    required String summary,
    required String action,
    required bool ready,
    required VoidCallback onSubmit,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(title, onBack: () => _go(_Stage.choose)),
            const SizedBox(height: 20),
            ...fields,
            Text(
              summary,
              key: const Key('ap-summary'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: HaroText.mono(
                size: 12,
                tracking: 0,
                color: HaroTokens.ink42,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              ErrorLine(_error!),
            ],
          ],
        ),
      ),
      Container(
        margin: const EdgeInsets.only(top: 22),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: HaroTokens.line12)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (_busy && _handle != null)
              HaroButton(
                key: const Key('ap-cancel-clone'),
                label: 'Cancel clone',
                height: 34,
                variant: HaroButtonVariant.tertiary,
                onPressed: _cancelClone,
              )
            else
              HaroButton(
                label: 'Back',
                height: 34,
                variant: HaroButtonVariant.tertiary,
                onPressed: _busy ? null : () => _go(_Stage.choose),
              ),
            const SizedBox(width: 8),
            HaroButton(
              key: const Key('ap-submit'),
              label: _busy ? '$action…' : action,
              height: 34,
              variant: HaroButtonVariant.primary,
              onPressed: ready && !_busy ? onSubmit : null,
            ),
          ],
        ),
      ),
    ],
  );

  Widget _cloneForm() {
    final url = normalizeCloneUrl(_cloneUrl.text);
    String? target;
    String hint = 'Enter a repository and pick a folder.';
    if (url.isNotEmpty && _cloneDest.text.trim().isNotEmpty) {
      try {
        target = _cloneTarget(url);
        hint = 'Clones to $target';
      } on ClonePathException catch (e) {
        hint = e.message;
      }
    }
    return _form(
      title: 'Clone from GitHub',
      fields: [
        _field(
          'Repository URL',
          _cloneUrl,
          hint: 'https://github.com/owner/repo.git',
          autofocus: true,
          onSubmit: _submitClone,
        ),
        _field(
          'Clone into',
          _cloneDest,
          hint: 'pick a folder…',
          onBrowse: () => _go(_Stage.pickCloneDest),
          onSubmit: _submitClone,
        ),
      ],
      summary: hint,
      action: 'Clone',
      ready: target != null,
      onSubmit: _submitClone,
    );
  }

  Widget _createForm() {
    final ready = _folder.isNotEmpty && _parent.text.trim().isNotEmpty;
    return _form(
      title: 'Start a new project',
      fields: [
        _field(
          'Project name',
          _name,
          hint: 'my-app',
          mono: false,
          autofocus: true,
          onSubmit: _submitCreate,
        ),
        _field(
          'Parent folder',
          _parent,
          hint: 'pick a folder…',
          onBrowse: () => _go(_Stage.pickCreateParent),
          onSubmit: _submitCreate,
        ),
        _field(
          'Git remote (optional)',
          _remote,
          hint: 'https://github.com/you/repo.git',
          onSubmit: _submitCreate,
        ),
      ],
      summary: ready
          ? 'Creates ${_join(_parent.text, _folder)}'
          : 'Enter a name and pick a parent folder.',
      action: 'Create project',
      ready: ready,
      onSubmit: _submitCreate,
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.row, required this.onTap});

  final ({_Stage stage, String title, String detail}) row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: row.title,
    builder: (context, hovered) => AnimatedContainer(
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
      decoration: BoxDecoration(
        color: hovered ? HaroTokens.raised : HaroTokens.transparent,
        border: const Border(bottom: BorderSide(color: HaroTokens.line08)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.title,
                  style: HaroText.ui(size: 15, weight: FontWeight.w500),
                ),
                const SizedBox(height: 3),
                Text(
                  row.detail,
                  style: HaroText.ui(size: 13, color: HaroTokens.ink66),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Text('→', style: HaroText.ui(color: HaroTokens.ink42)),
        ],
      ),
    ),
  );
}
