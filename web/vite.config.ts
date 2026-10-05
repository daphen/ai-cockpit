import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"
import tailwindcss from "@tailwindcss/vite"

export default defineConfig({
  plugins: [react(), tailwindcss()],
  worker: { rollupOptions: { output: { entryFileNames: "sw.js" } } },
  define: { __COCKPIT_BUILD__: JSON.stringify(Date.now().toString(36)) },
})
