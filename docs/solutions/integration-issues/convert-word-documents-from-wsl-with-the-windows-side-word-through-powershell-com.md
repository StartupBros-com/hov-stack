---
title: "Convert Word documents from WSL with the Windows-side Word through PowerShell COM when LibreOffice is absent"
date: "2026-09-12"
category: integration-issues
module: sign-it-word-convert-wsl
problem_type: integration_issue
component: tooling
symptoms:
  - "A skill needs a .docx as PDF, LibreOffice is not installed in the WSL distro, and Word is installed on the Windows side"
  - "A loop that calls powershell.exe stops after its first iteration"
  - "powershell.exe -File with a \\\\wsl.localhost path is unreliable, and Word opens UNC paths inconsistently"
root_cause: missing_tooling
resolution_type: code_fix
severity: medium
tags: [wsl, word, docx, powershell, com, libreoffice, conversion]
---

# Convert Word documents from WSL with the Windows-side Word through PowerShell COM when LibreOffice is absent

## Problem

sign-it needed to sign Word contracts, and the machine has no LibreOffice in WSL but a full Word install on Windows. pandoc cannot render to PDF without an engine, and installing LibreOffice is 300 MB of packages for a conversion Word already does with full fidelity.

## Symptoms

- `convert` had nothing to call: `soffice`, `libreoffice`, `docx2pdf` all missing.
- The first bash loop over four documents converted one file and exited: powershell.exe read the loop's stdin.
- Running the script from its WSL path through `\\wsl.localhost\...` was not something to rely on for Word's `Documents.Open`.

## What Didn't Work

- pandoc: needs a PDF engine (LaTeX, typst, weasyprint), none installed, and a docx signature table survives Word's own export better than any reflow.
- Passing WSL paths to Word: the UNC form works for some calls and not for others; the exchange directory below sidesteps it entirely.

## Solution

`sign-it convert` tries LibreOffice first, then Word through `powershell.exe`, else exits 4 naming both. The Word path (dotfiles #1130, `skills-local/sign-it/scripts/sign-it.mjs`):

1. Ask PowerShell for the Windows TEMP directory (`$env:TEMP`), map it with `wslpath -u`, and create an exchange directory there.
2. Copy the document, and the PowerShell script itself, into the exchange directory; translate their paths back with `wslpath -w`. Only paths under `/mnt/` are translated, so a test stub can run the same code with Linux paths.
3. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <exchange>\word-to-pdf.ps1 -In <exchange>\doc.docx -Out <exchange>\doc.pdf` with `stdio: ['ignore', 'pipe', 'pipe']` so PowerShell cannot consume the caller's stdin.
4. Copy the PDF back beside the source, then remove the three exchange files.

The script (`skills-local/sign-it/scripts/word-to-pdf.ps1`) opens read-only, exports with format 17 (PDF), and quits Word in a `finally`:

```powershell
$word = New-Object -ComObject Word.Application
$word.Visible = $false; $word.DisplayAlerts = 0
try { $doc = $word.Documents.Open($In, $false, $true); $doc.ExportAsFixedFormat($Out, 17); $doc.Close(0) }
finally { $word.Quit() }
```

Measured: 2.6 to 7 seconds per document including Word startup; four real contracts converted with their signature tables intact.

## Why This Works

WSL's interop runs Windows executables in the user's session, so COM automation reaches the installed Word. The exchange directory keeps every path Word sees on a Windows drive; closing stdin removes the one way PowerShell interferes with a bash pipeline; copying the script to the Windows side avoids executing from a network path.

## Prevention

- Stub both converters in the suite (`SIGN_IT_SOFFICE`, `SIGN_IT_POWERSHELL` point at bash fakes) so the dispatch order, the overwrite refusal and the exchange cleanup are tested on Linux CI where neither tool exists.

## Related Issues

- `docs/solutions/best-practices/harden-a-heuristic-tool-on-the-operators-real-files-with-a-trial-fleet.md`
