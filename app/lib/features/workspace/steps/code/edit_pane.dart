import 'dart:async' show scheduleMicrotask;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart';

import '../../../../data/workspace_detail.dart' show workspaceDetailProvider;
import '../../../../data/workspace_detail_lazy.dart'
    show workspaceImpactProvider;
import '../../../../data/workspace_store.dart' show haroApiProvider;
import '../../../../lsp/lsp_client.dart';
import '../../../../lsp/lsp_diagnostics.dart';
import '../../../../lsp/lsp_completion.dart';
import '../../../../lsp/lsp_definition.dart';
import '../../../../lsp/lsp_format.dart';
import '../../../../lsp/lsp_hover.dart';
import '../../../../lsp/lsp_document.dart';
import '../../../../lsp/lsp_providers.dart';
import '../../../../overlays/toast.dart';
import '../../../../shortcuts/app_commands.dart';
import '../../../../shortcuts/platform_keys.dart';
import '../../../../theme/coding_font.dart';
import '../../../../theme/display_scope.dart';
import '../../../../theme/haro_theme.dart';
import '../../../../theme/tokens.dart';
import '../../../../widgets/haro_button.dart';
import '../../../../widgets/haro_pressable.dart';
import '../../../settings/editor_prefs_provider.dart';
import '../../terminal/bottom_panel_provider.dart';
import '../../terminal/panel_model.dart' show canRunRelated;
import '../../terminal/related_tests.dart';
import '../agent/composer_logic.dart' show formatBytes;
import 'code_tokens.dart';
import 'edit_buffer.dart';
import 'go_to_line.dart';
import 'proof_marks.dart' show ProofMark, diagnosticMarks, mergeProofMarks;
import 'editor/deferred_listenable.dart';
import 'editor/editor_gutter.dart';
import 'editor/editor_marks.dart';
import 'editor/editor_tabs.dart'
    show EditorJump, EditorPlace, EditorTabsNotifier, editorTabsProvider;
import 'editor/lsp_completion_view.dart';
import 'editor/lsp_hover_layer.dart';
import 'editor/minimap.dart';
import 'syntax.dart';

/// Syntax highlighting runs in a background isolate, which widget tests cannot pump.
@visibleForTesting
bool codeEditorHighlighting = true;

/// Edit tab body: the editor with its gutter, indent guides and minimap, a find bar (⌘F) and the
/// status footer. The buffer belongs to the store; this only draws it.
class EditPane extends ConsumerWidget {
  const EditPane({
    super.key,
    required this.buffer,
    required this.onSave,
    this.fontSize = 13,
    this.minimap = true,
    this.marks = const {},
    this.ran = const {},
    this.proof = const {},
    this.jump,
    this.onJumped,
    this.workspaceId,
  });

  final EditBuffer buffer;
  final VoidCallback onSave;
  final int fontSize;
  final bool minimap;

  /// Lets an image file load from the backend and the palette act on this workspace; without
  /// it (a bare editor) images fall back to the not-opened note.
  final String? workspaceId;

  /// Change bars and "line ran" dots for the saved text; empty while the buffer is dirty.
  final Map<int, ChangeMark> marks;
  final Set<int> ran;

  /// Gate findings per saved line (needs-your-eyes); empty while dirty.
  final Map<int, List<ProofMark>> proof;

  /// A line to reveal once the editor is up, and the callback that marks it handled.
  final EditorJump? jump;
  final ValueChanged<int>? onJumped;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wordWrap = ref.watch(editorPrefsProvider.select((p) => p.wordWrap));
    return ListenableBuilder(
      listenable: buffer,
      builder: (context, _) => switch (buffer.phase) {
        BufferPhase.loading => const _Note('LOADING…'),
        BufferPhase.failed => _Note(
          'Could not read this file: ${buffer.loadError ?? 'unknown error'}',
          error: true,
        ),
        BufferPhase.guarded =>
          workspaceId != null && isImagePath(buffer.path)
              ? _ImagePreview(
                  key: ValueKey('image:${buffer.path}'),
                  buffer: buffer,
                  workspaceId: workspaceId!,
                )
              : _Note(guardText(buffer)),
        BufferPhase.mixedEndings => const _Note(mixedEndingsNote),
        BufferPhase.ready => _ReadyEditor(
          key: ValueKey(buffer.path),
          buffer: buffer,
          onSave: onSave,
          fontSize: fontSize,
          minimap: minimap,
          wordWrap: wordWrap,
          marks: marks,
          ran: ran,
          proof: proof,
          jump: jump,
          onJumped: onJumped,
          workspaceId: workspaceId,
        ),
      },
    );
  }
}

