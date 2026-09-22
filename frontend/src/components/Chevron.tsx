/** The single expand/collapse chevron used everywhere a section opens — diff
 *  file blocks, the sidebar project navigator, and the code-editor file tree —
 *  so every disclosure affordance reads identically (same stroke, rotation, and
 *  ease). Points right when closed; rotates 90° to point down when `open`.
 *  Style via the `.chevron` / `.chevron.open` rules in styles.css. */
export function Chevron({ open, className = "" }: { open: boolean; className?: string }) {
  return (
    <svg
      className={"chevron" + (open ? " open" : "") + (className ? " " + className : "")}
      width="10"
      height="10"
      viewBox="0 0 10 10"
      aria-hidden="true"
    >
      <path
        d="M3 1.5 L6.5 5 L3 8.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
