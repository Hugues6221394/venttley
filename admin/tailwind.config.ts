import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}"],
  darkMode: "class",
  theme: {
    extend: {
      colors: {
        // Brand pinks (kept in sync with lib/presentation/theme/colors.dart)
        blush: "rgb(var(--console-blush, 253 236 239) / <alpha-value>)",
        cardBlush: "rgb(var(--console-card-blush, 255 245 247) / <alpha-value>)",
        berry: "rgb(var(--console-accent, 209 46 101) / <alpha-value>)",
        berryDesat: "#D96B8A",
        burgundy: "rgb(var(--console-heading, 74 14 23) / <alpha-value>)",
        mauve: "rgb(var(--console-line-strong, 214 214 220) / <alpha-value>)",
        charcoal: "#120B0D",
        offwhite: "#E0D5D7",
        dividerDark: "#361F23",
        cardDark: "#1E1316",

        // Console-grade neutrals layered on top of the brand. A working
        // dashboard needs calm slate/canvas surfaces, not pure pink, so
        // information density reads cleanly at a glance.
        canvas: "rgb(var(--console-canvas, 250 246 247) / <alpha-value>)",
        line: "rgb(var(--console-line, 234 217 222) / <alpha-value>)",
        ink: "rgb(var(--console-ink, 42 27 31) / <alpha-value>)",
        "ink-muted": "rgb(var(--console-muted, 124 91 98) / <alpha-value>)",

        // Status tones
        ok: "rgb(var(--console-ok, 31 143 77) / <alpha-value>)",
        warn: "rgb(var(--console-warn, 199 122 26) / <alpha-value>)",
        danger: "rgb(var(--console-danger, 193 48 61) / <alpha-value>)",
        info: "rgb(var(--console-info, 59 106 182) / <alpha-value>)",
      },
      fontFamily: {
        sans: [
          "Inter",
          "-apple-system",
          "BlinkMacSystemFont",
          "Segoe UI Variable Text",
          "Segoe UI",
          "ui-sans-serif",
          "system-ui",
          "Roboto",
          "sans-serif",
        ],
        mono: ["JetBrains Mono", "ui-monospace", "Menlo", "monospace"],
      },
      boxShadow: {
        soft: "var(--theme-shadow-sm)",
        lift: "var(--theme-shadow-md)",
        // Backwards-compat alias used by older components before the rebuild.
        card: "var(--theme-shadow-sm)",
      },
    },
  },
  plugins: [],
};

export default config;