String guardText(EditBuffer b) {
  final why = b.guardReason ?? 'not editable';
  final size = b.guardSize;
  return size == null ? 'Not opened: $why.' : 'Not opened: $why ($size bytes).';
}

/// How the preview loads the picture. Tests swap it for an in-memory image.
@visibleForTesting
ImageProvider Function(String url) imageProviderFor = NetworkImage.new;

/// An image file the backend refused to open as text, drawn from `/raw`. The query carries the
/// bump counter (buffer changes and fs events touching the file) so a rewrite by the agent is not
/// served from Flutter's image cache. A guarded buffer never stores an etag, so it cannot key it.
class _ImagePreview extends ConsumerStatefulWidget {
  const _ImagePreview({
    super.key,
    required this.buffer,
    required this.workspaceId,
  });

  final EditBuffer buffer;
  final String workspaceId;

  @override
  ConsumerState<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends ConsumerState<_ImagePreview> {
  int _version = 0;

  @override
  void initState() {
    super.initState();
    widget.buffer.addListener(_onBuffer);
  }

  @override
  void dispose() {
    widget.buffer.removeListener(_onBuffer);
    super.dispose();
  }

  void _onBuffer() => setState(() => _version++);

  @override
  Widget build(BuildContext context) {
    final b = widget.buffer;
    ref.listen(
      workspaceDetailProvider(widget.workspaceId).select((d) => d.lastFs),
      (_, e) {
        final touched =
            e != null &&
            (e.truncated ||
                e.paths.isEmpty ||
                e.paths.any((p) => p.path == b.path));
        if (touched) setState(() => _version++);
      },
    );
    final raw = ref.read(haroApiProvider).rawUrl(widget.workspaceId, b.path);
    final url = raw.replace(
      queryParameters: {...raw.queryParameters, 'v': '$_version'},
    );
    final size = b.guardSize;
    final name = b.path.split('/').last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Image(
                key: const ValueKey('image-preview'),
                image: imageProviderFor(url.toString()),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.none,
                errorBuilder: (_, _, _) => _Note(guardText(b)),
              ),
            ),
          ),
        ),
        Container(
          height: CodeTokens.editorFooterHeight,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.centerLeft,
          decoration: const BoxDecoration(
            color: HaroTokens.bg,
            border: Border(top: BorderSide(color: HaroTokens.line08)),
          ),
          child: Text(
            size == null ? name : '$name · ${formatBytes(size)}',
            key: const ValueKey('image-caption'),
            style: HaroText.mono(
              size: 11,
              color: HaroTokens.ink42,
              tracking: 0,
            ),
          ),
        ),
      ],
    );
  }
}

class _ReadyEditor extends ConsumerStatefulWidget {
  const _ReadyEditor({
    super.key,
    required this.buffer,
    required this.onSave,
    required this.fontSize,
    required this.minimap,
    required this.wordWrap,
    required this.marks,
    required this.ran,
    required this.proof,
    this.jump,
    this.onJumped,
    this.workspaceId,
  });

  final EditBuffer buffer;
  final VoidCallback onSave;
  final int fontSize;
  final bool minimap;
  final bool wordWrap;
  final Map<int, ChangeMark> marks;
  final Set<int> ran;
  final Map<int, List<ProofMark>> proof;
  final EditorJump? jump;
  final ValueChanged<int>? onJumped;
  final String? workspaceId;

