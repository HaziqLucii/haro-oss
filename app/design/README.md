# design/

The Claude Design redesign of haro (2026-09-29). This is the target: build to match it exactly.

| File | What |
|---|---|
| `haro-redesign-spec.md` | Implementation spec: what to remove, app shell, first run, triage dashboard, workspace, overlays, copy rules, build order, and §9 Flutter implementation (packages, "Open in…", state machine, widget map, theme). Read this first. |
| `prototype/haro-redesign.dc.html` | Clickable prototype. Open it in a browser next to the spec. The Tweaks panel `startScreen` switches first run / dashboard / workspace / settings; the **Preview state** bar on the workspace steps through idle, running, red, green, merged. |
| `haro-plan.md` | **Living plan from the 2026-09-29 design sessions (wins over everything else here).** Manual mode, XP, code-step IDE, shell strips, focus mode. |
| `prototype/haro-finalized-ui.dc.html` | **Current target prototype** (implements `haro-plan.md`). Wins over `haro-redesign.dc.html` where they differ. |
| `prototype/haro-manual-journey.dc.html` | Manual mode told as a real 19-step task (scenario A finish by hand, B switch to agent halfway). Behaviour reference; loses to the plan and Finalized UI on conflicts (no kanji in UI, no Hints tab). |
| `prototype/haro-manual-mode.dc.html` | Three short manual-mode demos. Oldest of the three: its Hints ladder is dropped. |
| `prototype/support.js`, `prototype/fonts/` | Assets the prototype loads. |
