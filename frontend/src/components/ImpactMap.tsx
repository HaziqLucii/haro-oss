import type { ImpactResponse } from "../types";

/** The Impact Map (v1.2): the agent's diff on the left, the tests it provably
 *  affects on the right, with a headline "blast radius" metric and a fast
 *  "run impacted only" gate. Powered by `vitest --changed <base_ref>`. */
export function ImpactMap({
  impact,
  busy,
  onRefresh,
  onRunImpacted,
}: {
  impact: ImpactResponse | null;
  busy: boolean;
  onRefresh: () => void;
  onRunImpacted: () => void;
}) {
  if (!impact) {
    return (
      <div className="impact">
        <button className="ghost" onClick={onRefresh}>
          analyze impact
        </button>
        <span className="dim"> · map the agent's diff to the tests it affects</span>
      </div>
    );
  }
  if (!impact.supported) {
    return <div className="impact empty">This runner doesn't support impact analysis.</div>;
  }
  if (impact.error) {
    return <pre className="gate-error">{impact.error}</pre>;
  }

  const impactedFiles = impact.impacted_files;
  const pct =
    impact.total_tests > 0 ? Math.round((impact.impacted_tests.length / impact.total_tests) * 100) : 0;
  const unaffected = impact.total_tests - impact.impacted_tests.length;

  return (
    <div className="impact">
      <div className="impact-headline">
        <span className="impact-metric">{impact.impacted_tests.length}</span>
        <span className="dim">
          of {impact.total_tests} tests impacted ({pct}%) · {unaffected} unaffected
        </span>
        <span className="impact-actions">
          <button className="ghost" onClick={onRefresh} disabled={busy}>
            re-analyze
          </button>
          <button
            className="primary"
            onClick={onRunImpacted}
            disabled={busy || impact.changed_files.length === 0}
          >
            run impacted only
          </button>
        </span>
      </div>

      <div className="impact-map">
        <div className="impact-col">
          <div className="impact-col-title dim">changed files ({impact.changed_files.length})</div>
          {impact.changed_files.length === 0 && <div className="empty">no changes vs {impact.base_ref}</div>}
          {impact.changed_files.map((f) => (
            <div key={f.path} className="impact-file">
              <span className="if-path">{f.path}</span>
              <span className="if-stat">
                {f.added != null && <span className="s-pass">+{f.added}</span>}{" "}
                {f.removed != null && <span className="s-fail">−{f.removed}</span>}
              </span>
            </div>
          ))}
        </div>

        <div className="impact-arrow">→</div>

        <div className="impact-col">
          <div className="impact-col-title dim">impacted test files ({impactedFiles.length})</div>
          {impactedFiles.length === 0 && <div className="empty">none</div>}
          {impactedFiles.map((f) => {
            const n = impact.impacted_tests.filter((t) => t.file === f).length;
            return (
              <div key={f} className="impact-file">
                <span className="if-path">{f}</span>
                <span className="if-stat dim">{n} test{n === 1 ? "" : "s"}</span>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
