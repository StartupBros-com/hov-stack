# Create a note

Create note lets a user save a titled note from the browser or CLI, cancel an unfinished browser draft, and confirm the saved note from a second user-facing view.

## Sub-features

- `create-open` opens a blank editor from each browser entry point.
- `create-save` persists a title and body.
- `create-cancel` discards an unfinished browser draft.
- `create-cli` creates the same note shape from the terminal.

## How to get to it from the user's point of view

- Click the `New note` button in the browser toolbar.
- Press `n` in the browser while focus is outside an editable field.
- Run `notes create --title <title> --body <body>` in a terminal.

## Driving it with the harness

Preconditions:

- Notes is healthy at `http://127.0.0.1:4173`.
- No note is titled `Release checklist`.
- The doctor check reports the expected URL and disposable data directory.

- **Open editor.** Click the button named `New note`. Run `page.getByRole('button', { name: 'New note' }).click()`. A form named `Note editor` appears with focus in the `Title` textbox.
- **Enter content.** Type the title and body. Run `page.getByRole('textbox', { name: 'Title' }).fill('Release checklist')` and `page.getByRole('textbox', { name: 'Body' }).fill('Tag and publish')`. The `Save note` button becomes enabled.
- **Save note.** Click the button named `Save note`. Run `page.getByRole('button', { name: 'Save note' }).click()`. A status named `Note saved` appears and the heading reads `Release checklist`.
- **Confirm persistence.** Return to the note list and reopen the note. Run `page.getByRole('link', { name: 'All notes' }).click()` then `page.getByRole('link', { name: 'Release checklist' }).click()`. The editor shows both saved values.
- **Cancel draft.** Open a new note, enter `Discard me`, and choose `Cancel`. Run `page.getByRole('button', { name: 'New note' }).click()`, `page.getByRole('textbox', { name: 'Title' }).fill('Discard me')`, and `page.getByRole('button', { name: 'Cancel' }).click()`. The note list returns and has no `Discard me` link.
- **CLI entry.** Create a second note. Run `notes create --title "CLI note" --body "Created from terminal" --format json` as a direct shell command and capture stdout, stderr, and exit code. Exit code `0` and stdout contain the new note ID and title.
- **Proof.** Reopen both saved notes from `All notes`. Screenshot the list and capture `page.locator('body').ariaSnapshot()` to `/tmp/verify-notes-$RUN_ID/create-note/list.png` and `/tmp/verify-notes-$RUN_ID/create-note/list.aria.txt`. The artifacts show `Release checklist` and `CLI note`.

## Gotchas

- Pressing `n` while a textbox has focus types the character instead of opening a new editor.
- Titles are trimmed on save. Assert the rendered title, not the draft input value.
- A save status alone is insufficient proof. Reopen the note from the list.
- Remove `Release checklist` and `CLI note` during fixture cleanup, but retain their proof artifacts.
