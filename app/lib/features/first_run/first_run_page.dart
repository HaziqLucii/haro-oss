import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/haro_api.dart' show HaroApiException;
import '../../api/models/models.dart';
import '../../data/workspace_store.dart';
import '../../overlays/overlay.dart' show haroOverlayDepth;
import '../../shortcuts/app_commands.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/check_mark.dart';
import '../../widgets/haro_button.dart';
import '../../widgets/status_square.dart';
import '../add_project/clone_runner.dart' show homeDirProvider;
import '../workspace/fade_in.dart';
import 'first_run_model.dart';
import 'first_run_providers.dart';

const _cardMax = 640.0;
const _pageGutter = 24.0;
const _pageGutterY = 16.0;
const _cardPadX = 30.0;
const _labelColumn = 130.0;
const _markColumn = 18.0;
const _washBleed = 10.0;
const _rowGap = 12.0;

/// §3. Opens after Add project and only shows the two checks the gate depends on: the
/// test runner and the baseline run. The one write (accepting a detected preset) waits
/// behind an explicit click that first shows the config it will write. The baseline
/// starts by itself once the runner is configured, and when both checks pass on a project
/// with no workspaces yet the page hands over to New workspace after a short beat; any
/// real decision (no runner, red or failed baseline, an unconfirmed preset), a click
/// during the beat, or an overlay opening keeps the page open.
class FirstRunPage extends ConsumerStatefulWidget {
  const FirstRunPage({super.key, required this.projectId});

  final String? projectId;

  @override
  ConsumerState<FirstRunPage> createState() => _FirstRunPageState();
}

class _FirstRunPageState extends ConsumerState<FirstRunPage> {
  StackPreset? _preview;
  bool _writing = false;
  String? _error;
  bool _acknowledged = false;
  bool _starting = false;
  String? _baselineError;
  bool _autoRan = false;
  bool _written = false;

  /// A run was already in flight when the preset was written, so its result is for the old
  /// config: run again once it ends, and never hand over on it.
  bool _rerunPending = false;
  bool _touched = false;
  Timer? _advanceTimer;

  String get _id => widget.projectId ?? '';

  @override
  void dispose() {
    _advanceTimer?.cancel();
    super.dispose();
  }

  /// Only a click that lands while a beat is pending cancels it: clicks while a preset is
  /// being confirmed must not forfeit the hand-over that follows the green run.
  void _touch() {
    if (_advanceTimer == null) return;
    _touched = true;
    _advanceTimer!.cancel();
    _advanceTimer = null;
  }

  void _advance() {
    _advanceTimer = null;
    if (!mounted || _touched) return;
    if (haroOverlayDepth.value > 0 ||
        ModalRoute.of(context)?.isCurrent == false) {
      _touched = true;
      return;
    }
    ref.read(firstRunAdvancedProvider.notifier).mark(_id);
    _commands.openNewWorkspace(_id);
  }

