import 'package:flutter/widgets.dart';

import '../features/guide/guide_view.dart';
import '../theme/haro_theme.dart';
import '../widgets/haro_button.dart';
import '../widgets/haro_segmented.dart';
import 'overlay.dart';
import 'shortcuts_overlay.dart' show ShortcutsList;

enum HelpTab { guide, shortcuts }

/// The help window: a Guide tab (topics down the left) and a Keyboard shortcuts tab. `?` opens
/// it on the shortcuts, the top bar's `?` button and the palette open the guide.
Future<void> showHelpOverlay(
  BuildContext context, {
  HelpTab tab = HelpTab.guide,
  String? topic,
}) => showHaroOverlay<void>(
  context,
  width: 980,
  height: 640,
  child: HelpOverlay(tab: tab, topic: topic),
);

class HelpOverlay extends StatefulWidget {
  const HelpOverlay({super.key, this.tab = HelpTab.guide, this.topic});

  final HelpTab tab;
  final String? topic;

  @override
  State<HelpOverlay> createState() => _HelpOverlayState();
}

class _HelpOverlayState extends State<HelpOverlay> {
  late HelpTab _tab = widget.tab;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(30, 24, 30, 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Help', style: HaroText.ui(size: 22, weight: FontWeight.w500)),
            const SizedBox(width: 24),
            HaroSegmented<HelpTab>(
              keyPrefix: 'help-tab',
              mono: false,
              height: 28,
              horizontalPadding: 14,
              segments: const [
                HaroSegment(HelpTab.guide, 'Guide'),
                HaroSegment(HelpTab.shortcuts, 'Keyboard shortcuts'),
              ],
              selected: _tab,
              onChanged: (t) => setState(() => _tab = t),
            ),
            const Spacer(),
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
        const SizedBox(height: 18),
        // Both stay built, so a reader who checks a key and comes back finds the guide where
        // they left it (topic, search and scroll).
        Expanded(
          child: IndexedStack(
            index: _tab == HelpTab.guide ? 0 : 1,
            children: [
              GuideView(
                key: const ValueKey('help-guide'),
                initialTopic: widget.topic,
              ),
              const SingleChildScrollView(
                key: ValueKey('help-shortcuts'),
                child: ShortcutsList(),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
