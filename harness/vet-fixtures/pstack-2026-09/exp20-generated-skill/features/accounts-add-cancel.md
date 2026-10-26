# Add account form, cancel path

The Accounts tab and its add-account form let a user open an inline "Add New Account"
form, name the account, pick an auth mode, and either continue (which starts
a real OAuth/API-key flow against a provider) or cancel and discard the
draft. This feature only drives the open/fill/cancel path: no real provider
credentials are available or used in verification, so `Continue` beyond the
form is out of scope for this recipe (see Gotchas).

## Sub-features

- `add-open` opens the inline "Add New Account" form from the Accounts tab.
- `add-fill` accepts a name into the "Account Name" field and a mode choice
  from the "Mode" select.
- `add-cancel` discards the draft and returns to the plain account list with
  no account created.

## How to get to it from the user's point of view

- Navigate to the "Accounts" tab from the sidebar.
- Click the "Add Account" button in the Accounts card header.

## Driving it with the harness

Preconditions:

- Server is healthy at `http://127.0.0.1:8199`.
- Fresh scratch DB: `GET /api/accounts` returns `[]`.

- **Open the tab.** Navigate to `http://127.0.0.1:8199/accounts`. The
  heading `Accounts` and description `Manage your Claude accounts` are
  visible, with no account rows listed.
- **Open the form.** Click the button named `Add Account`. A heading `Add
  New Account` appears, with a labeled field `Account Name` and a `Mode`
  select defaulted to `Claude CLI OAuth (Recommended)`.
- **Fill the name.** Fill the `Account Name` field with
  `verify-scratch-account`. The value is reflected in the input.
- **Cancel.** Click the button named `Cancel` inside the open form. The
  form closes (the `Add New Account` heading disappears) and the account
  list still shows zero rows.
- **Confirm no side effect.** Re-query `GET /api/accounts` from the page
  context (`page.evaluate(() => fetch('/api/accounts').then(r => r.json()))`).
  It must still return `[]` — proof the cancel path took no server-side
  action, not just that the form closed visually.
- **Proof.** Screenshot the opened form (with the name filled in) and the
  post-cancel account list; dump the DOM text of both states and the
  `/api/accounts` JSON body to `evidence/accounts-add-cancel/`.

## Gotchas

- The form is inline (`{adding && <AccountAddForm .../>}`), not a modal
  dialog — there is no overlay/backdrop to wait for, only the heading
  changing from "Add Account" button to "Add New Account" form.
- `AccountAddForm` renders a different `Cancel` button per internal wizard
  stage (form entry, device-code polling, routing outcome, etc.); at most
  one is in the DOM at a time in the default state, but don't assume the
  first `Cancel` found is always the form-entry one if a prior step in the
  same run left the wizard mid-flow — start this recipe from a fresh page
  load.
- Picking a mode other than the default (`claude-oauth`) can reveal
  provider-specific fields (API key inputs, AWS profile selects, etc.) that
  this recipe does not exercise; if the map is extended to cover a specific
  provider's fields, add it as its own feature file rather than growing this
  one.
- Selecting `Codex (OpenAI OAuth)` or the Qwen mode starts polling a device
  code endpoint on selection alone (before any explicit "continue" click) —
  avoid selecting those modes in a scripted run unless the recipe also
  drives the cancel-during-polling path, or a stray poll can outlive the
  script.
