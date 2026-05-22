import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./app/**/*.{ts,tsx}",
    "./components/**/*.{ts,tsx}",
  ],
  darkMode: "class",
  theme: {
    extend: {
      colors: {
        // Mirror lib/presentation/theme/colors.dart so the admin reads like
        // the mobile app to anyone who has both side-by-side.
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
        ok: "#6BA56F",
        warn: "#E6B65C",
        danger: "#CC4747",
      },
      fontFamily: {
        sans: ["Inter", "ui-sans-serif", "system-ui"],
      },
      boxShadow: {
        card: "0 1px 2px rgba(74,14,23,0.04), 0 8px 24px rgba(74,14,23,0.06)",
      },
    },
  },
  plugins: [],
};

export default config;