  @override
  ConsumerState<_ReadyEditor> createState() => _ReadyEditorState();
}

class _ReadyEditorState extends ConsumerState<_ReadyEditor> {
  late final CodeFindController _find = CodeFindController(
    widget.buffer.controller!,
  );
  final _scroll = CodeScrollController();
  final _themes = <bool, CodeHighlightTheme?>{};
  final _editorFocus = FocusNode();
  final _goController = TextEditingController();
  final _goFocus = FocusNode();
  CodeIndicatorValueNotifier? _indicator;
  late final int _unit = _detectUnit(widget.buffer.controller!.codeLines);
  late final CodeCommentFormatter? _comments = commentFormatterFor(
    languageForPath(widget.buffer.path),
  );
  late final AppCommandsNotifier _commands;
  late final EditorTabsNotifier? _tabs;
  LspClient? _lsp;
  LspDocument? _lspDoc;
  LspCompletionController? _completion;
  LspHoverController? _hover;
  List<LspDiagnostic>? _diagFrom;
  Map<int, List<ProofMark>> _diagMarks = const {};
  Map<int, List<ProofMark>>? _mergedFrom;
  Map<int, List<ProofMark>> _merged = const {};
  late final VoidCallback _goToLineCommand = _openGoToLine;
  late final VoidCallback _relatedCommand = _runRelated;
  late final VoidCallback _definitionCommand = _goToDefinition;
  late final Future<void> Function() _formatHook = _formatBeforeSave;
  int _jumped = 0;
  bool _goOpen = false;
  bool _goInvalid = false;

  static int _detectUnit(CodeLines lines) => indentUnit([
    for (var i = 0; i < lines.length && i < 400; i++) lines[i].text,
  ]);

  /// Kept per mode: re_editor re-highlights whenever the theme instance changes.
  CodeHighlightTheme? _theme(bool colour) => _themes.putIfAbsent(colour, () {
    final lang = languageForPath(widget.buffer.path);
    final mode = modeForLanguage(lang);
    if (mode == null || !codeEditorHighlighting) return null;
    return CodeHighlightTheme(
      languages: {
        for (final e in modesForEditor(lang!).entries)
          e.key: CodeHighlightThemeMode(mode: e.value),
      },
      theme: syntaxStyles(colour: colour),
    );
  });

