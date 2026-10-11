import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../api/models/models.dart';
import '../../../../state/manual_rail.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../../../widgets/haro_pressable.dart';
import '../../../../widgets/haro_text_field.dart';
import '../workspace_rail.dart' show workspaceUrlOpenerProvider;
import 'manual_controller.dart';
import 'manual_widgets.dart';

/// Docs tab: saved plans, pinned web docs and man pages opened this session, plus a reader.
class DocsTab extends ConsumerStatefulWidget {
  const DocsTab({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  ConsumerState<DocsTab> createState() => _DocsTabState();
}

class _DocsTabState extends ConsumerState<DocsTab> {
  final _url = TextEditingController();

  ManualRailController get _ctl =>
      ref.read(manualRailProvider(widget.workspaceId).notifier);

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _pin() async {
    final ok = await _ctl.pin(_url.text);
    if (ok && mounted) _url.clear();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(manualRailProvider(widget.workspaceId));
    final items = docItems(
      plans: s.plans,
      pinned: s.pinned,
      manPages: s.manPages,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (items.isEmpty)
            Text(
              'Nothing here yet. Saved plans, pinned links and man pages you open show up in this list.',
              key: const ValueKey('docs-empty'),
              style: HaroText.ui(
                size: 13,
                color: HaroTokens.ink42,
                height: 1.5,
              ),
            ),
          for (final item in items)
            _DocRow(
              key: ValueKey('doc-${item.ref.kind.name}-${item.ref.id}'),
              item: item,
              selected: s.selectedDoc == item.ref,
              onTap: () => _ctl.selectDoc(item.ref),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: HaroTextField(
                  key: const ValueKey('pin-input'),
                  controller: _url,
                  mono: true,
                  fontSize: 11,
                  hintText: 'Pin a link: https://...',
                  onSubmitted: (_) => _pin(),
                ),
              ),
              const SizedBox(width: 4),
              HaroButton(
                key: const ValueKey('pin-go'),
                label: 'Pin',
                variant: HaroButtonVariant.secondary,
                height: 30,
                fontSize: 12.5,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                onPressed: _pin,
              ),
            ],
          ),
          if (s.docError != null) ManualError(s.docError!),
          if (s.selectedDoc != null)
            _Reader(state: s, workspaceId: widget.workspaceId),
        ],
      ),
    );
  }
}

class _DocRow extends StatelessWidget {
  const _DocRow({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final DocItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    semanticLabel: item.name,
    builder: (context, hovered) => Container(
      height: 28,
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: selected || hovered ? HaroTokens.raised : HaroTokens.transparent,
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HaroText.mono(
                size: 11.5,
                color: selected ? HaroTokens.ink : HaroTokens.ink66,
                tracking: 0,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            item.meta,
            style: HaroText.mono(
              size: 9.5,
              color: HaroTokens.ink42,
              tracking: 0,
            ),
          ),
        ],
      ),
    ),
  );
}

class _Reader extends ConsumerWidget {
  const _Reader({required this.state, required this.workspaceId});

  final ManualState state;
  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ref0 = state.selectedDoc!;
    final ctl = ref.read(manualRailProvider(workspaceId).notifier);
    switch (ref0.kind) {
      case DocKind.plan:
        ManualPlan? plan;
        for (final p in state.plans) {
          if (p.id == ref0.id) plan = p;
        }
        if (plan == null) return const SizedBox.shrink();
        return _shell(
          key: 'reader-plan',
          title: planFileName(plan),
          body: [
            Text(
              plan.title,
              style: HaroText.ui(
                size: 13,
                color: HaroTokens.ink86,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 6),
            for (final st in plan.steps) PlanStepRow(step: st),
            if (plan.why.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Why this order: ${plan.why}',
                style: HaroText.ui(
                  size: 12.5,
                  color: HaroTokens.ink66,
                  height: 1.5,
                ),
              ),
            ],
          ],
          footer: 'yours · ${planProgress(plan)} done',
          actions: [
            HaroButton(
              key: const ValueKey('reader-tick'),
              label: 'Tick in Plan',
              variant: HaroButtonVariant.secondary,
              height: 26,
              fontSize: 12.5,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: () => ctl.showPlan(plan!.id),
            ),
          ],
        );
      case DocKind.pinned:
        PinnedDoc? doc;
        for (final d in state.pinned) {
          if (d.url == ref0.id) doc = d;
        }
        if (doc == null) return const SizedBox.shrink();
        return _shell(
          key: 'reader-pinned',
          title: doc.title,
          body: [
            Text(
              doc.url,
              style: HaroText.mono(
                size: 11,
                color: HaroTokens.ink66,
                tracking: 0,
              ),
            ),
          ],
          footer: 'web · pinned · opens in your browser',
          actions: [
            HaroButton(
              key: const ValueKey('reader-open'),
              label: 'Open ↗',
              variant: HaroButtonVariant.secondary,
              height: 26,
              fontSize: 12.5,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: () {
                final uri = Uri.tryParse(doc!.url);
                if (uri != null) ref.read(workspaceUrlOpenerProvider)(uri);
              },
            ),
            HaroButton(
              key: const ValueKey('reader-unpin'),
              label: 'Unpin',
              height: 26,
              fontSize: 12.5,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              onPressed: () => ctl.unpin(doc!.url),
            ),
          ],
        );
      case DocKind.man:
        ManPage? page;
        for (final m in state.manPages) {
          if (m.page == ref0.id) page = m;
        }
        if (page == null) return const SizedBox.shrink();
        return _shell(
          key: 'reader-man',
          title: page.page,
          body: [
            Text(
              page.text,
              softWrap: false,
              style: HaroText.mono(
                size: 10.5,
                color: HaroTokens.ink86,
                tracking: 0,
                height: 1.45,
              ),
            ),
          ],
          scrollX: true,
          footer: page.truncated
              ? 'offline · no AI summary · cut short'
              : 'offline · no AI summary',
        );
    }
  }

  Widget _shell({
    required String key,
    required String title,
    required List<Widget> body,
    required String footer,
    List<Widget> actions = const [],
    bool scrollX = false,
  }) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: body,
    );
    return Column(
      key: ValueKey(key),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Text(
          title,
          style: HaroText.mono(
            size: 15,
            weight: FontWeight.w700,
            color: HaroTokens.ink,
            tracking: 0,
          ),
        ),
        const SizedBox(height: 8),
        if (scrollX)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: content,
          )
        else
          content,
        const SizedBox(height: 10),
        Text(
          footer,
          key: const ValueKey('reader-footer'),
          style: HaroText.mono(size: 10, color: HaroTokens.ink42, tracking: 0),
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: actions),
        ],
      ],
    );
  }
}
