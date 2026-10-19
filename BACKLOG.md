# remote-toolkit — open problems

One line per real open problem: `- <problem> → <fix idea> (<date>, <where seen>)`. Delete the line when it
is fixed; git keeps the history. Incidents go to `~/Work/Harness/FRICTION.md` first.

- A synced tree lands on the remote with Mutagen's portable defaults (files 0600, directories and executables 0700), so a remote process running as another uid gets EACCES → an opt-in per-profile default file and directory mode at session create, documented beside the note that session options freeze at create (2026-10-18).
- The first apply of a small changed file can fail on the remote with `unable to set staged file permissions … no such file or directory` and stay stuck in staging (four times on one profile; flush and pause/resume did not clear it) → find what removes the beta staging file between stage and apply; until then, compare the remote digest before launching (2026-10-11).
- Nothing proves a remote copy equals the local tree before a launch that does not go through `rt`: new files took 30-60 s to arrive (flush gave up at its 10 s default while the session was still applying), and a live edit synced in under a running read-only analysis and broke its imports → an `rt` digest check (local vs remote sha256 for named paths, exit non-zero on a difference) for launchers to call, and a note that long reads import from a frozen copy (2026-10-19, two incidents in one research project).