  @override
  void initState() {
    super.initState();
    _commands = ref.read(appCommandsProvider.notifier);
    final id = widget.workspaceId;
    _tabs = id == null ? null : ref.read(editorTabsProvider(id).notifier);
    _startLsp(id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final y = widget.buffer.scrollOffset;
      final s = _scroll.verticalScroller;
      s.addListener(_rememberScroll);
      if (y > 0 && s.hasClients) {
        s.jumpTo(y.clamp(0, s.position.maxScrollExtent));
      } else if (!_jumpPending) {
        _restorePlace();
      }
      _maybeJump();
      _commands.register(
        (c) => c.copyWith(
          goToLine: _goToLineCommand,
          runRelatedTests: _relatedCommand,
          goToDefinition: _lsp == null
              ? const AppCommands().goToDefinition
              : _definitionCommand,
        ),
      );
    });
  }

  /// TS/JS buffers get completion from the workspace's language server; every other file
  /// keeps the plain editor, overlay and all.
  void _startLsp(String? workspaceId) {
    final lang = lspLanguageId(widget.buffer.path);
    if (workspaceId == null || lang == null) return;
    final client = ref.read(lspClientProvider(workspaceId));
    if (client.rootPath.isEmpty) return;
    final controller = widget.buffer.controller!;
    final uri = lspDocumentUri(client.rootPath, widget.buffer.path);
    _lsp = client
      ..addListener(_onLsp)
      ..diagnosticsFeed.addListener(_onDiagnostics);
    _lspDoc = LspDocument(
      client: client,
      uri: uri,
      languageId: lang,
      controller: controller,
    )..open();
    _completion = LspCompletionController(
      client: client,
      uri: uri,
      controller: controller,
    );
    _hover = LspHoverController(client: client, uri: uri);
    widget.buffer.addBeforeSave(_formatHook);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onLsp());
  }

  String? get _lspUri {
    final client = _lsp;
    return client == null
        ? null
        : lspDocumentUri(client.rootPath, widget.buffer.path);
  }

  void _onDiagnostics() {
    if (mounted) setState(() {});
  }

  /// The gate's saved-line marks plus the server's live diagnostics for this file. Diagnostics
  /// are not held back while the buffer is dirty: the server republishes after every edit.
  Map<int, List<ProofMark>> _gutterMarks() {
    final uri = _lspUri;
    final items = uri == null
        ? const <LspDiagnostic>[]
        : _lsp!.diagnosticsOf(uri);
    if (!identical(items, _diagFrom)) {
      _diagFrom = items;
      _diagMarks = diagnosticMarks(items);
      _mergedFrom = null;
    }
    if (!identical(widget.proof, _mergedFrom)) {
      _mergedFrom = widget.proof;
      _merged = mergeProofMarks(widget.proof, _diagMarks);
    }
    return _merged;
  }

  /// The quiet one-line notice, once per workspace however many editors are open.
  void _onLsp() {
    final client = _lsp;
    if (!mounted || client == null || !client.takeNotice()) return;
    showHaroToast(context, client.unavailableReason ?? lspInstallHint);
  }

  @override
  void didUpdateWidget(_ReadyEditor old) {
    super.didUpdateWidget(old);
    if (widget.jump?.serial != old.jump?.serial) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeJump());
    }
  }

  bool get _jumpPending {
    final j = widget.jump;
    return j != null && j.serial > _jumped;
  }

  /// A buffer that was never scrolled (just loaded, or the app just started) opens where the
  /// cursor and scroll were last time. A buffer kept across a step switch already holds both.
  void _restorePlace() {
    final id = widget.workspaceId;
    if (id == null) return;
    final place = ref.read(editorTabsProvider(id)).places[widget.buffer.path];
    if (place == null) return;
    final c = widget.buffer.controller!;
    final at = _visiblePosition(place.line, place.col);
    c.selection = CodeLineSelection.collapsed(
      index: at.index,
      offset: at.offset,
    );
    final s = _scroll.verticalScroller;
    if (place.scroll > 0 && s.hasClients) {
      s.jumpTo(place.scroll.clamp(0, s.position.maxScrollExtent));
    }
  }

  void _maybeJump() {
    final j = widget.jump;
    if (!mounted || j == null || j.serial <= _jumped) return;
    _jumped = j.serial;
    _revealLine(j.line, j.col);
    widget.onJumped?.call(j.serial);
  }

  /// Where 1-based file [line] and [col] sit among the editor's visible lines. Lines (from the
  /// server, a jump, a saved place) count every line, folded or not, while the selection and
  /// `codeLines` count only the visible ones: a target hidden inside a fold unfolds it.
  CodeLinePosition _visiblePosition(int line, int col) {
    final c = widget.buffer.controller!;
    final full = lineIndexFor(line, c.lineCount);
    var at = c.lineIndex2Index(full);
    for (var i = 0; at.chunkIndex >= 0 && i < 16; i++) {
      c.expandChunk(at.index);
      at = c.lineIndex2Index(full);
    }
    final index = at.index >= 0
        ? at.index
        : lineIndexFor(line, c.codeLines.length);
    return CodeLinePosition(
      index: index,
      offset: (col - 1).clamp(0, c.codeLines[index].length),
    );
  }

  void _revealLine(int line, [int col = 1]) {
    final c = widget.buffer.controller!;
    final at = _visiblePosition(line, col);
    c.selection = CodeLineSelection.collapsed(
      index: at.index,
      offset: at.offset,
    );
    _scroll.makeCenterIfInvisible(at);
  }

  void _openGoToLine() {
    if (!mounted) return;
    setState(() {
      _goOpen = true;
      _goInvalid = false;
    });
    _goController.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _goFocus.requestFocus();
    });
  }

  void _closeGoToLine() {
    setState(() => _goOpen = false);
    _editorFocus.requestFocus();
  }

  void _submitGoToLine(String text) {
    final line = parseLineNumber(text);
    if (line == null) {
      setState(() => _goInvalid = true);
      return;
    }
    _revealLine(line);
    _closeGoToLine();
  }

  /// The buffer's save hook: with Format on save on, the server formats the text first. It
  /// reads the setting at save time, so toggling it needs no editor rebuild.
  Future<void> _formatBeforeSave() async {
    final client = _lsp;
    final uri = _lspUri;
    if (client == null || uri == null || !mounted) return;
    if (!ref.read(editorPrefsProvider).formatOnSave) return;
    final controller = widget.buffer.controller!;
    await formatBuffer(
      client: client,
      uri: uri,
      controller: controller,
      unit: _detectUnit(controller.codeLines),
    );
  }

  /// F12 and the palette's "Go to definition": the first location the server reports. A target
  /// in the worktree opens at its line and column; one outside it (a dependency behind the
  /// worktree's `node_modules` symlink) is named in a toast. No answer does nothing.
  Future<void> _goToDefinition() async {
    final client = _lsp;
    final uri = _lspUri;
    final tabs = _tabs;
    if (client == null || uri == null || tabs == null || !mounted) return;
    final c = widget.buffer.controller!;
    final jump = await resolveDefinition(
      client,
      uri,
      c.index2lineIndex(c.selection.extentIndex),
      c.selection.extentOffset,
    );
    if (!mounted || jump == null) return;
    switch (jump) {
      case OpenDefinition():
        tabs.open(jump.path, line: jump.line, col: jump.column);
      case OutsideDefinition():
        showHaroToast(
          context,
          'Definition is outside this workspace: ${jump.label}',
        );
    }
  }

  /// The palette's "Run the tests touching this file": same eligibility as the Gate tab row,
  /// and the result lands on that tab.
  Future<void> _runRelated() async {
    final id = widget.workspaceId;
    if (id == null || !mounted) return;
    final path = widget.buffer.path;
    final api = ref.read(haroApiProvider);
    final panel = ref.read(bottomPanelProvider(id).notifier);
    String? refusal;
    try {
      final impact = await ref.read(workspaceImpactProvider(id).future);
      if (!canRunRelated(path, impact)) {
        refusal = 'No test run is available for this file.';
      } else {
        panel.show(BottomTab.gate);
        refusal = await startRelatedRun(api, id, path);
      }
    } on Object {
      refusal = 'Could not start the run.';
    }
    if (refusal != null && mounted) showHaroToast(context, refusal);
  }

  /// Remembered as it changes: by dispose the scrollable is already detached.
  void _rememberScroll() {
    final s = _scroll.verticalScroller;
    if (s.hasClients) widget.buffer.scrollOffset = s.offset;
  }

  /// Tells the tab state where this editor was as it closes. Deferred to a microtask: dispose
  /// runs while the tree is locked, and a provider write there would rebuild its listeners.
  void _reportPlace() {
    final tabs = _tabs;
    if (tabs == null) return;
    final c = widget.buffer.controller;
    final sel = c?.selection;
    if (c == null || sel == null) return;
    final place = EditorPlace(
      line: c.index2lineIndex(sel.extentIndex) + 1,
      col: sel.extentOffset + 1,
      scroll: widget.buffer.scrollOffset,
    );
    final path = widget.buffer.path;
    scheduleMicrotask(() {
      try {
        tabs.rememberPlace(path, place);
      } catch (_) {
        // The scope was torn down first (app or test shutdown): nothing left to tell.
      }
    });
  }

  @override
  void dispose() {
    _scroll.verticalScroller.removeListener(_rememberScroll);
    _reportPlace();
    widget.buffer.removeBeforeSave(_formatHook);
    _lsp?.removeListener(_onLsp);
    _lsp?.diagnosticsFeed.removeListener(_onDiagnostics);
    _lspDoc?.close();
    _completion?.dispose();
    _hover?.dispose();
    _find.dispose();
    _editorFocus.dispose();
    _goController.dispose();
    _goFocus.dispose();
    final commands = _commands;
    final go = _goToLineCommand;
    final related = _relatedCommand;
    final definition = _definitionCommand;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Only take our own callbacks back: the next file's editor may already own them.
      if (!commands.alive) return;
      commands.register(
        (c) => c.copyWith(
          goToLine: c.goToLine == go ? const AppCommands().goToLine : null,
          runRelatedTests: c.runRelatedTests == related
              ? const AppCommands().runRelatedTests
              : null,
          goToDefinition: c.goToDefinition == definition
              ? const AppCommands().goToDefinition
              : null,
        ),
      );
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.buffer;
    final controller = b.controller!;
    final codingFont = DisplayScope.codingFontOf(context);
    final size = widget.fontSize.toDouble();
    final lineStyle = codingTextStyle(
      codingFont,
      fontSize: size,
      height: CodeTokens.editorLineHeight,
    );
    final charWidth = measureCharWidth(lineStyle);
    final gutterMarks = _gutterMarks();
    final editor = CodeEditor(
      controller: controller,
      scrollController: _scroll,
      findController: _find,
      focusNode: _editorFocus,
      autofocus: true,
      wordWrap: widget.wordWrap,
      autocompleteSymbols: true,
      commentFormatter: _comments,
      padding: const EdgeInsets.symmetric(vertical: 8),
      style: CodeEditorStyle(
        fontSize: size,
        fontFamily: codingFontFamily(codingFont),
        fontHeight: CodeTokens.editorLineHeight,
        textColor: HaroTokens.ink,
        backgroundColor: HaroTokens.bg,
        selectionColor: HaroTokens.line30,
        highlightColor: HaroTokens.line20,
        cursorColor: HaroTokens.ink,
        cursorWidth: 1.5,
        cursorLineColor: HaroTokens.line12,
        chunkIndicatorColor: HaroTokens.ink42,
        codeTheme: _theme(DisplayScope.syntaxColourOf(context)),
      ),
      indicatorBuilder: (context, editing, chunks, notifier) {
        if (!identical(_indicator, notifier)) {
          _indicator = notifier;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
        return DeferredListenableBuilder(
          listenable: editing,
          builder: (context) => EditorGutter(
            editing: editing,
            chunks: chunks,
            notifier: notifier,
            textStyle: lineStyle,
            charWidth: charWidth,
            marks: widget.marks,
            ran: widget.ran,
            proof: gutterMarks,
            onProofTap: widget.workspaceId == null
                ? null
                : (line) {
                    final id = widget.workspaceId!;
                    ref
                        .read(problemsFocusProvider(id).notifier)
                        .reveal(widget.buffer.path, line);
                    ref
                        .read(bottomPanelProvider(id).notifier)
                        .show(BottomTab.problems);
                  },
          ),
        );
      },
      leadingDivider: const SizedBox(
        width: 1,
        child: ColoredBox(color: HaroTokens.line08),
      ),
      findBuilder: (context, find, readOnly) => FindBar(controller: find),
      shortcutOverrideActions: {
        CodeShortcutSaveIntent: CallbackAction<CodeShortcutSaveIntent>(
          onInvoke: (_) {
            widget.onSave();
            return null;
          },
        ),
      },
    );
    final indicator = _indicator;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _completion == null
                          ? editor
                          : lspAutocomplete(_completion!, editor),
                    ),
                    if (indicator != null)
                      Positioned.fill(
                        child: DeferredListenableBuilder(
                          listenable: controller,
                          builder: (context) => IndentGuides(
                            editing: controller,
                            notifier: indicator,
                            scroll: _scroll.horizontalScroller,
                            charWidth: charWidth,
                            textLeft:
                                GutterMetrics.total(
                                  controller.lineCount,
                                  charWidth,
                                ) +
                                1,
                            unit: _unit,
                          ),
                        ),
                      ),
                    if (indicator != null && _hover != null)
                      Positioned.fill(
                        child: LspHoverLayer(
                          hover: _hover!,
                          editing: controller,
                          indicator: indicator,
                          scroll: _scroll,
                          focus: _editorFocus,
                          textLeft: () =>
                              GutterMetrics.total(
                                controller.lineCount,
                                charWidth,
                              ) +
                              1,
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.minimap)
                Minimap(
                  controller: controller,
                  scroll: _scroll.verticalScroller,
                  added: {
                    for (final e in widget.marks.entries)
                      if (e.value == ChangeMark.added) e.key,
                  },
                ),
            ],
          ),
        ),
        _Footer(
          buffer: b,
          onSave: widget.onSave,
          goTo: _goOpen
              ? _GoToLineField(
                  controller: _goController,
                  focusNode: _goFocus,
                  invalid: _goInvalid,
                  lineCount: controller.lineCount,
                  onSubmitted: _submitGoToLine,
                  onClose: _closeGoToLine,
                )
              : null,
        ),
      ],
    );
    if (_lsp == null) return body;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f12): _definitionCommand,
      },
      child: body,
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Align(
      alignment: Alignment.topLeft,
      child: Text(
        text,
        style: HaroText.mono(
          color: error ? HaroTokens.fail : HaroTokens.ink42,
          tracking: 0,
          size: 12,
        ),
      ),
    ),
  );
}

