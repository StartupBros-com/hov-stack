# acme-console

The Acme workspace console: a React 19 + Tailwind CSS v4 app built with Vite.

- `pnpm dev` starts it on http://localhost:5173.
- Design tokens live in `src/styles/theme.css`. Tailwind's default scales are reset there, so only the
  listed colours, spacing steps, radii and text sizes exist.
- Shared components live in `src/components/ui/`: `Button`, `Card` / `CardHeader`, `Avatar`, `Input`.
- Pages live in `src/pages/`. The settings screen is `src/pages/Settings.tsx`.
