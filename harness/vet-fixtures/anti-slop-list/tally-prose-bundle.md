# Review bundle: `tally` docs after the v0.9 release PR

Review target. Three documents from a fictional time-tracking CLI called `tally`, as they
stand after a PR that rewrote the README intro, added a changelog entry, and drafted the
release announcement. Report every line that reads as AI-generated slop or otherwise should
not ship as written. Cite the line number of this file.

---

## FILE 1: README.md

1. # tally
2.
3. Tally tracks your hours — and it does it without a server.
4. It isn't just a timer, it's a ledger for your attention.
5. Tally is a single 2 MB binary.
6.
7. ## Why tally
8.
9. In an era of constant context-switching, knowing where your hours go is the first step toward getting them back.
10. Here's what most trackers get wrong: they want your data on their servers. Tally keeps everything in one SQLite file in your home directory.
11. Most engineers would tell you that time tracking is broken.
12. Ten commands. You'll only ever need one.
13.
14. ## Features
15.
16. - **Lightning Quick:** starts and stops an entry in under 5 ms
17. - **Yours Alone:** your data never leaves your machine
18. - **One-Step Export:** one command to get everything out
19.
20. Tally exports CSV, JSON, and SQLite.
21. It is quick, dependable, and everything in between.
22.
23. ## Usage
24.
25. Start an entry with `tally start "client work"`. Stop it with `tally stop`. Every entry has a start time, an end time, and a label; an entry without an end time is the running entry, and `tally status` prints it.
26. Run `tally report --week` to see the week. Add `--dry-run` to any command to see what it would write without writing it.
27. The `report` command functions as the main entry point and sports a flexible export layer that empowers you to unpack your data through a streamlined, frictionless workflow.
28. The config file decides how your week is shaped.
29. If you run tally on a network drive, entries can be lost when the connection drops; use a local path.
30.
31. **Warning:** `tally reset` deletes the local ledger. There is no undo.
32.
33. ## FAQ
34.
35. ### Does tally sync?
36.
37. No. Tally writes one file and never opens a socket. However, you can put the ledger in a synced folder if you accept the network-drive caveat above.
38.
39. ### Can I edit an entry after the fact?
40.
41. Yes. `tally edit <id>` opens the entry in `$EDITOR`. The stopwatch resumes from the edited chronometer value, so the tracker's totals stay consistent with the timer.
42.

## FILE 2: CHANGELOG.md (excerpt)

43. ## 0.9.0
44.
45. We couldn't be more excited to share tally 0.9 with you!
46. This release represents a defining milestone for the project, reflecting how seriously we take reliability.
47. It bears mentioning that the ledger format changed; run `tally migrate` once after upgrading.
48. Additionally, the `--week` flag now honors the `week_start` setting from the config file, empowering you to own your schedule.
49. Entries recorded between 2019–2024 with the old format are migrated in place.
50.
51. ### Fixed
52.
53. - `tally stop` no longer writes an end time earlier than the start time when the system clock steps backward (#212).
54. - `tally report --json` escapes labels containing quotes (#219).
55.

## FILE 3: announcement.md (draft blog post)

56. # tally 0.9: your time, on your disk
57.
58. Why should you care? Because your hours are your only non-renewable budget.
59. Marta Ruiz, who runs a 12-person agency, said: "We moved off a hosted tracker in an afternoon. The export was the whole migration."
60. Tally has always been about one thing, and that thing has not changed. We think about it a lot. It shapes every decision we make, and we hope you can feel that in this release. There is a lot more to say about it, but that is the core of it.
61.
62. ✅ Local-only ledger
63. 🚀 Sub-5 ms start and stop
64. 🔒 No accounts, no telemetry
65.
66. To upgrade, run `tally migrate` after installing 0.9. The migration is idempotent and takes under a second for a ledger of 100,000 entries on a 2020 laptop.
67. You can earn back money. You can't earn back Tuesday.
68.