  /// Runs after the frame so the state changes never land inside build.
  void _sync({
    required bool autoRun,
    required bool advance,
    required bool rerun,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (autoRun && !_autoRan) {
        _autoRan = true;
        _runBaseline();
      }
      if (rerun && _rerunPending && !_starting) {
        _rerunPending = false;
        _runBaseline();
        advance = false;
      }
      if (advance && !_touched) {
        _advanceTimer ??= Timer(HaroTokens.beat, _advance);
      } else {
        _advanceTimer?.cancel();
        _advanceTimer = null;
      }
    });
  }

  Future<void> _runBaseline({bool afterWrite = false}) async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _baselineError = null;
    });
    final live = ref.read(firstRunBaselineLiveProvider(_id).notifier);
    try {
      await ref.read(haroApiProvider).runBaseline(_id);
      live.markRunning();
    } on HaroApiException catch (e) {
      if (e.status == 409) {
        if (afterWrite) _rerunPending = true;
        live.markRunning();
      } else if (mounted) {
        setState(
          () => _baselineError = 'Could not start the run: ${e.message}',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _baselineError = 'Could not start the run: $e');
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  AppCommands get _commands => ref.read(appCommandsProvider);

  Future<void> _write(StackPreset preset) async {
    setState(() {
      _writing = true;
      _error = null;
    });
    try {
      await ref.read(haroApiProvider).applyPreset(_id, preset.id);
      ref
        ..invalidate(firstRunRunnerProvider(_id))
        ..invalidate(firstRunScriptsProvider(_id));
      if (mounted) {
        setState(() {
          _writing = false;
          _preview = null;
          _written = true;
          _autoRan = true;
        });
        // The result for the old config says nothing about the one just written.
        unawaited(_runBaseline(afterWrite: true));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _writing = false;
          _error = 'Could not write the preset: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_id.isEmpty) return const _NotFound('No project selected');
    final project = ref.watch(firstRunProjectProvider(_id));
    final found = project.value;
    if (project.hasError) return const _NotFound('Could not reach the backend');
    if (!project.hasValue) return const SizedBox.shrink();
    if (found == null) return const _NotFound('Project not found');

    final runnerA = ref.watch(firstRunRunnerProvider(_id));
    final baselineA = ref.watch(firstRunBaselineProvider(_id));
    final baseline =
        ref.watch(firstRunBaselineLiveProvider(_id)) ?? baselineA.value;

    final facts = runnerA.hasValue
        ? runnerFacts(runnerA.requireValue, written: _written)
        : null;
    final rows = <DetectionRow>[
      if (facts != null)
        runnerRow(facts, baseline: baseline)
      else if (runnerA.hasError)
        const DetectionRow(
          id: 'runner',
          label: 'Test runner',
          finding: 'could not read the gate config',
          mark: RowMark.idle,
        ),
      if (baselineA.hasValue || baselineA.hasError)
        baselineRow(baseline, startError: _baselineError),
    ];

    final result = facts != null && baselineA.hasValue
        ? resultLine(facts, baseline: baseline, acknowledged: _acknowledged)
        : null;
    final blocked = result?.kind == ResultKind.baselineRed;
    final home = ref.watch(homeDirProvider);

    final configured = facts != null && facts.configured && !facts.offerFix;
    final advanced = ref.watch(firstRunAdvancedProvider).contains(_id);
    final store = ref.watch(workspaceStoreProvider);
    final firstRun =
        store.loaded && (store.workspaces[_id] ?? const []).isEmpty;
    _sync(
      autoRun:
          facts != null &&
          facts.configured &&
          baselineA.hasValue &&
          baseline == null &&
          !_starting,
      advance:
          configured &&
          firstRun &&
          !advanced &&
          !_rerunPending &&
          baselineA.hasValue &&
          baseline?.status == BaselineStatus.passed,
      rerun: _rerunPending && baseline != null && !baseline.running,
    );

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _touch(),
      child: _card(context, rows, result, blocked, home, found.path),
    );
  }

  Widget _card(
    BuildContext context,
    List<DetectionRow> rows,
    ResultLine? result,
    bool blocked,
    String? home,
    String path,
  ) {
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: _pageGutter,
          vertical: _pageGutterY,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: box.maxHeight - _pageGutterY * 2,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _cardMax),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: HaroTokens.panel,
                  border: Border.all(color: HaroTokens.line20),
                  borderRadius: BorderRadius.circular(HaroTokens.radius),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        _cardPadX,
                        26,
                        _cardPadX,
                        0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Header(path: tildify(path, home)),
                          const SizedBox(height: 18),
                          const _Rule(HaroTokens.line12),
                          for (final row in rows) ...[
                            FadeIn(
                              key: ValueKey('fr-fade-${row.id}'),
                              child: _RowView(
                                row: row,
                                actionBusy: _starting,
                                onAction: row.action == null
                                    ? null
                                    : _runBaseline,
                                onFix: row.fix == null
                                    ? null
                                    : () => setState(() {
                                        _preview = row.fix!.preset;
                                        _error = null;
                                      }),
                              ),
                            ),
                            if (row.id == 'runner' && _preview != null)
                              _PresetPreview(
                                preset: _preview!,
                                writing: _writing,
                                error: _error,
                                onWrite: () => _write(_preview!),
                                onCancel: () => setState(() => _preview = null),
                              ),
                          ],
                          const SizedBox(height: 18),
                          if (result != null)
                            FadeIn(
                              key: ValueKey('fr-result-${result.kind.name}'),
                              child: _ResultView(
                                result: result,
                                onContinue: () =>
                                    setState(() => _acknowledged = true),
                                onPickCommand: () =>
                                    _commands.openSettings(SettingsTab.gate),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const _Rule(HaroTokens.line12),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _cardPadX,
                        vertical: 16,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: HaroButton(
                              key: const ValueKey('fr-adjust'),
                              label: 'Adjust gate settings',
                              variant: HaroButtonVariant.tertiary,
                              padding: EdgeInsets.zero,
                              fontSize: 13.5,
                              onPressed: () =>
                                  _commands.openSettings(SettingsTab.gate),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Opacity(
                            opacity: blocked ? .42 : 1,
                            child: HaroButton(
                              key: const ValueKey('fr-create'),
                              label: 'Create first workspace',
                              variant: HaroButtonVariant.primary,
                              height: 34,
                              fontSize: 13.5,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              onPressed: blocked
                                  ? null
                                  : () => _commands.openNewWorkspace(_id),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'ADDING $path',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: HaroText.mono(
          size: 10.5,
          tracking: .16,
          color: HaroTokens.ink42,
        ),
      ),
      const SizedBox(height: 10),
      Text(
        'Checking how this project proves itself',
        style: HaroText.ui(
          size: 26,
          weight: FontWeight.w500,
          height: 1.2,
        ).copyWith(letterSpacing: -0.39),
      ),
      const SizedBox(height: 6),
      Text(
        'haro needs a test suite it can trust before any agent’s work can merge. '
        'This takes a few seconds.',
        style: HaroText.ui(size: 14, color: HaroTokens.ink66, height: 1.5),
      ),
    ],
  );
}

class _Rule extends StatelessWidget {
  const _Rule(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 1, child: ColoredBox(color: color));
}

/// A passed check reads as a tick; anything still open keeps the status square.
Widget _mark(RowMark mark) => switch (mark) {
  RowMark.gate => const CheckMark(color: HaroTokens.gate),
  _ => _square(mark),
};

StatusSquare _square(RowMark mark, {double size = 9}) => switch (mark) {
  RowMark.gate => StatusSquare(
    size: size,
    color: HaroTokens.gate,
    filled: true,
  ),
  RowMark.progress => StatusSquare(
    size: size,
    color: HaroTokens.ink,
    filled: false,
  ),
  RowMark.idle => StatusSquare(
    size: size,
    color: HaroTokens.ink42,
    filled: false,
  ),
  RowMark.fail => StatusSquare(
    size: size,
    color: HaroTokens.fail,
    filled: true,
  ),
};

class _RowView extends StatelessWidget {
  const _RowView({
    required this.row,
    this.onFix,
    this.onAction,
    this.actionBusy = false,
  });

  final DetectionRow row;
  final VoidCallback? onFix;
  final VoidCallback? onAction;
  final bool actionBusy;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: ValueKey('fr-row-${row.id}'),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: HaroTokens.line08)),
    ),
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        if (row.mark == RowMark.gate)
          // Bleeds past the columns so the text stays on the grid.
          const Positioned(
            key: ValueKey('fr-wash'),
            left: -_washBleed,
            right: -_washBleed,
            top: 0,
            bottom: 0,
            child: ColoredBox(color: HaroTokens.gateWash),
          ),
        _content(),
      ],
    ),
  );

  Widget _content() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 13),
    child: Row(
      children: [
        SizedBox(
          width: _markColumn,
          child: Align(alignment: Alignment.centerLeft, child: _mark(row.mark)),
        ),
        SizedBox(
          width: _labelColumn,
          child: Text(
            row.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HaroText.ui(size: 14),
          ),
        ),
        const SizedBox(width: _rowGap - 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.finding,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: HaroText.mono(
                  size: 12,
                  tracking: 0,
                  color: HaroTokens.ink66,
                ),
              ),
              for (final line in row.details)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    line,
                    key: ValueKey('fr-detail-${row.id}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HaroText.mono(
                      size: 11.5,
                      tracking: 0,
                      color: HaroTokens.ink42,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (onAction != null) ...[
          const SizedBox(width: _rowGap),
          HaroButton(
            key: ValueKey('fr-action-${row.id}'),
            label: row.action!,
            height: 26,
            fontSize: 12.5,
            foreground: HaroTokens.ink,
            onPressed: actionBusy ? null : onAction,
          ),
        ],
        if (onFix != null) ...[
          const SizedBox(width: _rowGap),
          HaroButton(
            key: ValueKey('fr-fix-${row.id}'),
            label: row.fix!.label,
            height: 26,
            fontSize: 12.5,
            foreground: HaroTokens.ink,
            onPressed: onFix,
          ),
        ],
      ],
    ),
  );
}

