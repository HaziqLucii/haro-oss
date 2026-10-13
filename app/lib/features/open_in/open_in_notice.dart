import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';

/// A failed open, shown next to the control that started it. [source] names that control
/// (`header`, `code`, `verify-look`) so only one place shows it.
@immutable
class OpenInNotice {
  const OpenInNotice(this.source, this.message);

  final String source;
  final String message;
}

const openInNoticeDuration = Duration(seconds: 6);

class OpenInNoticeNotifier extends Notifier<OpenInNotice?> {
  Timer? _timer;

  @override
  OpenInNotice? build() {
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  void show(String source, String message) {
    _timer?.cancel();
    state = OpenInNotice(source, message);
    _timer = Timer(openInNoticeDuration, clear);
  }

  void clear() {
    _timer?.cancel();
    _timer = null;
    state = null;
  }
}

final openInNoticeProvider =
    NotifierProvider<OpenInNoticeNotifier, OpenInNotice?>(
      OpenInNoticeNotifier.new,
    );

/// The mono red line for [source], or nothing.
class OpenInNoticeText extends ConsumerWidget {
  const OpenInNoticeText({super.key, required this.source, this.padding});

  final String source;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(
      openInNoticeProvider.select(
        (n) => n?.source == source ? n!.message : null,
      ),
    );
    if (message == null) return const SizedBox.shrink();
    final text = Text(
      message,
      key: ValueKey('open-in-notice-$source'),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: HaroText.mono(size: 11, color: HaroTokens.fail, tracking: 0),
    );
    return padding == null ? text : Padding(padding: padding!, child: text);
  }
}
