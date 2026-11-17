/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        bg: "var(--color-bg)",
        surface: "var(--color-surface)",
        fg: "var(--color-fg)",
        "fg-muted": "var(--color-fg-muted)",
        brand: "var(--color-brand)",
      },
      boxShadow: {
        raised: "var(--shadow-raised)",
      },
      keyframes: {
        "slide-up": { from: { transform: "translateY(8px)", opacity: "0" }, to: { transform: "none", opacity: "1" } },
        "slide-down": { from: { transform: "translateY(-8px)", opacity: "0" }, to: { transform: "none", opacity: "1" } },
      },
      animation: {
        "slide-up": "slide-up 200ms ease-out",
        "slide-down": "slide-down 200ms ease-out",
      },
    },
  },
  plugins: [],
};
