import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/haro_api.dart';
import '../api/models/models.dart';
import '../data/github_accounts.dart';
import '../data/workspace_store.dart' show haroApiProvider;
import '../features/workspace/rail/workspace_rail.dart'
    show workspaceUrlOpenerProvider;
import '../overlays/overlay.dart';
import '../state/github_account_view.dart';
import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/check_mark.dart';
import '../widgets/haro_button.dart';
import '../widgets/status_square.dart';

Future<void> showGithubLogin(BuildContext context) => showHaroOverlay<void>(
  context,
  width: 420,
  child: const GithubLoginDialog(),
);

enum _Phase { starting, pending, done, failed }

/// Device login through `gh`: shows the one-time code, polls until GitHub confirms, then
/// refreshes the account list and closes. However the dialog goes away (Cancel, Esc, a click
/// outside) a sign-in still waiting on GitHub is cancelled, so the next attempt is not refused.
class GithubLoginDialog extends ConsumerStatefulWidget {
  const GithubLoginDialog({super.key});

  @override
  ConsumerState<GithubLoginDialog> createState() => _GithubLoginDialogState();
}

class _GithubLoginDialogState extends ConsumerState<GithubLoginDialog> {
  late final HaroApi _api;
  late final GithubAccountsNotifier _accounts;
  _Phase _phase = _Phase.starting;
  GithubLoginStart? _login;
  String? _error;
  String? _doneLogin;

  /// The older sign-in a 409 says is in the way, when the backend names it.
  String? _blockingId;
  bool _copied = false;
  bool _polling = false;
  Timer? _poll;
  Timer? _closer;

  @override
  void initState() {
    super.initState();
    _api = ref.read(haroApiProvider);
    _accounts = ref.read(githubAccountsProvider.notifier);
    _start();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _closer?.cancel();
    final login = _login;
    if (login != null && _phase == _Phase.pending) _cancelRemote(login.id);
    super.dispose();
  }

  void _cancelRemote(String id) {
    _api.cancelGithubLogin(id).then((_) {}, onError: (Object _) {});
  }

  Future<void> _start() async {
    _blockingId = null;
    try {
      final login = await _api.startGithubLogin();
      if (!mounted) {
        _cancelRemote(login.id);
        return;
      }
      setState(() {
        _login = login;
        _phase = _Phase.pending;
      });
      _poll = Timer.periodic(const Duration(seconds: 1), (_) => _check());
    } on HaroApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = loginStartFailure(e.status, e.body, e.message);
        _blockingId = loginInProgressId(e.body);
      });
    }
  }

  Future<void> _cancelBlockingAndRetry(String id) async {
    setState(() => _phase = _Phase.starting);
    try {
      await _api.cancelGithubLogin(id);
    } on HaroApiException {
      // Already gone is as good as cancelled; the start below says if it is not.
    }
    if (mounted) await _start();
  }

  Future<void> _check() async {
    final login = _login;
    if (login == null || _polling || _phase != _Phase.pending) return;
    _polling = true;
    try {
      final status = await _api.getGithubLogin(login.id);
      if (!mounted || _phase != _Phase.pending) return;
      switch (status.state) {
        case GithubLoginState.done:
          _poll?.cancel();
          setState(() {
            _phase = _Phase.done;
            _doneLogin = status.login;
          });
          _accounts.refresh();
          // The backend restores the terminal's account after a login; one more read
          // settles the list if the first raced it. Not cancelled on dispose on purpose.
          final accounts = _accounts;
          Timer(const Duration(seconds: 1), accounts.refresh);
          _closer = Timer(HaroTokens.beat, () {
            if (mounted) closeHaroOverlay(context);
          });
        case GithubLoginState.failed || GithubLoginState.cancelled:
          _poll?.cancel();
          setState(() {
            _phase = _Phase.failed;
            _error = status.error ?? 'Sign-in did not finish.';
          });
        case GithubLoginState.pending || GithubLoginState.unknown:
          break;
      }
    } on HaroApiException {
      // A blip between polls is not a failed sign-in; the next tick asks again.
    } finally {
      _polling = false;
    }
  }

  Future<void> _copy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) setState(() => _copied = true);
  }

  void _open(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null) ref.read(workspaceUrlOpenerProvider)(uri);
  }

  @override
  Widget build(BuildContext context) {
    final login = _login;
    return Padding(
      key: const ValueKey('gh-login'),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ADD GITHUB ACCOUNT',
            style: HaroText.mono(size: 10.5, color: HaroTokens.ink42),
          ),
          const SizedBox(height: 16),
          if (_phase == _Phase.starting)
            Text(
              'Starting sign-in…',
              style: HaroText.ui(size: 13, color: HaroTokens.ink42),
            ),
          if (_phase == _Phase.failed)
            Text(
              _error ?? 'Sign-in failed.',
              key: const ValueKey('gh-login-error'),
              style: HaroText.ui(size: 13, color: HaroTokens.fail, height: 1.5),
            ),
          if (_phase == _Phase.done)
            Row(
              key: const ValueKey('gh-login-done'),
              children: [
                const CheckMark(color: HaroTokens.ink),
                const SizedBox(width: 10),
                Text(
                  _doneLogin == null
                      ? 'Signed in.'
                      : 'Signed in as $_doneLogin.',
                  style: HaroText.ui(size: 13, color: HaroTokens.ink),
                ),
              ],
            ),
          if (_phase == _Phase.pending && login != null) ..._codeBlock(login),
          if (_phase == _Phase.failed && _blockingId != null) ...[
            const SizedBox(height: 14),
            HaroButton(
              key: const ValueKey('gh-login-retry'),
              label: 'Cancel the login in progress and retry',
              onPressed: () => _cancelBlockingAndRetry(_blockingId!),
            ),
          ],
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerRight,
            child: HaroButton(
              key: const ValueKey('gh-login-cancel'),
              variant: HaroButtonVariant.tertiary,
              label: _phase == _Phase.pending ? 'Cancel' : 'Close',
              onPressed: () => closeHaroOverlay(context),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _codeBlock(GithubLoginStart login) => [
    Text(
      'Enter this code on GitHub to sign in.',
      style: HaroText.ui(size: 13, color: HaroTokens.ink66, height: 1.5),
    ),
    const SizedBox(height: 14),
    Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: HaroTokens.line14),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: SelectableText(
        login.code,
        key: const ValueKey('gh-login-code'),
        style: HaroText.mono(size: 30, color: HaroTokens.ink, tracking: .16),
      ),
    ),
    const SizedBox(height: 14),
    Row(
      children: [
        HaroButton(
          key: const ValueKey('gh-login-copy'),
          label: _copied ? 'COPIED' : 'COPY',
          textStyle: HaroText.mono(size: 11),
          onPressed: () => _copy(login.code),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: HaroButton(
            key: const ValueKey('gh-login-open'),
            variant: HaroButtonVariant.primary,
            label: 'Open ${_display(login.url)}',
            onPressed: () => _open(login.url),
          ),
        ),
      ],
    ),
    const SizedBox(height: 16),
    Row(
      children: [
        const StatusSquare(color: HaroTokens.ink66, filled: false),
        const SizedBox(width: 8),
        Text(
          'WAITING FOR GITHUB',
          style: HaroText.mono(size: 10.5, color: HaroTokens.ink42),
        ),
      ],
    ),
  ];
}

String _display(String url) => url.replaceFirst(RegExp(r'^https?://'), '');