class _Footer extends StatelessWidget {
  const _Footer({required this.buffer, required this.onSave, this.goTo});

  final EditBuffer buffer;
  final VoidCallback onSave;

  /// The go-to-line field, while it is open: it takes the footer's left side.
  final Widget? goTo;

  @override
  Widget build(BuildContext context) {
    final style = HaroText.mono(size: 11, color: HaroTokens.ink42, tracking: 0);
    final Widget status;
    if (buffer.saveError != null) {
      status = Text(
        'Save failed: ${buffer.saveError}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style.copyWith(color: HaroTokens.fail),
      );
    } else {
      status = const SizedBox.shrink();
    }
    return Container(
      height: CodeTokens.editorFooterHeight,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: HaroTokens.bg,
        border: Border(top: BorderSide(color: HaroTokens.line08)),
      ),
      child: Row(
        children: [
          ?goTo,
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: status),
          ),
          const SizedBox(width: 12),
          HaroButton(
            label: 'Save',
            kbd: primaryLabel('S'),
            height: 22,
            fontSize: 12,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            onPressed: buffer.canSave && buffer.dirty ? onSave : null,
          ),
        ],
      ),
    );
  }
}

/// `Go to line` input in the editor footer: a number (or `:number`), Enter jumps, Esc closes.
class _GoToLineField extends StatelessWidget {
  const _GoToLineField({
    required this.controller,
    required this.focusNode,
    required this.invalid,
    required this.lineCount,
    required this.onSubmitted,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool invalid;
  final int lineCount;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final style = HaroText.mono(size: 11, color: HaroTokens.ink42, tracking: 0);
    return Row(
      children: [
        Text('Go to line', style: style),
        const SizedBox(width: 8),
        Container(
          width: 84,
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            border: Border.all(
              color: invalid ? HaroTokens.ink : HaroTokens.line30,
            ),
            borderRadius: BorderRadius.circular(HaroTokens.radius),
          ),
          child: Focus(
            onKeyEvent: (_, e) {
              if (e is KeyDownEvent &&
                  e.logicalKey == LogicalKeyboardKey.escape) {
                onClose();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
              key: const ValueKey('go-to-line-field'),
              controller: controller,
              focusNode: focusNode,
              keyboardType: TextInputType.number,
              style: HaroText.mono(
                size: 12,
                color: HaroTokens.ink,
                tracking: 0,
              ),
              cursorColor: HaroTokens.ink,
              cursorWidth: 1,
              decoration: const InputDecoration.collapsed(hintText: ''),
              onSubmitted: onSubmitted,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text('of $lineCount', style: style),
        const SizedBox(width: 8),
        _Tap('esc', onClose),
      ],
    );
  }
}

/// ⌘F find bar in the brand chrome: input, `n of m`, prev/next, case and regex toggles. ⌘⌥F
/// (re_editor's own binding) or the `⇄` toggle adds a replace row: replace one, or all.
class FindBar extends StatelessWidget implements PreferredSizeWidget {
  const FindBar({super.key, required this.controller});

  final CodeFindController controller;

  static const double height = 36;
  static const double replaceHeight = 64;

  @override
  Size get preferredSize {
    final v = controller.value;
    return Size(
      double.infinity,
      v == null ? 0 : (v.replaceMode ? replaceHeight : height),
    );
  }

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    if (value == null) return const SizedBox.shrink();
    final result = value.result;
    final label = value.option.pattern.isEmpty
        ? ''
        : result == null || result.matches.isEmpty
        ? 'none'
        : '${result.index + 1} of ${result.matches.length}';
    final small = HaroText.mono(size: 11, color: HaroTokens.ink42, tracking: 0);
    final replacing = value.replaceMode;
    return Container(
      height: replacing ? replaceHeight : height,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: HaroTokens.panel,
        border: Border(bottom: BorderSide(color: HaroTokens.line08)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: height - 1,
            child: Row(
              children: [
                _FindField(
                  key: const ValueKey('find-input'),
                  controller: controller.findInputController,
                  focusNode: controller.findInputFocusNode,
                  onSubmitted: (_) {
                    controller.nextMatch();
                    controller.focusOnFindInput();
                  },
                ),
                const SizedBox(width: 10),
                Text(label, style: small),
                const SizedBox(width: 8),
                _Tap('↑', controller.previousMatch),
                _Tap('↓', controller.nextMatch),
                _Tap(
                  'Aa',
                  controller.toggleCaseSensitive,
                  on: value.option.caseSensitive,
                ),
                _Tap('.*', controller.toggleRegex, on: value.option.regex),
                _Tap(
                  '⇄',
                  controller.toggleMode,
                  on: replacing,
                  key: const ValueKey('find-toggle-replace'),
                ),
                const Spacer(),
                _Tap('esc', controller.close),
              ],
            ),
          ),
          if (replacing)
            SizedBox(
              height: replaceHeight - height,
              child: Row(
                children: [
                  _FindField(
                    key: const ValueKey('replace-input'),
                    controller: controller.replaceInputController,
                    focusNode: controller.replaceInputFocusNode,
                    onSubmitted: (_) => controller.replaceMatch(),
                  ),
                  const SizedBox(width: 10),
                  _Tap(
                    'replace',
                    controller.replaceMatch,
                    key: const ValueKey('find-replace'),
                  ),
                  _Tap(
                    'all',
                    controller.replaceAllMatches,
                    key: const ValueKey('find-replace-all'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _FindField extends StatelessWidget {
  const _FindField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) => Flexible(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          border: Border.all(color: HaroTokens.line30),
          borderRadius: BorderRadius.circular(HaroTokens.radius),
        ),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          style: HaroText.mono(size: 12, color: HaroTokens.ink, tracking: 0),
          cursorColor: HaroTokens.ink,
          cursorWidth: 1,
          decoration: const InputDecoration.collapsed(hintText: ''),
          onSubmitted: onSubmitted,
        ),
      ),
    ),
  );
}

class _Tap extends StatelessWidget {
  const _Tap(this.label, this.onTap, {super.key, this.on = false});

  final String label;
  final VoidCallback onTap;
  final bool on;

  @override
  Widget build(BuildContext context) => HaroPressable(
    onTap: onTap,
    builder: (context, hovered) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        label,
        style: HaroText.mono(
          size: 11,
          color: on || hovered ? HaroTokens.ink : HaroTokens.ink42,
          tracking: 0,
        ),
      ),
    ),
  );
}
