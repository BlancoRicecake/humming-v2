import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";
import { fileURLToPath } from "node:url";

// This web app reuses the main frontend's piano-roll/editor components by
// importing their .tsx source directly (read-only, no copy). Vite must be
// allowed to serve files from the Humming V2 root so those imports resolve.
const here = path.dirname(fileURLToPath(import.meta.url));
const hummingRoot = path.resolve(here, "../../.."); // web → ace-fusion → labs → root

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5273,
    fs: { allow: [hummingRoot] },
    proxy: {
      // web talks only to the lab orchestrator (:8200); /api → :8200/*
      "/api": {
        target: "http://127.0.0.1:8200",
        changeOrigin: true,
        rewrite: (p) => p.replace(/^\/api/, ""),
      },
    },
  },
});
