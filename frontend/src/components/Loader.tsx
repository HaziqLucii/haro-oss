import { useEffect, useState } from "react";

// Whimsical rotating verbs, à la Claude Code's "Thinking…".
const WORDS = ["Thinking", "Pondering", "Reasoning", "Cooking", "Scheming", "Working", "Crunching"];

/** The "Thinking…" loader — a small monochrome meter (three hairline bars breathing
 *  out of phase) beside a rotating verb, shown while the agent is spun up but hasn't
 *  streamed its first token yet. Bone-on-ground, no accent: green stays reserved for
 *  the gate. */
export function ThinkingLoader() {
  const [i, setI] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setI((n) => (n + 1) % WORDS.length), 2200);
    return () => clearInterval(t);
  }, []);

  return (
    <div className="thinking">
      <span className="hloader" aria-hidden="true">
        <i />
        <i />
        <i />
      </span>
      <div className="thinking-word">{WORDS[i]}…</div>
    </div>
  );
}
