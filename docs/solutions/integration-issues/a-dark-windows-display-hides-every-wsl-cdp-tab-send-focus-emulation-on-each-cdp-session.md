---
title: A dark Windows display hides every wsl-cdp tab, so an unattended CDP job sends focus emulation on each session
date: 2026-11-05
category: integration-issues
module: wsl-cdp-unattended-drive
problem_type: integration_issue
component: development_workflow
symptoms:
  - "Every tab in the agent browser reads document.visibilityState hidden while the Windows display is off, even the fronted tab of a window that is not minimized"
  - requestAnimationFrame callbacks never fire, so a script that waits on a frame hangs until wsl-cdp's 20 s eval timeout
  - A click lands but a menu that needs a drawn frame never opens, so the scripted step times out
  - The same job works whenever someone is at the PC
root_cause: wrong_api
resolution_type: code_fix
severity: medium
related_components: [wsl-cdp-bridge, playwright]
tags: [wsl-cdp, cdp, chromium, occlusion, hidden-tab, request-animation-frame, focus-emulation, unattended, windows-display-off]
---

# A dark Windows display hides every wsl-cdp tab, so an unattended CDP job sends focus emulation on each session

## Problem

wsl-cdp drives its agent profile, its own instance of the Windows browser (Brave, Chrome/156 in this case), not the operator's daily browser. When the Windows display turns off on its idle timeout, Chromium marks every window of that browser occluded and every page hidden. Hidden pages draw no frames. A scheduled job that clicks through a site's UI from WSL then fails or skips every run while nobody is at the PC, which for a scheduled job is most runs.

## Symptoms

- `document.visibilityState` reads `hidden` in every tab, including the fronted tab of a maximized window.
- `requestAnimationFrame` callbacks never fire. A frame-timing script hangs until `wsl-cdp eval` gives up (`TIMEOUT_MS = 20000`, `plugins/wsl-cdp/wsl-cdp-drive.mjs:17`). An earlier MV3 extension e2e run hit the same stall from a background tab (auto memory [claude]).
- The click on a site's overflow (⋯) menu is dispatched, but the menu renders on a frame that never comes, so the step that waits for its items times out.
- The job works whenever someone is at the PC, which points away from the site and toward the browser.

## What Didn't Work

