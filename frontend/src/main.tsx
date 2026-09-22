import React from "react";
import ReactDOM from "react-dom/client";
import { App } from "./App";
import "./styles.css";

// Distinguish the live-source dev app (run.sh → Vite dev server) from the
// packaged build: only the dev server sets import.meta.env.DEV, so the installed
// app keeps the "haro." title while dev windows read "haro-dev".
if (import.meta.env.DEV) document.title = "haro-dev";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
