import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/github_accounts.dart';
import '../../state/github_account_view.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';

/// Under a failed GitHub load that looks like the wrong account (a repo the signed-in account
/// cannot see answers as "not found"): which account was used, and where to switch. Draws
/// nothing for any other error. If the account lookup fails the line still points at the menu.
class GhAccountHint extends ConsumerWidget {
  const GhAccountHint({
    super.key,
    required this.projectId,
    required this.error,
  });

  final String? projectId;
  final String? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = projectId;
    if (id == null || !needsAccountHint(error)) return const SizedBox.shrink();
    final resolved = ref.watch(projectGhAccountProvider(id))?.resolved;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        accountHintLine(resolved),
        key: const ValueKey('gh-hint'),
        textAlign: TextAlign.center,
        style: HaroText.ui(size: 12.5, color: HaroTokens.ink66, height: 1.5),
      ),
    );
  }
}
