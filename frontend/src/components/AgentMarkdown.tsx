import { Fragment, useState, type ReactNode } from "react";
import { StarFilled } from "./icons";

/** Copy text to the clipboard (with a legacy fallback). In dev we also stash the
 *  last-copied value on window for tests. */
export async function copyText(text: string): Promise<boolean> {
  if (import.meta.env.DEV) (window as unknown as { __lastCopy?: string }).__lastCopy = text;
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    try {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.focus();
      ta.select();
      const ok = document.execCommand("copy");
      ta.remove();
      return ok;
    } catch {
      return false;
    }
  }
}

export function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      className={"copy-btn" + (copied ? " copied" : "")}
      title="copy code"
      onClick={async () => {
        await copyText(text);
        setCopied(true);
        setTimeout(() => setCopied(false), 1300);
      }}
    >
      {copied ? "copied ✓" : "copy"}
    </button>
  );
}

/** Inline `code` — click to copy. */
export function InlineCode({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <code
      className={"inline-code" + (copied ? " copied" : "")}
      title="click to copy"
      onClick={async () => {
        await copyText(text);
        setCopied(true);
        setTimeout(() => setCopied(false), 1000);
      }}
    >
      {text}
    </code>
  );
}

type Part = { type: "text" | "code"; content: string; lang?: string };

/** Split text into prose + fenced code blocks. Tolerant of an unclosed trailing
 *  fence (so a code block renders live while the agent is still streaming it). */
export function splitFences(text: string): Part[] {
  const parts: Part[] = [];
  const re = /```([\w+.-]*)\n?([\s\S]*?)(?:\n?```|$)/g;
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) parts.push({ type: "text", content: text.slice(last, m.index) });
    parts.push({ type: "code", lang: m[1] || "", content: m[2] });
    last = re.lastIndex;
    if (re.lastIndex === m.index) re.lastIndex++; // guard against zero-length matches
  }
  if (last < text.length) parts.push({ type: "text", content: text.slice(last) });
  return parts;
}

/** Inline formatting inside a line: `code`, ***bold-italic***, **bold**, *italic* /
 *  _italic_. Emphasis bodies may themselves contain the other markers (e.g. a
 *  **bold phrase with an *italic* word**), so we recurse into each match — a body
 *  is re-parsed for nested `code`/emphasis. Alternation order is deliberate: longer
 *  fences (`***`, `**`) are tried before `*`, so bold wins over italic at a position
 *  and a stray inner `*` no longer defeats the whole bold span (the old bug). */
export function renderInline(text: string, keyBase: string): ReactNode[] {
  const out: ReactNode[] = [];
  const re =
    /(`[^`\n]+`)|(\*\*\*[^\n]+?\*\*\*)|(\*\*[^\n]+?\*\*)|(\*(?![\s*])[^\n]*?\*)|(_(?![\s_])[^\n]*?_)/g;
  let last = 0;
  let k = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) out.push(text.slice(last, m.index));
    const tok = m[0];
    const key = `${keyBase}-${k++}`;
    if (tok.startsWith("`")) {
      out.push(<InlineCode key={key} text={tok.slice(1, -1)} />);
    } else if (tok.startsWith("***")) {
      out.push(
        <strong key={key}>
          <em>{renderInline(tok.slice(3, -3), key)}</em>
        </strong>
      );
    } else if (tok.startsWith("**")) {
      out.push(<strong key={key}>{renderInline(tok.slice(2, -2), key)}</strong>);
    } else if (tok.startsWith("*")) {
      out.push(<em key={key}>{renderInline(tok.slice(1, -1), key)}</em>);
    } else {
      out.push(<em key={key}>{tok.slice(1, -1)}</em>); // _italic_
    }
    last = re.lastIndex;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

/** Split a GFM table row into trimmed cells, tolerating optional outer pipes. */
function splitRowCells(line: string): string[] {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((c) => c.trim());
}

/** A GFM delimiter row: `|---|:--:|--:|` — dashes with optional alignment colons. */
function isDelimiterRow(line: string): boolean {
  if (!line.includes("-") || !line.includes("|")) return false;
  const cells = splitRowCells(line);
  return cells.length > 0 && cells.every((c) => /^:?-+:?$/.test(c));
}

/** Derive per-column text alignment from the delimiter row's colons. */
function colAlign(cell: string): "left" | "center" | "right" | undefined {
  const l = cell.startsWith(":");
  const r = cell.endsWith(":");
  if (l && r) return "center";
  if (r) return "right";
  if (l) return "left";
  return undefined;
}

/** Block-level prose: headings (#), bullet lists (- / *), GFM tables, blank-line
 *  gaps, and plain lines — each with inline formatting. (Between fenced code blocks.) */
