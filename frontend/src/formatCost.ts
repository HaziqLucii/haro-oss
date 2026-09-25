/**
 * Format a USD dollar amount compactly for display.
 *
 * Agent costs span a wide range: a tiny follow-up might cost fractions of a
 * cent while a long session runs into dollars. Sub-dollar amounts keep 4
 * decimals so small costs stay legible (0.0021 → "$0.0021"); once we're at a
 * dollar or more, 2 decimals reads like money (1.5 → "$1.50").
 */
export function formatCost(usd: number): string {
  const abs = Math.abs(usd);
  const decimals = abs >= 1 ? 2 : 4;
  const sign = usd < 0 ? "-" : "";
  return `${sign}$${abs.toFixed(decimals)}`;
}
