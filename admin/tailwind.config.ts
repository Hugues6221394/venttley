import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}"],
  darkMode: "class",
  theme: {
    extend: {
      colors: {
        // Brand pinks (kept in sync with lib/presentation/theme/colors.dart)
        blush: "#FDECEF",
        cardBlush: "#FFF5F7",
        berry: "#D12E65",
        berryDesat: "#D96B8A",
        burgundy: "#4A0E17",
        mauve: "#E5A1B4",
        charcoal: "#120B0D",
        offwhite: "#E0D5D7",
        dividerDark: "#361F23",
        cardDark: "#1E1316",

        // Console-grade neutrals layered on top of the brand. A working
        // dashboard needs calm slate/canvas surfaces, not pure pink, so
        // information density reads cleanly at a glance.
        canvas: "#FAF6F7",
        line: "#EAD9DE",
        ink: "#2A1B1F",
        "ink-muted": "#7C5B62",

        // Status tones
        ok: "#1F8F4D",
        warn: "#C77A1A",
        danger: "#C1303D",
        info: "#3B6AB6",
      },
      fontFamily: {
        sans: [
          "Inter",
          "ui-sans-serif",
          "system-ui",
          "-apple-system",
          "Segoe UI",
          "Roboto",
          "sans-serif",
        ],
        mono: ["JetBrains Mono", "ui-monospace", "Menlo", "monospace"],
      },
      boxShadow: {
        soft: "0 1px 2px rgba(74,14,23,0.04), 0 6px 18px rgba(74,14,23,0.05)",
        lift: "0 4px 12px rgba(74,14,23,0.08), 0 18px 40px rgba(74,14,23,0.10)",
        // Backwards-compat alias used by older components before the rebuild.
        card: "0 1px 2px rgba(74,14,23,0.04), 0 8px 24px rgba(74,14,23,0.06)",
      },
    },
  },
  plugins: [],
};

export default config;
