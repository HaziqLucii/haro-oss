import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/models.dart';
import '../data/github_accounts.dart';
import '../state/github_account_view.dart';
import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/check_mark.dart';
import '../widgets/haro_pressable.dart';
import 'github_avatar.dart';
import 'github_login_dialog.dart';

/// The round avatar at the top right of the top bar. Opens the account menu. [projectId] is
/// the open workspace's project, which adds the "this project uses" section.
class GithubAccountButton extends ConsumerStatefulWidget {
  const GithubAccountButton({super.key, this.projectId});

  final String? projectId;

  @override
  ConsumerState<GithubAccountButton> createState() =>
      _GithubAccountButtonState();
}

class _GithubAccountButtonState extends ConsumerState<GithubAccountButton>
    with WidgetsBindingObserver {
  bool _open = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _refresh() {
    ref.read(githubAccountsProvider.notifier).refresh();
    final id = widget.projectId;
    if (id != null && ref.exists(projectGhAccountProvider(id))) {
      ref.read(projectGhAccountProvider(id).notifier).refresh();
    }
  }

  Future<void> _openMenu() async {
    final box = context.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset.zero);
    final anchor = Rect.fromLTWH(
      origin.dx,
      origin.dy,
      box.size.width,
      box.size.height,
    );
    ref.read(githubAccountsProvider.notifier).refresh();
    final id = widget.projectId;
    if (id != null) ref.read(projectGhAccountProvider(id).notifier).refresh();
    final host = context;
    setState(() => _open = true);
    final wantsLogin = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close menu',
      barrierColor: HaroTokens.transparent,
      transitionDuration: HaroTokens.fadeFast,
      pageBuilder: (context, _, _) =>
          GithubAccountMenu(anchor: anchor, projectId: id),
      transitionBuilder: (context, animation, _, page) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: HaroTokens.curve),
        child: page,
      ),
    );
    if (mounted) setState(() => _open = false);
    if (wantsLogin == true && host.mounted) showGithubLogin(host);
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(githubAccountsProvider).data;
    final account = avatarAccount(accounts);
    final label = account == null
        ? (accounts != null && !accounts.ghAvailable
              ? 'GitHub CLI not installed'
              : 'GitHub: no account')
        : 'GitHub: ${account.login}';
    return HaroPressable(
      key: const ValueKey('gh-avatar-button'),
      onTap: _openMenu,
      tooltip: label,
      semanticLabel: label,
      builder: (context, hovered) =>
          GithubAvatar(account: account, lit: hovered || _open),
    );
  }
}

const double _rowHeight = 30;
const double _autoRowHeight = 44;
const double _edge = 8;

class _Item {
  const _Item(this.build, [this.onSelect]);

  final Widget Function(bool focused) build;
  final VoidCallback? onSelect;
}

/// The dropdown: accounts, the project's choice, and "Add GitHub account…". Arrow keys move,
/// Enter picks, Esc or a click outside closes. Picking an account leaves it open so the mark
/// visibly moves.
class GithubAccountMenu extends ConsumerStatefulWidget {
  const GithubAccountMenu({super.key, required this.anchor, this.projectId});

  final Rect anchor;
  final String? projectId;

  @override
  ConsumerState<GithubAccountMenu> createState() => _GithubAccountMenuState();
}

class _GithubAccountMenuState extends ConsumerState<GithubAccountMenu> {
  int _focus = -1;
  List<_Item> _items = const [];

  void _move(int delta) {
    final rows = [
      for (var i = 0; i < _items.length; i++)
        if (_items[i].onSelect != null) i,
    ];
    if (rows.isEmpty) return;
    final at = rows.indexOf(_focus);
    final next = at == -1
        ? (delta > 0 ? 0 : rows.length - 1)
        : (at + delta) % rows.length;
    setState(() => _focus = rows[next]);
  }

  void _select() {
    if (_focus < 0 || _focus >= _items.length) return;
    _items[_focus].onSelect?.call();
  }

  /// Everything off [ref] is read before the first await: Esc can dispose this state while
  /// the backend is still answering.
  Future<void> _setDefault(String login) async {
    final id = widget.projectId;
    final project = id != null && ref.exists(projectGhAccountProvider(id))
        ? ref.read(projectGhAccountProvider(id).notifier)
        : null;
    await ref.read(githubAccountsProvider.notifier).setDefault(login);
    await project?.refresh();
  }

