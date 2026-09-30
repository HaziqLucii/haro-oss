// Paste-to-file: a large pasted block is promoted to a `.context/` file attachment
// instead of being dumped into the composer (kept out of the prompt text). The
// thresholds are deliberately low — a stack trace, a log dump, or a spec pasted in
// reads far better as a chip you can open in a tab than as dozens of lines wedged
// into the prompt box (and Claude Code reads the file lazily via an @ mention, so it
// doesn't bloat the prompt up front).

export const PASTE_TO_FILE_LINES = 20;
export const PASTE_TO_FILE_CHARS = 2000;

/** True when a pasted block is big enough to become a file attachment. */
export function shouldAttachPaste(text: string): boolean {
  if (!text) return false;
  const lines = text.split("\n").length;
  return lines >= PASTE_TO_FILE_LINES || text.length >= PASTE_TO_FILE_CHARS;
}

/** A composer attachment: a worktree-relative `.context/` file the agent can read.
 *  Text pastes carry a `lines` count; pasted images / picked files carry `kind`
 *  ("image" | "file") + a byte `size` instead (there's nothing to count). */
export interface Attachment {
  path: string; // e.g. ".context/pasted-ab12cd.txt"
  name: string; // basename, shown on the chip
  lines?: number; // text attachments only
  kind?: "text" | "image" | "file";
  size?: number; // byte size, for non-text attachments
}

/** Chip label: basename + line count ("pasted-ab12cd.txt · 42 lines"). */
export function attachmentLabel(a: Attachment): string {
  return `${a.name} · ${a.lines ?? 0} line${a.lines === 1 ? "" : "s"}`;
}

/** Human-readable byte size for a chip label ("24 KB", "1.3 MB"). */
export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

/** Chip stat: line count for text, byte size for images/files. */
export function attachmentStat(a: Attachment): string {
  if (a.kind === "image" || a.kind === "file") {
    return a.size != null ? formatBytes(a.size) : a.kind;
  }
  const n = a.lines ?? 0;
  return `${n} line${n === 1 ? "" : "s"}`;
}

/** Read a File's bytes as a bare base64 string (no `data:…;base64,` prefix), for
 *  uploading an image/media attachment over the JSON transport. */
export function fileToBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const res = reader.result;
      if (typeof res !== "string") return reject(new Error("could not read file"));
      resolve(res.slice(res.indexOf(",") + 1)); // strip the data-URL prefix
    };
    reader.onerror = () => reject(reader.error ?? new Error("could not read file"));
    reader.readAsDataURL(file);
  });
}

/** Fold the attachments into the task as `@path` mentions so Claude Code reads them.
 *  Attachments alone (no typed prose) still produce a valid task. */
export function composeWithAttachments(task: string, attachments: Attachment[]): string {
  const mentions = attachments.map((a) => `@${a.path}`).join(" ");
  const trimmed = task.trim();
  if (!mentions) return trimmed;
  return trimmed ? `${trimmed}\n\n${mentions}` : mentions;
}
