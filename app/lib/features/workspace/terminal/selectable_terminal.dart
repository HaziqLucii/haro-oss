import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

/// A [TerminalView] whose mouse selection can run past one screen.
///
/// The widget's own drag selection reads the pointer against the view as it is NOW and never
/// scrolls, so a selection stops at the edge of a panel only a third of the window tall: the
/// output of a long command could not be copied. Here a drag remembers the buffer cell it
/// started on (as an anchor, so output that keeps streaming cannot shift it), scrolls while the
/// pointer is held above or below the view, and re-extends the selection each tick. Raw pointer
/// events, not a gesture recognizer: a recognizer on top would win a plain click by default and
/// take the terminal's taps with it. Taps, double-click word selection, the wheel and the copy
/// shortcut stay the widget's own. A program that asked for the mouse (vim, htop) keeps it: this
/// stays out of the way while the terminal reports mouse events.
class SelectableTerminal extends StatefulWidget {
  const SelectableTerminal(
    this.terminal, {
    super.key,
    this.viewKey,
    this.controller,
    this.readOnly = false,
    this.autofocus = false,
    this.theme = TerminalThemes.defaultTheme,
    this.textStyle = const TerminalStyle(),
    this.padding,
  });

  final Terminal terminal;

  /// Goes on the [TerminalView] itself.
  final Key? viewKey;

  /// The selection lives here; created (and disposed) here when null.
  final TerminalController? controller;
  final bool readOnly;
  final bool autofocus;
  final TerminalTheme theme;
  final TerminalStyle textStyle;
  final EdgeInsets? padding;

  @override
  State<SelectableTerminal> createState() => _SelectableTerminalState();
}

class _SelectableTerminalState extends State<SelectableTerminal> {
  static const _tick = Duration(milliseconds: 40);
  static const _slop = 3.0;

  late TerminalController _controller;
  final _scroll = ScrollController();
  TerminalViewState? _view;
  Timer? _timer;
  Offset? _down;
  Offset? _pointer;
  int? _pointerId;
  CellAnchor? _start;

  /// A drag is under way (the pointer moved past the slop).
  bool get _dragging => _timer != null;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TerminalController();
  }

  @override
  void didUpdateWidget(SelectableTerminal old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      if (old.controller == null) _controller.dispose();
      _controller = widget.controller ?? TerminalController();
      _endDrag();
    }
    if (old.viewKey != widget.viewKey) _view = null;
  }

  @override
  void dispose() {
    _endDrag();
    _scroll.dispose();
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  TerminalViewState? _viewState() {
    if (_view != null && _view!.mounted) return _view;
    TerminalViewState? found;
    void visit(Element e) {
      if (found != null) return;
      if (e is StatefulElement && e.state is TerminalViewState) {
        found = e.state as TerminalViewState;
        return;
      }
      e.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    return _view = found;
  }

  void _onDown(PointerDownEvent e) {
    _endDrag();
    // A read-only view never forwards the mouse, so a stuck mouse mode there is no reason to
    // leave selecting alone.
    final mouseOwned =
        !widget.readOnly && widget.terminal.mouseMode != MouseMode.none;
    if (e.kind != PointerDeviceKind.mouse ||
        e.buttons != kPrimaryButton ||
        mouseOwned) {
      return;
    }
    final view = _viewState();
    if (view == null) return;
    _down = e.localPosition;
    _pointer = e.localPosition;
    _pointerId = e.pointer;
    // Hear the end of this press wherever it lands, even if a dialog or another route takes
    // the pointer: a timer left running would keep scrolling on its own.
    GestureBinding.instance.pointerRouter.addRoute(e.pointer, _route);
    final cell = view.renderTerminal.getCellOffset(e.localPosition);
    _start = widget.terminal.buffer.createAnchorFromOffset(cell);
  }

  void _onMove(PointerMoveEvent e) {
    final down = _down;
    if (down == null) return;
    _pointer = e.localPosition;
    if (!_dragging) {
      if ((e.localPosition - down).distance < _slop) {
        return;
      }
      _timer = Timer.periodic(_tick, (_) => _scrollAndExtend());
    }
    // The widget's own drag handler runs after this event and writes a selection measured
    // from where the view was when the drag began: ours goes in after it.
    scheduleMicrotask(_extend);
  }

  void _route(PointerEvent e) {
    if (e is PointerUpEvent || e is PointerCancelEvent) _endDrag();
  }

  void _endDrag() {
    _timer?.cancel();
    _timer = null;
    final id = _pointerId;
    if (id != null) {
      GestureBinding.instance.pointerRouter.removeRoute(id, _route);
    }
    _pointerId = null;
    _start?.dispose();
    _start = null;
    _down = null;
    _pointer = null;
  }

  /// While the pointer is held outside the view, scroll toward it: faster the further out.
  void _scrollAndExtend() {
    final view = _viewState();
    final pointer = _pointer;
    if (view == null || pointer == null || !_scroll.hasClients) return;
    final height = view.renderTerminal.size.height;
    double delta = 0;
    if (pointer.dy < 0) {
      delta = -(4 + (-pointer.dy) / 2).clamp(4.0, 48.0);
    } else if (pointer.dy > height) {
      delta = (4 + (pointer.dy - height) / 2).clamp(4.0, 48.0);
    }
    if (delta == 0) return;
    final to = (_scroll.offset + delta).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    if (to == _scroll.offset) return;
    _scroll.jumpTo(to);
    _extend();
  }

  void _extend() {
    final view = _viewState();
    final start = _start;
    final pointer = _pointer;
    if (!_dragging || view == null || start == null || pointer == null) return;
    if (!start.attached) {
      // The line it began on has scrolled out of the buffer: nothing to anchor to.
      _endDrag();
      return;
    }
    final from = start.offset;
    final cell = view.renderTerminal.getCellOffset(pointer);
    final forward = cell.y > from.y || (cell.y == from.y && cell.x >= from.x);
    // Both ends are inclusive of the cell under them: a drag that runs backward (the pointer
    // held above the panel) must still take the character it started on.
    final base = forward ? from : CellOffset(from.x + 1, from.y);
    final end = forward ? CellOffset(cell.x + 1, cell.y) : cell;
    final buffer = widget.terminal.buffer;
    _controller.setSelection(
      buffer.createAnchorFromOffset(base),
      buffer.createAnchorFromOffset(end),
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: TerminalView(
          widget.terminal,
          key: widget.viewKey,
          controller: _controller,
          scrollController: _scroll,
          readOnly: widget.readOnly,
          autofocus: widget.autofocus,
          theme: widget.theme,
          textStyle: widget.textStyle,
          padding: widget.padding,
        ),
      ),
      Positioned.fill(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onDown,
          onPointerMove: _onMove,
        ),
      ),
    ],
  );
}
