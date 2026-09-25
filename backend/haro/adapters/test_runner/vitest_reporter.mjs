// haro's custom Vitest reporter: emits newline-delimited JSON to stdout,
// one object per test-case lifecycle event, so the Python VitestAdapter can
// stream a live test grid. Every line is tagged `__sg:1` so the adapter can
// ignore stray console.log output from the tests themselves.
//
// Uses Vitest's modern reporter API (onTestCaseReady / onTestCaseResult),
// ground-truthed against vitest 4.1.10.

function line(obj) {
  obj.__sg = 1;
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function caseInfo(tc) {
  let state = null;
  let duration = null;
  let message = null;
  let stack = null;
  try {
    const r = tc.result?.() || {};
    state = r.state ?? null;
    const err = r.errors && r.errors[0];
    if (err) {
      message = err.message || String(err);
      stack = err.stack ? String(err.stack).split("\n").slice(0, 5).join("\n") : null;
    }
  } catch (e) {
    /* ignore */
  }
  try {
    duration = tc.diagnostic?.()?.duration ?? null;
  } catch (e) {
    /* ignore */
  }
  return {
    id: tc.id,
    moduleId: tc.module?.moduleId ?? null,
    name: tc.fullName || tc.name,
    status: state,
    duration,
    message,
    stack,
  };
}

export default class HaroReporter {
  onTestModuleCollected(m) {
    const tests = [];
    try {
      for (const t of m.children.allTests()) {
        tests.push({ id: t.id, moduleId: m.moduleId, name: t.fullName || t.name });
      }
    } catch (e) {
      /* older/newer tree API — cells will still register on onTestCaseReady */
    }
    line({ g: "module", moduleId: m.moduleId, tests });
  }

  onTestCaseReady(tc) {
    line({ g: "ready", ...caseInfo(tc) });
  }

  onTestCaseResult(tc) {
    line({ g: "result", ...caseInfo(tc) });
  }

  onTestRunEnd(_modules, errors, reason) {
    line({ g: "end", reason: reason ?? null, errorCount: (errors || []).length });
  }
}
