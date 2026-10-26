# Theme toggle

The sidebar's theme control lets a user switch the dashboard between light, dark, and system appearance.
The choice is applied to `<html>`'s class list immediately and persisted in
`localStorage` under the key `theme`, so it survives a reload.

## Sub-features

- `theme-open` opens the theme menu from the sidebar control.
- `theme-set-dark` applies dark mode: `<html class="dark">` and
  `localStorage.theme === "dark"`.
- `theme-persist` keeps the choice after a full page reload.
- `theme-set-light` applies light mode: `<html class="light">` and
  `localStorage.theme === "light"`.

## How to get to it from the user's point of view

- Click the theme button in the sidebar/header (icon-only button, accessible
  name "Toggle theme").
- Choose "Light", "Dark", or "System" from the dropdown menu it opens.

## Driving it with the harness

Preconditions:

- Server is healthy at `http://127.0.0.1:8199`.
- Fresh browser context: `theme-context.tsx` writes `localStorage.theme =
  "system"` on first mount (verified live: the key is present immediately,
  not absent/null), and with no OS dark-mode preference this resolves to
  `document.documentElement.className === "light"`.

- **Open menu.** Navigate to `http://127.0.0.1:8199/`. Click the button with
  accessible name `Toggle theme`. A menu with items `Light`, `Dark`, `System`
  appears.
- **Set dark.** Click the `Dark` menu item. Read `document.documentElement.className`
  and `localStorage.getItem('theme')` via `page.evaluate`. Both must reflect
  `dark`.
- **Reload and confirm persistence.** Reload the page. Re-read
  `document.documentElement.className` and `localStorage.getItem('theme')`.
  Both must still read `dark` — this is the "reopen and confirm" step; a
  class that only holds before reload is not proof of persistence.
- **Set light.** Open the theme menu again and click `Light`. Confirm
  `document.documentElement.className` contains `light` and
  `localStorage.getItem('theme') === 'light'`.
- **Proof.** Screenshot before/after the dark switch and after the reload;
  dump the evaluated class name and localStorage value to a `.txt` file
  alongside each screenshot under `evidence/theme-toggle/`.

## Gotchas

- `theme-context.tsx` computes an *effective* theme for `system` from
  `prefers-color-scheme`; only `light` and `dark` selections give a
  deterministic class to assert on. Don't assert a class for `System`
  without also pinning `prefers-color-scheme` in the browser context.
- The class list is replaced (`classList.remove("light","dark")` then
  `classList.add(...)`), not toggled — assert exact membership, not absence
  of the other class alone.
- Playwright's default browser context has no persisted storage across a
  fresh `newContext()`; drive open-menu, set, and reload within the *same*
  context/page, or persistence isn't actually being tested.
- `navigation.tsx` renders **two** `ThemeToggle` instances (a `lg:hidden`
  mobile header copy and a `hidden lg:flex` desktop sidebar copy inside a
  `position: fixed` `<aside class="h-screen">`). Playwright's `getByRole`
  correctly matches only the one visible at the current viewport width, but
  at the default 1280x720 viewport the desktop sidebar's copy sits below
  y=720 (below the fold of a fixed-position element, which page-level
  scrolling cannot bring into view) and `.click()` times out with "element
  is outside of the viewport". Launch the page with a taller viewport
  (`{ width: 1280, height: 1100 }` was sufficient; 720 and 1000 were not)
  so the fixed sidebar's full content, including its footer, fits on
  screen.