function renderProse(text: string, keyBase: string): ReactNode[] {
  const lines = text.split("\n");
  const blocks: ReactNode[] = [];
  let list: ReactNode[] = [];
  const flushList = () => {
    if (list.length) {
      blocks.push(
        <ul className="md-ul" key={`${keyBase}-ul-${blocks.length}`}>
          {list}
        </ul>
      );
      list = [];
    }
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const li = line.match(/^\s*[-*]\s+(.+)$/);
    if (li) {
      list.push(<li key={i}>{renderInline(li[1], `${keyBase}-li-${i}`)}</li>);
      continue;
    }
    flushList();
    // GFM table: a header row (contains a pipe) immediately followed by a
    // delimiter row. Consume the header, delimiter, and all following rows.
    if (line.includes("|") && i + 1 < lines.length && isDelimiterRow(lines[i + 1])) {
      const header = splitRowCells(line);
      const aligns = splitRowCells(lines[i + 1]).map(colAlign);
      const rows: string[][] = [];
      let j = i + 2;
      for (; j < lines.length; j++) {
        const r = lines[j];
        if (!r.includes("|") || r.trim() === "") break;
        rows.push(splitRowCells(r));
      }
      blocks.push(
        <table className="md-table" key={`${keyBase}-tbl-${i}`}>
          <thead>
            <tr>
              {header.map((c, ci) => (
                <th key={ci} style={aligns[ci] ? { textAlign: aligns[ci] } : undefined}>
                  {renderInline(c, `${keyBase}-th-${i}-${ci}`)}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((row, ri) => (
              <tr key={ri}>
                {header.map((_, ci) => (
                  <td key={ci} style={aligns[ci] ? { textAlign: aligns[ci] } : undefined}>
                    {renderInline(row[ci] ?? "", `${keyBase}-td-${i}-${ri}-${ci}`)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      );
      i = j - 1;
      continue;
    }
    const h = line.match(/^(#{1,6})\s+(.+)$/);
    if (h) {
      const lvl = Math.min(h[1].length, 3);
      blocks.push(
        <div className={`md-h md-h${lvl}`} key={i}>
          {renderInline(h[2], `${keyBase}-h-${i}`)}
        </div>
      );
    } else if (line.trim() === "") {
      blocks.push(<div className="md-gap" key={i} />);
    } else {
      blocks.push(
        <div className="md-line" key={i}>
          {renderInline(line, `${keyBase}-l-${i}`)}
        </div>
      );
    }
  }
  flushList();
  return blocks;
}

/** Render a run of prose: fenced code blocks (each with a copy button) interleaved
 *  with markdown prose. The shared body used for both normal output and the inside
 *  of an insight callout. */
function renderContent(text: string, keyBase: string): ReactNode[] {
  return splitFences(text).map((p, i) =>
    p.type === "code" ? (
      <div className="code-block" key={`${keyBase}-${i}`}>
        {p.lang && <span className="code-lang">{p.lang}</span>}
        <CopyButton text={p.content} />
        <pre>
          <code>{p.content}</code>
        </pre>
      </div>
    ) : (
      <div className="md-text" key={`${keyBase}-${i}`}>
        {renderProse(p.content, `${keyBase}t${i}`)}
      </div>
    )
  );
}

type InsightSeg =
  | { type: "normal"; content: string }
  | { type: "insight"; label: string; content: string };

// The MCP's "Insight" callout arrives as plain tokens framed by box-drawing rules:
//   ★ Insight ────────────
//   …prose…
//   ────────────
// Carve those out so they render as a highlighted fun-fact box rather than raw
// lines. Detection keys on the box-drawing rule char (U+2500 ─ / U+2501 ━), NOT a
// plain "---", so a genuine markdown horizontal rule in ordinary prose is never
// mistaken for an insight divider. The opener also requires the ★, so a bare rule
// line only ever closes a block.
const INSIGHT_OPEN = /^[ \t]*★[ \t]*([^\n─━]*?)[ \t]*[─━]*[ \t]*$/;
const INSIGHT_RULE = /^[ \t]*[─━]{3,}[ \t]*$/;

function splitInsights(text: string): InsightSeg[] {
  const lines = text.split("\n");
  const segs: InsightSeg[] = [];
  let normal: string[] = [];
  const flushNormal = () => {
    if (normal.length) {
      segs.push({ type: "normal", content: normal.join("\n") });
      normal = [];
    }
  };
  for (let i = 0; i < lines.length; i++) {
    const open = INSIGHT_OPEN.exec(lines[i]);
    if (open) {
      flushNormal();
      // Body runs until the closing rule — or end of text, so the box renders live
      // while the block is still streaming in (before its closing rule arrives).
      const body: string[] = [];
      let j = i + 1;
      for (; j < lines.length && !INSIGHT_RULE.test(lines[j]); j++) body.push(lines[j]);
      segs.push({
        type: "insight",
        label: open[1].trim() || "Insight",
        content: body.join("\n").replace(/^\n+|\n+$/g, ""),
      });
      i = j; // skip the closing rule (or land on EOF), loop's i++ moves past it
      continue;
    }
    normal.push(lines[i]);
  }
  flushNormal();
  return segs;
}

/** Renders an agent message: prose with inline code + fenced code blocks that each
 *  carry a copy button, plus the MCP "Insight" fun-fact callout when one appears.
 *  Keeps the dev in flow — grab code without leaving. */
export function AgentMarkdown({ text }: { text: string }) {
  const segs = splitInsights(text);
  return (
    <div className="md ev-token">
      {segs.map((seg, i) =>
        seg.type === "insight" ? (
          <div className="insight-callout" key={i}>
            <div className="insight-head">
              <StarFilled size={13} />
              <span className="insight-label">{seg.label}</span>
            </div>
            <div className="insight-body">{renderContent(seg.content, `in${i}`)}</div>
          </div>
        ) : (
          <Fragment key={i}>{renderContent(seg.content, `n${i}`)}</Fragment>
        )
      )}
    </div>
  );
}
