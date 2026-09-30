import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/workspace/workspace_ui.dart';
import '../shell/shell_providers.dart';

import '../shortcuts/platform_keys.dart';
import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/haro_button.dart';
import 'overlay.dart';

Future<void> showShortcutsOverlay(BuildContext context) =>
    showHaroOverlay<void>(context, width: 720, child: const ShortcutsOverlay());

/// Label and keys in the order the prototype lists them (row-major across two columns).
/// A [manual] workspace has no agent step or prompt: three steps, and no prompt to focus.
List<(String, String)> shortcutEntries({
  PrimaryModifier? modifier,
  bool manual = false,
}) {
  String p(String key, {bool shift = false}) =>
      primaryLabel(key, shift: shift, modifier: modifier);
  return [
    ('Command palette', p('K')),
    ('New workspace', p('N')),
    if (!manual) ('Focus the prompt', p('I')),
    (
      manual ? 'Commit' : 'Run agent / commit',
      primaryLabel('↵', modifier: modifier),
    ),
    manual
        ? ('Go to code / verify / ship', p('1–3'))
        : ('Go to step 1–4', p('1–4')),
    ('Run gate', p('G')),
    ('Go to file', p('P')),
    ('Search in files', p('F', shift: true)),
    ('Toggle side panel', p('B')),
    ('Run dev server', p('R')),
    ('Toggle terminal', controlLabel('`', modifier: modifier)),
    ('Save all files (runs the gate with Run on save)', p('S')),
    ('Split editor', p('\\')),
    ('Focus the editor', p('↵', shift: true)),
    ('Open worktree in your editor', p('O', shift: true)),
    ('Next workspace that needs you', p('J')),
    ('Close / exit', 'Esc'),
    ('More actions on a project or workspace', 'Right-click'),
  ];
}

/// `?` (§6.3). Keep in step with the bindings in `key_bindings.dart` and the editor/composer.
class ShortcutsOverlay extends ConsumerWidget {
  const ShortcutsOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final openId = ref.watch(
      workspaceUiProvider.select((u) => u.activeWorkspaceId),
    );
    final manual =
        openId != null &&
        (ref.watch(shellDataProvider).workspaceById(openId)?.manual ?? false);
    final entries = shortcutEntries(manual: manual);
    final rows = <Widget>[];
    for (var i = 0; i < entries.length; i += 2) {
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _Entry(entries[i])),
            const SizedBox(width: 40),
            Expanded(
              child: i + 1 < entries.length
                  ? _Entry(entries[i + 1])
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Keyboard shortcuts',
                  style: HaroText.ui(size: 22, weight: FontWeight.w500),
                ),
              ),
              HaroButton(
                width: 28,
                height: 28,
                padding: EdgeInsets.zero,
                label: 'Close',
                tooltip: 'Close (Esc)',
                onPressed: () => closeHaroOverlay(context),
                child: const Center(child: Text('✕')),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...rows,
          const SizedBox(height: 16),
          Text(
            'Press ? anywhere to open this.',
            style: HaroText.ui(size: 12.5, color: HaroTokens.ink42),
          ),
        ],
      ),
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry(this.entry);

  final (String, String) entry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 11),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: HaroTokens.line08)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            entry.$1,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HaroText.ui(color: HaroTokens.ink86),
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: HaroTokens.line20),
            borderRadius: BorderRadius.circular(HaroTokens.radius),
          ),
          child: Text(
            entry.$2,
            maxLines: 1,
            softWrap: false,
            style: HaroText.mono(color: HaroTokens.ink, tracking: 0),
          ),
        ),
      ],
    ),
  );
}
