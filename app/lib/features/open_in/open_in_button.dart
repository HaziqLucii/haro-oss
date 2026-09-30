import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/haro_pressable.dart';
import 'editors_provider.dart';
import 'open_in_launcher.dart';

/// `Open in Zed ▾`: the label half opens the default editor, the caret half always shows the
/// menu. With no default (preference "Ask every time") it is one `Open in… ▾` that shows the
/// menu. Secondary styling, never primary.
class OpenInButton extends ConsumerWidget {
  const OpenInButton({
    super.key,
    required this.workspaceId,
    required this.source,
    this.path,
    this.line,
    this.height = 24,
  });

  final String workspaceId;
  final String source;
  final String? path;

  /// Read at click time: the cursor line moves without the button rebuilding.
  final int? Function()? line;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(defaultEditorProvider);
    final style = HaroText.mono(size: 11, tracking: 0);

    Widget segment({
      required Key key,
      required String label,
      required VoidCallback onTap,
      required EdgeInsets padding,
      String? semantic,
    }) => HaroPressable(
      onTap: onTap,
      semanticLabel: semantic ?? label,
      builder: (context, hovered) => Container(
        key: key,
        height: height - 2,
        padding: padding,
        alignment: Alignment.center,
        child: AnimatedDefaultTextStyle(
          duration: HaroTokens.fadeFast,
          curve: HaroTokens.curve,
          style: style.copyWith(
            color: hovered ? HaroTokens.ink : HaroTokens.ink66,
          ),
          child: Text(label, maxLines: 1, softWrap: false),
        ),
      ),
    );

    void launch(BuildContext c, {bool menu = false}) => ref
        .read(openInLauncherProvider)
        .launch(
          c,
          workspaceId: workspaceId,
          source: source,
          path: path,
          line: line?.call(),
          forceMenu: menu,
        );

    return Container(
      key: const ValueKey('open-in'),
      decoration: BoxDecoration(
        border: Border.all(color: HaroTokens.line14),
        borderRadius: BorderRadius.circular(HaroTokens.radius),
      ),
      child: Builder(
        builder: (context) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (editor == null)
              segment(
                key: const ValueKey('open-in-main'),
                label: 'Open in… ▾',
                semantic: 'Open in…',
                padding: const EdgeInsets.symmetric(horizontal: 9),
                onTap: () => launch(context),
              )
            else ...[
              segment(
                key: const ValueKey('open-in-main'),
                label: 'Open in ${editor.label}',
                padding: const EdgeInsets.symmetric(horizontal: 9),
                onTap: () => launch(context),
              ),
              Container(width: 1, height: height - 2, color: HaroTokens.line14),
              segment(
                key: const ValueKey('open-in-caret'),
                label: '▾',
                semantic: 'Choose editor',
                padding: const EdgeInsets.symmetric(horizontal: 7),
                onTap: () => launch(context, menu: true),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// `Open in editor ↗`: a secondary button at one file and line (verify rows). Opens the
/// default editor, or the menu when the preference is "Ask every time".
class OpenInLink extends ConsumerWidget {
  const OpenInLink({
    super.key,
    required this.workspaceId,
    required this.source,
    required this.path,
    this.line,
  });

  final String workspaceId;
  final String source;
  final String path;
  final int? line;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IntrinsicWidth(
    child: Builder(
      builder: (context) => HaroButton(
        label: 'Open in editor ↗',
        height: 26,
        fontSize: 12.5,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        foreground: HaroTokens.ink86,
        onPressed: () => ref
            .read(openInLauncherProvider)
            .launch(
              context,
              workspaceId: workspaceId,
              source: source,
              path: path,
              line: line,
            ),
      ),
    ),
  );
}
