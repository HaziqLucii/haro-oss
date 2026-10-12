import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api/haro_api.dart';
import '../../../api/models/models.dart';
import '../../../data/workspace_browser.dart';
import '../../../data/workspace_store.dart';
import '../../../overlays/toast.dart';
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/shell_icons.dart';

TextStyle _label() =>
    HaroText.mono(size: 10, color: HaroTokens.ink42, tracking: .16);

/// One browser for the whole workspace, kept open between the agent's runs. The Playwright plugin
/// opens a browser per run and closes it when the run ends; this one is started here (or by the
/// agent with `haro-app browser start`) and every run after that uses it, so the page the agent
/// left is still there for the next prompt. Per workspace: another workspace never shares it.
class BrowserSection extends ConsumerStatefulWidget {
  const BrowserSection({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  ConsumerState<BrowserSection> createState() => _BrowserSectionState();
}

class _BrowserSectionState extends ConsumerState<BrowserSection> {
  bool _busy = false;

  Future<void> _toggle(bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final api = ref.read(haroApiProvider);
      if (on) {
        await api.stopBrowser(widget.workspaceId);
      } else {
        await api.startBrowser(widget.workspaceId);
      }
      ref.invalidate(workspaceBrowserProvider(widget.workspaceId));
    } on HaroApiException catch (e) {
      if (mounted) showHaroToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st =
        ref.watch(workspaceBrowserProvider(widget.workspaceId)).value ??
        BrowserState.off;
    final starting = _busy && !st.running || st.starting;
    final on = st.running;
    final word = starting
        ? 'STARTING'
        : on
        ? 'ON'
        : 'OFF';
    final hint = starting
        ? 'Starting. The first time it downloads the server.'
        : on
        ? 'Every run here uses it, and it stays open between prompts.'
        : 'Turn it on before you prompt: the agent then keeps one browser '
              'across runs instead of reopening it each time.';
    return Container(
      key: const ValueKey('rail-browser'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: HaroTokens.line12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('BROWSER', style: _label()),
              Text(
                word,
                key: const ValueKey('rail-browser-state'),
                style: _label().copyWith(
                  color: on ? HaroTokens.ink : HaroTokens.ink42,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  hint,
                  key: const ValueKey('rail-browser-hint'),
                  style: HaroText.mono(
                    size: 10.5,
                    tracking: 0,
                    color: HaroTokens.ink42,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ShellIconButton(
                key: const ValueKey('rail-browser-toggle'),
                icon: on ? ShellIcon.stop : ShellIcon.play,
                tooltip: on ? 'Close the browser' : 'Open the browser',
                width: 28,
                height: 28,
                iconSize: 15,
                on: on,
                onTap: starting ? null : () => _toggle(on),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
