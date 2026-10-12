import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models/models.dart';
import '../../data/workspace_detail.dart';
import '../../data/workspace_store.dart' show haroApiProvider;
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';

/// Shown on every step while the workspace's setup script has failed: the exit code, the last
/// lines it printed (the real reason, e.g. `bun: command not found`) and a way to run it again.
/// It disappears the moment a re-run starts.
class SetupBanner extends ConsumerStatefulWidget {
  const SetupBanner({
    super.key,
    required this.workspaceId,
    required this.onError,
  });

  final String workspaceId;
  final ValueChanged<Object> onError;

  @override
  ConsumerState<SetupBanner> createState() => _SetupBannerState();
}

class _SetupBannerState extends ConsumerState<SetupBanner> {
  static const _shownLines = 6;

  bool _rerunning = false;

  Future<void> _rerun() async {
    setState(() => _rerunning = true);
    try {
      await ref.read(haroApiProvider).rerunSetup(widget.workspaceId);
    } catch (e) {
      if (mounted) setState(() => _rerunning = false);
      widget.onError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final setup = ref.watch(
      workspaceDetailProvider(widget.workspaceId).select((d) => d.setup),
    );
    if (setup?.status == SetupStatus.running) _rerunning = false;
    if (setup == null || setup.status != SetupStatus.failed) {
      return const SizedBox.shrink();
    }
    final lines = setup.tail.isEmpty ? <String>[] : setup.tail.split('\n');
    final shown = lines.length > _shownLines
        ? lines.sublist(lines.length - _shownLines)
        : lines;
    final detail = shown.isNotEmpty ? shown.join('\n') : (setup.note ?? '');
    return Container(
      key: const ValueKey('setup-banner'),
      margin: const EdgeInsets.fromLTRB(28, 12, 28, 0),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        border: Border.all(color: HaroTokens.line20),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  setup.exit == null
                      ? 'SETUP FAILED'
                      : 'SETUP FAILED · EXIT ${setup.exit}',
                  key: const ValueKey('setup-banner-title'),
                  style: HaroText.mono(
                    size: 10.5,
                    color: HaroTokens.fail,
                    tracking: .14,
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    detail,
                    key: const ValueKey('setup-banner-detail'),
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                    style: HaroText.mono(
                      size: 11.5,
                      color: HaroTokens.ink66,
                      tracking: 0,
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          IntrinsicWidth(
            child: HaroButton(
              key: const ValueKey('setup-banner-rerun'),
              label: 'Re-run setup',
              variant: HaroButtonVariant.control,
              height: 28,
              fontSize: 12.5,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              onPressed: _rerunning ? null : _rerun,
            ),
          ),
        ],
      ),
    );
  }
}
