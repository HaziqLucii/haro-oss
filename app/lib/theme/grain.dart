import 'package:flutter/widgets.dart';

import 'tokens.dart';

class GrainOverlay extends StatelessWidget {
  const GrainOverlay({super.key});

  @override
  Widget build(BuildContext context) => const IgnorePointer(
    child: Opacity(
      opacity: HaroTokens.grainOpacity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/images/grain.png'),
            repeat: ImageRepeat.repeat,
            filterQuality: FilterQuality.none,
          ),
        ),
        child: SizedBox.expand(),
      ),
    ),
  );
}
