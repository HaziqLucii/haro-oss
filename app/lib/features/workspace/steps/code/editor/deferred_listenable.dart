import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// A [ListenableBuilder] that survives a notification fired while the tree is building.
/// re_editor's controller notifies from `CodeEditor.initState` (it swaps its delegate in), so
/// any sibling already listening would be marked dirty mid-build; here that rebuild waits for
/// the end of the frame instead.
class DeferredListenableBuilder extends StatefulWidget {
  const DeferredListenableBuilder({
    super.key,
    required this.listenable,
    required this.builder,
  });

  final Listenable listenable;
  final Widget Function(BuildContext context) builder;

  @override
  State<DeferredListenableBuilder> createState() => _State();
}

class _State extends State<DeferredListenableBuilder> {
  bool _queued = false;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(DeferredListenableBuilder old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_queued) return;
      _queued = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _queued = false;
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
