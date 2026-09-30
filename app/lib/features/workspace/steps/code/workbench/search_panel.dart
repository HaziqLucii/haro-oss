import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../theme/haro_theme.dart';
import '../../../../../theme/tokens.dart';
import '../../../../../widgets/haro_pressable.dart';
import '../diff_model.dart';
import '../editor/editor_tabs.dart';
import 'search_model.dart';
import 'workbench_icons.dart';
import 'workbench_state.dart';
import 'workbench_widgets.dart';

/// Find in files: the query, an `N results in M files` line, and the hits grouped by file.
/// A click opens the file at the line, pinned.
class SearchPanel extends ConsumerStatefulWidget {
  const SearchPanel({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  ConsumerState<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends ConsumerState<SearchPanel> {
  late final TextEditingController _query = TextEditingController(
    text: ref.read(workbenchProvider(widget.workspaceId)).query,
  );
  Timer? _debounce;
  final _collapsed = <String>{};

  String get _id => widget.workspaceId;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) ref.read(workbenchProvider(_id).notifier).setQuery(text);
    });
  }

  void _open(String file, int line) => ref
      .read(editorTabsProvider(_id).notifier)
      .open(file, line: line, preview: false);

  @override
  Widget build(BuildContext context) {
    final query = ref
        .watch(workbenchProvider(_id).select((s) => s.query))
        .trim();
    final tooShort = query.length < minSearchChars;
    final result = tooShort
        ? null
        : ref.watch(workspaceSearchProvider((_id, query)));
    final data = result?.value;
    final groups = data == null
        ? const <SearchGroup>[]
        : groupMatches(data.matches, query);

    final String summary;
    if (tooShort) {
      summary = '';
    } else if (result != null && result.hasError) {
      summary = 'Search failed';
    } else if (data == null) {
      summary = 'Searching…';
    } else {
      summary = searchSummary(groups, truncated: data.truncated);
    }

    return PanelColumn(
      children: [
        PanelHeader(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const PanelTitle('SEARCH'),
              FieldBox(
                height: WorkbenchTokens.searchHeight,
                border: HaroTokens.line20,
                child: BareField(
                  key: const ValueKey('search-query'),
                  controller: _query,
                  hint: 'Search in files',
                  autofocus: true,
                  onChanged: _onChanged,
                  onSubmitted: (t) {
                    _debounce?.cancel();
                    ref.read(workbenchProvider(_id).notifier).setQuery(t);
                  },
                ),
              ),
              const SizedBox(height: 6),
              Text(
                summary,
                key: const ValueKey('search-summary'),
                style: HaroText.mono(
                  size: 10,
                  color: HaroTokens.ink42,
                  tracking: 0,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: groups.isEmpty
              ? const SizedBox.shrink()
              : ListView(
                  key: const ValueKey('search-results'),
                  padding: const EdgeInsets.only(bottom: 10),
                  children: [
                    for (final g in groups) ...[
                      _GroupHeader(
                        group: g,
                        open: !_collapsed.contains(g.file),
                        onTap: () => setState(() {
                          if (!_collapsed.remove(g.file)) {
                            _collapsed.add(g.file);
                          }
                        }),
                      ),
                      if (!_collapsed.contains(g.file))
                        for (final h in g.hits)
                          _HitRow(
                            file: g.file,
                            hit: h,
                            onTap: () => _open(g.file, h.line),
                          ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.open,
    required this.onTap,
  });

  final SearchGroup group;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: group.file,
    builder: (context, hovered) => Container(
      key: ValueKey('search-file:${group.file}'),
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: hovered ? HaroTokens.panel : HaroTokens.transparent,
      child: Row(
        children: [
          WorkbenchIconView(
            open ? WorkbenchIcon.chevronDown : WorkbenchIcon.chevronRight,
            size: 10,
            color: HaroTokens.ink42,
          ),
          const SizedBox(width: 8),
          Text(basenameOf(group.file), style: HaroText.ui(size: 13)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              dirnameOf(group.file),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: HaroText.mono(
                size: 10,
                color: HaroTokens.ink42,
                tracking: 0,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${group.hits.length}',
            style: HaroText.mono(
              size: 10,
              color: HaroTokens.ink66,
              tracking: 0,
            ),
          ),
        ],
      ),
    ),
  );
}

class _HitRow extends StatelessWidget {
  const _HitRow({required this.file, required this.hit, required this.onTap});

  final String file;
  final SearchHit hit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = HaroText.mono(size: 11, color: HaroTokens.ink66, tracking: 0);
    return HaroPressable(
      onTap: onTap,
      semanticLabel: '$file:${hit.line}',
      builder: (context, hovered) => Container(
        key: ValueKey('search-hit:$file:${hit.line}'),
        height: 24,
        padding: const EdgeInsets.fromLTRB(34, 0, 12, 0),
        color: hovered ? HaroTokens.panel : HaroTokens.transparent,
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text(
                '${hit.line}',
                textAlign: TextAlign.right,
                maxLines: 1,
                softWrap: false,
                style: style.copyWith(color: HaroTokens.ink42),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: hit.pre),
                    if (hit.match.isNotEmpty)
                      TextSpan(
                        text: hit.match,
                        style: const TextStyle(
                          color: HaroTokens.bg,
                          backgroundColor: HaroTokens.ink,
                        ),
                      ),
                    TextSpan(text: hit.post),
                  ],
                ),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