  List<_Item> _build(GithubAccounts? accounts, ProjectGhAccount? project) {
    final items = <_Item>[];
    void heading(String text) => items.add(_Item((_) => _Heading(text)));
    void note(String text, {Key? key}) =>
        items.add(_Item((_) => _Note(text, key: key)));
    void separator() => items.add(_Item((_) => const _Separator()));

    if (accounts != null && !accounts.ghAvailable) {
      heading('GitHub');
      note(
        'The GitHub CLI (gh) is not installed. Install it to sign in.',
        key: const ValueKey('gh-missing'),
      );
      return items;
    }

    final list = accounts?.accounts ?? const <GithubAccount>[];
    heading('Accounts');
    if (list.isEmpty) {
      note(
        accounts == null ? 'Loading…' : 'No GitHub account signed in.',
        key: const ValueKey('gh-none'),
      );
    }
    for (final a in list) {
      items.add(
        _Item(
          (focused) => _Row(
            key: ValueKey('gh-account-${a.login}'),
            focused: focused,
            leading: GithubAvatar(
              account: a,
              size: HaroTokens.avatarSizeSmall,
              lit: focused,
            ),
            label: a.login,
            tag: a.terminalActive ? 'terminal' : null,
            marked: a.isDefault,
            onTap: () => _setDefault(a.login),
          ),
          () => _setDefault(a.login),
        ),
      );
    }

    final id = widget.projectId;
    if (id != null) {
      void pick(String? login) =>
          ref.read(projectGhAccountProvider(id).notifier).setOverride(login);
      separator();
      heading('This project uses');
      items.add(
        _Item(
          (focused) => _Row(
            key: const ValueKey('gh-project-auto'),
            focused: focused,
            label: 'Auto',
            detail: autoRowDetail(project),
            marked: project != null && project.override == null,
            onTap: () => pick(null),
          ),
          () => pick(null),
        ),
      );
      for (final a in list) {
        items.add(
          _Item(
            (focused) => _Row(
              key: ValueKey('gh-project-${a.login}'),
              focused: focused,
              leading: GithubAvatar(
                account: a,
                size: HaroTokens.avatarSizeSmall,
                lit: focused,
              ),
              label: a.login,
              marked: project?.override == a.login,
              onTap: () => pick(a.login),
            ),
            () => pick(a.login),
          ),
        );
      }
    }

    separator();
    void add() => Navigator.of(context, rootNavigator: true).pop(true);
    items.add(
      _Item(
        (focused) => _Row(
          key: const ValueKey('gh-add'),
          focused: focused,
          label: 'Add GitHub account…',
          onTap: add,
        ),
        add,
      ),
    );
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(githubAccountsProvider).data;
    final id = widget.projectId;
    final project = id == null ? null : ref.watch(projectGhAccountProvider(id));
    _items = _build(accounts, project);
    if (_focus >= _items.length) _focus = -1;

    final size = MediaQuery.sizeOf(context);
    const width = HaroTokens.accountMenuWidth;
    final left = math.max(
      _edge,
      math.min(widget.anchor.right - width, size.width - width - _edge),
    );
    final top = widget.anchor.bottom + 6;
    return FocusScope(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context, rootNavigator: true).maybePop(),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
          const SingleActivator(LogicalKeyboardKey.enter): _select,
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              Positioned(
                left: left,
                top: top,
                width: width,
                child: Material(
                  type: MaterialType.transparency,
                  child: Container(
                    key: const ValueKey('gh-menu'),
                    constraints: BoxConstraints(
                      maxHeight: size.height - top - _edge,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      color: HaroTokens.panel,
                      border: Border.all(color: HaroTokens.line20),
                      borderRadius: BorderRadius.circular(HaroTokens.radius),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < _items.length; i++)
                            _items[i].build(i == _focus),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    height: 26,
    padding: const EdgeInsets.only(left: 12, right: 12, top: 6),
    alignment: Alignment.centerLeft,
    child: Text(
      text.toUpperCase(),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: HaroText.mono(size: 10, color: HaroTokens.ink42, tracking: .14),
    ),
  );
}

class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 9,
    child: Center(
      child: Divider(height: 1, thickness: 1, color: HaroTokens.line08),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Text(
      text,
      style: HaroText.ui(size: 12.5, color: HaroTokens.ink42, height: 1.45),
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.label,
    required this.onTap,
    this.leading,
    this.detail,
    this.tag,
    this.marked = false,
    this.focused = false,
  });

  final String label;
  final VoidCallback onTap;
  final Widget? leading;
  final String? detail;
  final String? tag;
  final bool marked;
  final bool focused;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: label,
    builder: (_, hovered) {
      final lit = hovered || focused;
      return AnimatedContainer(
        duration: HaroTokens.fadeFast,
        curve: HaroTokens.curve,
        height: detail == null ? _rowHeight : _autoRowHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: lit ? HaroTokens.line08 : HaroTokens.transparent,
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 8)],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: HaroText.ui(
                      size: 13,
                      color: lit ? HaroTokens.ink : HaroTokens.ink86,
                    ),
                  ),
                  if (detail != null)
                    Text(
                      detail!,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: HaroText.mono(
                        size: 10,
                        color: HaroTokens.ink42,
                        tracking: .04,
                      ),
                    ),
                ],
              ),
            ),
            if (tag != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  border: Border.all(color: HaroTokens.line14),
                  borderRadius: BorderRadius.circular(HaroTokens.radius),
                ),
                child: Text(
                  tag!.toUpperCase(),
                  style: HaroText.mono(
                    size: 9,
                    color: HaroTokens.ink42,
                    tracking: .12,
                  ),
                ),
              ),
            ],
            if (marked) ...[
              const SizedBox(width: 10),
              const CheckMark(color: HaroTokens.ink),
            ],
          ],
        ),
      );
    },
  );
}