class _PresetPreview extends StatelessWidget {
  const _PresetPreview({
    required this.preset,
    required this.writing,
    required this.error,
    required this.onWrite,
    required this.onCancel,
  });

  final StackPreset preset;
  final bool writing;
  final String? error;
  final VoidCallback onWrite;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final toml = preset.toml.trim();
    return FadeIn(
      key: ValueKey('fr-preview-${preset.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          key: const ValueKey('fr-preview'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'WILL WRITE TO .HARO/SETTINGS.TOML (COMMITTED)',
              style: HaroText.mono(
                size: 10.5,
                tracking: .14,
                color: HaroTokens.ink42,
              ),
            ),
            const SizedBox(height: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: HaroTokens.raised,
                border: Border.all(color: HaroTokens.line08),
                borderRadius: BorderRadius.circular(HaroTokens.radius),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    toml.isEmpty ? '# no config written' : toml,
                    key: const ValueKey('fr-preview-toml'),
                    style: HaroText.mono(
                      size: 12,
                      tracking: 0,
                      color: HaroTokens.ink86,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error!,
                style: HaroText.mono(
                  size: 11.5,
                  tracking: 0,
                  color: HaroTokens.fail,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                HaroButton(
                  key: const ValueKey('fr-write'),
                  label: writing ? 'Writing' : 'Write to .haro/settings.toml',
                  height: 28,
                  fontSize: 12.5,
                  foreground: HaroTokens.ink,
                  onPressed: writing ? null : onWrite,
                ),
                const SizedBox(width: 8),
                HaroButton(
                  key: const ValueKey('fr-preview-cancel'),
                  label: 'Cancel',
                  variant: HaroButtonVariant.tertiary,
                  height: 28,
                  fontSize: 12.5,
                  onPressed: writing ? null : onCancel,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({
    required this.result,
    required this.onContinue,
    required this.onPickCommand,
  });

  final ResultLine result;
  final VoidCallback onContinue;
  final VoidCallback onPickCommand;

  @override
  Widget build(BuildContext context) {
    final ready = result.kind == ResultKind.ready;
    final red = result.kind == ResultKind.baselineRed;
    final square = ready
        ? StatusSquare(size: 12, color: HaroTokens.gate, filled: true)
        : red || result.kind == ResultKind.baselineError
        ? StatusSquare(size: 12, color: HaroTokens.fail, filled: true)
        : StatusSquare(size: 12, color: HaroTokens.ink, filled: false);
    return Column(
      key: const ValueKey('fr-result'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            square,
            Text(
              result.headline,
              style: HaroText.ui(size: 16, weight: FontWeight.w500),
            ),
            if (result.detail.isNotEmpty)
              Text(
                result.detail,
                style: HaroText.ui(size: 14, color: HaroTokens.ink66),
              ),
          ],
        ),
        if (red) ...[
          const SizedBox(height: 12),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              IntrinsicWidth(
                child: HaroButton(
                  key: const ValueKey('fr-continue'),
                  label: 'Continue anyway',
                  height: 28,
                  fontSize: 12.5,
                  foreground: HaroTokens.ink,
                  onPressed: onContinue,
                ),
              ),
              Text(
                '(the gate compares against this baseline)',
                style: HaroText.ui(size: 13, color: HaroTokens.ink42),
              ),
              IntrinsicWidth(
                child: HaroButton(
                  key: const ValueKey('fr-pick-command'),
                  label: 'Pick a different test command',
                  variant: HaroButtonVariant.tertiary,
                  height: 28,
                  fontSize: 12.5,
                  onPressed: onPickCommand,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _NotFound extends StatelessWidget {
  const _NotFound(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          message.toUpperCase(),
          style: HaroText.mono(color: HaroTokens.ink42),
        ),
        const SizedBox(height: 12),
        HaroButton(
          key: const ValueKey('fr-back'),
          label: 'Back to dashboard',
          variant: HaroButtonVariant.tertiary,
          onPressed: () => context.go('/'),
        ),
      ],
    ),
  );
}
