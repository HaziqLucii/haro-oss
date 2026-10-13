import 'package:flutter/material.dart';

import '../theme/haro_theme.dart';
import '../theme/tokens.dart';

/// A file path on one line. When it is too long the folders give way (`.haro/no...`) and the file
/// name stays whole; the full path is the tooltip.
class PathLine extends StatelessWidget {
  const PathLine(this.path, {super.key, this.prefix = ''});

  final String path;

  /// Shown before [path] (the folder the path is relative to), shortened first.
  final String prefix;

  @override
  Widget build(BuildContext context) {
    final cut = path.lastIndexOf('/') + 1;
    final dir = '$prefix${path.substring(0, cut)}';
    final style = HaroText.mono(size: 11, tracking: 0, color: HaroTokens.ink42);
    return Tooltip(
      message: '$prefix$path',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dir.isNotEmpty)
            Flexible(
              child: Text(
                dir,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: style,
              ),
            ),
          Text(
            path.substring(cut),
            maxLines: 1,
            softWrap: false,
            style: style.copyWith(color: HaroTokens.ink66),
          ),
        ],
      ),
    );
  }
}
