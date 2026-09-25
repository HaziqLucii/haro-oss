// One-line rail chip for ③'s Zone 3 (notes/verify-redesign-plan.md): the rail no longer
// hosts the full pane (that moved into ③ itself), so this is the one line that survives —
// a deep-link back, not a worklist. Null when there's nothing to look at, so an idle rail
// never nags.
export function LookAtChip({ count, onClick }: { count: number; onClick: () => void }) {
  if (count === 0) return null;
  return (
    <button className="look-at-chip" onClick={onClick} title="things to look at, from the ③ verify step">
      {count} to look at
    </button>
  );
}