- **`Page.bringToFront`.** On 2026-11-04 at 05:17 EST, with the display off, a fronted tab stayed `hidden` and no frame fired. Fronting changes which tab is on top of the window, and the window itself is what Chromium has marked occluded.
- **Trusting `document.visibilityState` as the gate.** It read a stale `visible` on tabs that had been idle, so a gate on it passed and the click still went nowhere. One `requestAnimationFrame` callback within 1 s is the reliable test of "this page draws".
- **Skipping the run when the page does not draw** (dotfiles#2161). It made the failure honest: no click into a page that cannot draw, and a skip instead of a failed run. But every run while the display was dark became a skip, so it was a stopgap, not the fix.
- **Relaunch flags** (`--disable-backgrounding-occluded-windows`, `--disable-features=CalculateNativeWinOcclusion`). Not tried. Either needs a browser restart, and the agent browser is shared with other live sessions and holds their logins. `wsl-cdp up` also builds that browser's launch arguments itself.
- **Waking the display from Windows** (`SetThreadExecutionState`, synthesized input with `SendInput`, `SC_MONITORPOWER`). Not tried. None is documented to turn on a display that is already off: `SetThreadExecutionState` only holds off the idle timeout, and synthesized input is faking a user to the whole desktop.

## Solution

Send `Emulation.setFocusEmulationEnabled({ enabled: true })` on the page's CDP session before any step that needs frames or input, and send it again on every new connection. The fix landed as dotfiles#2162, in the browser driver's `keepDrawing`:

```js
async function keepDrawing(conn) {
  try {
    await conn.send("Emulation.setFocusEmulationEnabled", { enabled: true });
  } catch {
    // A browser without it: the paint check that follows decides.
  }
}

// Does the page draw? One requestAnimationFrame callback within 1 s.
const PAINT_JS = `new Promise((resolve) => {
  let done = false;
  const end = (painted) => { if (!done) { done = true; resolve({ painted, visibility: document.visibilityState }); } };
  requestAnimationFrame(() => end(true));
  setTimeout(() => end(false), 1000);
})`;
```

The driver calls `keepDrawing`, then `Page.bringToFront`, then polls `PAINT_JS` for about 3 s. A page that still does not draw is reported as "not drawing" and the run stops before clicking.

No browser restart, no flags, and no change to the display or the user's session.

Evidence, 2026-11-05:

- 10:25Z, after 33 minutes with no input on the PC. A control tab without emulation read `hidden` in a window that was not minimized, so the display was dark. The driver's tab drew, and the site's ⋯ menu opened and closed in it.
- 09:58 EST, the scheduled run with the fix. All 5 of its actions completed and were confirmed by readback. The control tab read dark before and after the run, with about 5 hours of idle time. The display was not observed during the run itself.

## Why This Works

The source references below are per chromium/main as read 2026-11-04.

- **The cause.** On Windows, `ui/aura/native_window_occlusion_tracker_win.cc` marks every visible browser window occluded when the screen is locked or the display is off: `if (screen_locked_ || !display_on_) occl_state = OCCLUDED` (a window that is not visible is already marked hidden). An occluded window's pages go to `PageVisibilityState::kHidden`, and a hidden page gets no frames, so `requestAnimationFrame` stops and nothing paints.
- **Why the fix holds.** `Emulation.setFocusEmulationEnabled(true)` makes the DevTools `EmulationHandler` (`content/browser/devtools/protocol/emulation_handler.cc`) take a capturer handle on the page's WebContents with `stay_hidden=false`. A WebContents with a visible capturer is visible whatever its window's occlusion says (`WebContentsImpl::CalculatePageVisibilityState`).
- **Why it has to be resent.** The capturer is held by that DevTools session's emulation handler, which drops it when the handler is destroyed or `Emulation.disable` runs. The handler lives only as long as its session, so treat the capturer as gone once the session detaches (inferred from the handler's lifetime; the detach path itself was not traced). So every connect, and every short-lived `wsl-cdp eval`-style session, has to send it again before relying on frames.
- **Why a Playwright client would not hit it.** Playwright sends the same call on every main-frame page session (`playwright-core` 1.56.1, `lib/server/chromium/crPage.js:438`), so a page it drives gets this for free. This is read from source, not observed on the wsl-cdp browser. A hand-rolled CDP client, such as `wsl-cdp-drive.mjs`, gets none of it.

## Prevention

- **Any unattended CDP job against the wsl-cdp browser sends focus emulation first,** on each session it opens, before a click, a screenshot or a frame-dependent eval.
- **Gate on a frame, not on `visibilityState`.** One `requestAnimationFrame` callback within 1 s after emulation. If it still fails, stop with a distinct "not drawing" result rather than clicking blind or reporting success.
- **Confirm a test was really dark with a control tab.** Front a blank tab without emulation, in a window that is not minimized. It must read `hidden` and fail the frame check; otherwise the display was on and the test proves nothing.
- **Not yet observed: a locked session.** The tracker branch covers both locked and display off, but only an idle, dark display was tested.
- **Open follow-up, a feature.** wsl-cdp's own drive helper sends no emulation: `Runtime.evaluate` with `awaitPromise: true` at `plugins/wsl-cdp/wsl-cdp-drive.mjs:77-80`. So `wsl-cdp eval` and `wsl-cdp screenshot` still hit this on an unattended host. Baking the call into the helper is the one-owner fix. A test for it would run the helper against a fake CDP endpoint and assert that the `Emulation.setFocusEmulationEnabled` call comes before the first `Runtime.evaluate`.
- **Known-limits wording.** `plugins/wsl-cdp/skills/wsl-cdp/SKILL.md:56` and `plugins/wsl-cdp/README.md:105` say only that attended use is the sweet spot. They do not say that a dark display hides every page, or that emulation keeps it drawing.

## Related Issues

- dotfiles#2162: the fix (focus emulation per op), verified in the dark 2026-11-05.
- dotfiles#2161: the interim skip when the page does not draw.
- dotfiles#2157 and dotfiles#2160: the scheduled browser job this was found in.
- `docs/solutions/integration-issues/open-html-deliverables-with-a-real-launcher-not-open-xdg-open.md`: the same agent-owned wsl-cdp browser, on a different problem (launching deliverables).
- `harness/browser-cdp-bridge.md`: background on the bridge.
