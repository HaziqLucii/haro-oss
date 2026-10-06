import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

// Vitest config for the gate. React plugin so .tsx imports transform; node env
// for pure-logic tests (component tests can opt into jsdom per-file later).
export default defineConfig({
  plugins: [react()],
  test: {
    environment: "node",
    include: ["src/**/*.{test,spec}.{ts,tsx}"],
  },
});
