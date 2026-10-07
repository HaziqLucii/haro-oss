import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/models.dart';
import '../data/github_accounts.dart';
import '../state/github_account_view.dart';
import '../theme/haro_theme.dart';
import '../theme/tokens.dart';
import '../widgets/shell_icons.dart';

/// Rec. 709 luma, so the picture is ink-neutral like the rest of the chrome.
const _gray = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// A GitHub account's picture in a hairline ring, grayscale, no shadow. The circle is the one
/// place the brand's 2px corners do not apply. While the picture is loading, offline or failed
/// the ring holds the login's first letter; with no [account] it holds a person.
class GithubAvatar extends ConsumerWidget {
  const GithubAvatar({
    super.key,
    this.account,
    this.size = HaroTokens.avatarSize,
    this.lit = false,
  });

  final GithubAccount? account;
  final double size;

  /// Hovered or open: the ring brightens.
  final bool lit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = account;
    Widget face;
    if (a == null) {
      face = Center(
        key: const ValueKey('gh-avatar-person'),
        child: ShellIconView(
          ShellIcon.person,
          size: size * .66,
          color: lit ? HaroTokens.ink : HaroTokens.ink66,
        ),
      );
    } else {
      final letter = Center(
        key: const ValueKey('gh-avatar-letter'),
        child: Text(
          loginInitial(a.login),
          style: HaroText.mono(
            size: size * .46,
            color: lit ? HaroTokens.ink : HaroTokens.ink66,
            tracking: 0,
          ),
        ),
      );
      face = ColorFiltered(
        colorFilter: _gray,
        child: Image(
          key: const ValueKey('gh-avatar-image'),
          image: ref.watch(githubAvatarImageProvider)(a.avatarUrl),
          width: size,
          height: size,
          fit: BoxFit.cover,
          frameBuilder: (context, child, frame, sync) =>
              frame == null && !sync ? letter : child,
          errorBuilder: (context, error, stack) => letter,
        ),
      );
    }
    return AnimatedContainer(
      duration: HaroTokens.fadeFast,
      curve: HaroTokens.curve,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: lit ? HaroTokens.line30 : HaroTokens.line20),
      ),
      child: ClipOval(child: face),
    );
  }
}
