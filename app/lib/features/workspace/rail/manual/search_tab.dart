import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/models/models.dart';
import '../../../../state/manual_rail.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../../../widgets/haro_pressable.dart';
import '../../../../widgets/haro_text_field.dart';
import '../../terminal/panel_tabs.dart' show openFileFromPanel;
import '../workspace_rail.dart' show workspaceUrlOpenerProvider;
import 'manual_controller.dart';
import 'manual_widgets.dart';

/// Search tab: one box, "Ask where to look\u2026". Pointers only; each row opens the place it names.
class SearchTab extends ConsumerStatefulWidget {
  const SearchTab({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  ConsumerState<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends ConsumerState<SearchTab> {
  final _query = TextEditingController();

  ManualRailController get _ctl =>
      ref.read(manualRailProvider(widget.workspaceId).notifier);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _ask(String text) => _ctl.ask(text);

  void _go(ResearchRow row) {
    switch (row.action) {
      case 'jump':
        final t = parseTarget(row.target);
        openFileFromPanel(
          context,
          ref,
          widget.workspaceId,
          t.path,
          line: t.line,
        );
      case 'read':
        _ctl.openMan(row.target);
      default:
        final uri = Uri.tryParse(row.target);
        if (uri != null) ref.read(workspaceUrlOpenerProvider)(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(manualRailProvider(widget.workspaceId));
    final groups = groupRows(s.rows);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: HaroTextField(
                  key: const ValueKey('search-input'),
                  controller: _query,
                  mono: true,
                  height: 34,
                  fontSize: 11.5,
                  hintText: 'Ask where to look\u2026',
                  onSubmitted: _ask,
                ),
              ),
              const SizedBox(width: 8),
              if (s.searching)
                HaroButton(
                  key: const ValueKey('search-stop'),
                  label: 'Stop',
                  height: 34,
                  fontSize: 11.5,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  onPressed: _ctl.stop,
                )
              else
                HaroButton(
                  key: const ValueKey('search-go'),
                  label: 'Ask',
                  variant: HaroButtonVariant.secondary,
                  height: 34,
                  fontSize: 11.5,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  onPressed: () => _ask(_query.text),
                ),
            ],
          ),
          if (s.searching)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Looking...',
                key: const ValueKey('search-busy'),
                style: HaroText.ui(size: 13, color: HaroTokens.ink42),
              ),
            ),
          if (s.searchError != null) ManualError(s.searchError!),
          if (s.answer != null && s.answer!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                s.answer!,
                key: const ValueKey('search-answer'),
                style: HaroText.ui(
                  size: 13,
                  color: HaroTokens.ink86,
                  height: 1.5,
                ),
              ),
            ),
          RunNotes(
            keyPrefix: 'search',
            guardNote: s.searchGuardNote,
            blockedCalls: s.searchBlocked,
          ),
          if (!s.searching &&
              s.searched &&
              s.rows.isEmpty &&
              s.searchError == null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Nothing found.',
                key: const ValueKey('search-none'),
                style: HaroText.ui(size: 13, color: HaroTokens.ink42),
              ),
            ),
          if (!s.searched)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Pointers only. haro shows where to look; you read it and write the code.',
                key: const ValueKey('search-empty'),
                style: HaroText.ui(
                  size: 13,
                  color: HaroTokens.ink42,
                  height: 1.5,
                ),
              ),
            ),
          for (final g in groups)
            for (final (i, row) in g.rows.indexed)
              _ResultRow(
                key: ValueKey('result-${g.source}-$i'),
                row: row,
                onTap: () => _go(row),
              ),
          if (s.note != null && s.note!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                s.note!,
                style: HaroText.mono(
                  size: 10,
                  color: HaroTokens.ink42,
                  tracking: 0,
                ),
              ),
            ),
          if (!s.searching && s.recent.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              'RECENT',
              key: const ValueKey('recent-header'),
              style: HaroText.mono(
                size: 9.5,
                color: HaroTokens.ink42,
                tracking: .1,
              ),
            ),
            for (final (i, ask) in s.recent.indexed)
              _RecentRow(
                key: ValueKey('recent-$i'),
                ask: ask,
                onTap: () {
                  _query.text = ask.query;
                  _ctl.openRecent(ask);
                },
              ),
          ],
        ],
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({super.key, required this.ask, required this.onTap});

  final RecentAsk ask;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final when = ask.at == null ? '' : recentAskAgo(ask.at!, DateTime.now());
    return HaroPressable(
      onTap: onTap,
      semanticLabel: 'Reopen answer: ${ask.query}',
      builder: (context, hovered) => Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: HaroTokens.line08)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                ask.query,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HaroText.ui(
                  size: 13,
                  color: hovered ? HaroTokens.ink : HaroTokens.ink86,
                ),
              ),
            ),
            if (when.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                when,
                style: HaroText.mono(
                  size: 9.5,
                  color: HaroTokens.ink42,
                  tracking: .1,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({super.key, required this.row, required this.onTap});

  final ResearchRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final small = HaroText.mono(
      size: 9.5,
      color: HaroTokens.ink42,
      tracking: .1,
    );
    return HaroPressable(
      onTap: onTap,
      semanticLabel: '${howLabel(row.action)} ${row.title}',
      builder: (context, hovered) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: HaroTokens.line08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    sourceLabel(row.source),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: small,
                  ),
                ),
                Text(
                  howLabel(row.action),
                  style: small.copyWith(
                    color: hovered ? HaroTokens.ink : HaroTokens.ink42,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              row.title,
              style: HaroText.ui(
                size: 13.5,
                color: hovered ? HaroTokens.ink : HaroTokens.ink86,
              ),
            ),
            if (row.why.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                row.why,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: HaroText.ui(
                  size: 12,
                  color: HaroTokens.ink42,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
