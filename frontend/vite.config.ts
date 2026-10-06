import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Proxy the control-plane REST + WebSocket to the FastAPI backend so the browser
// only ever talks to its own origin (no CORS in dev; same relative URLs work if
// we later serve the built SPA from FastAPI). HARO_API points at the backend —
// "localhost:8000" on the host, "http://backend:8000" inside the compose network.
const backend = process.env.HARO_API || "http://localhost:8000";

export default defineConfig({
  plugins: [react()],
  // Monaco is only reached through a lazy `import()` (CodePanel), so Vite's dev
  // dep-scanner doesn't pre-bundle it at startup. Without this, the FIRST time a
  // file is opened Vite discovers `monaco-editor` at runtime, re-optimizes deps,
  // and forces a full page reload — which drops the SPA route back to the haro
  // root ("opening Monaco kicks me home, then works on the 2nd try"). Worst after
  // a `docker compose down/up` wipes the node_modules volume (→ empty .vite cache).
  // Pre-bundling here moves that cost to server boot; production code-splitting
  // (the lazy chunk) is unaffected.
  optimizeDeps: {
    include: ["monaco-editor", "@monaco-editor/react"],
  },
  server: {
    host: true, // reachable from the host when running in a container
    port: 5173,
    // Allow access via a Tailscale MagicDNS name (e.g. jarvis.<tailnet>.ts.net)
    // when fronted by `tailscale serve` for HTTPS. Leading dot = domain + all
    // subdomains; safe because the dev server is only bound to loopback/tailnet.
    allowedHosts: [".ts.net"],
    proxy: {
      "/projects": backend,
      "/workspaces": backend,
      "/health": backend,
      "/fs": backend,
      "/usage": backend,
      "/ws": { target: backend, ws: true },
    },
  },
});
