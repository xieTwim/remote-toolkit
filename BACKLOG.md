# remote-toolkit — BACKLOG

One entry per ROOT CAUSE. Protocol: research-loop `commands/CAPABILITIES.md` § ISSUES protocol.
Grep before adding (`+1 <project> <date>` on a hit); closes in the fix's own commit, replaced by a
`- [fixed <commit>]` tombstone.

**Sanitized text only.** Host names, profile names, cluster paths and account names stay in the
reporting project's own `ISSUES.md`.

Seeded 2026-08-01 from the second migration lane.

---

- [open] 2026-08-01 dllm-reasoning: nothing tells a caller when a staged file has actually ARRIVED, so callers wait a fixed sleep and then install a stale copy. Measured: a patched launcher script was staged, waited on for ten seconds, and the still-stale remote copy was copied into place — `bash -n` passed because the OLD file is valid shell, so the run started and died instantly on an unknown case, holding 8 GPUs idle for ~25 minutes
  repro: stage a small edit, sleep a fixed interval, read the remote copy
  fix shape: an arrival assertion — content equality (a digest comparison) against the local file, exposed as something a caller can wait on, rather than a flush whose completion does not imply arrival. This is the general defect: the sync layer is being used as a job-control protocol, and a fixed sleep is what callers reach for when the layer offers no ack

- [open] 2026-08-01 reason-select: a courier bucket degrades silently as finished handoffs accumulate, and the tool's only lever makes it worse. Measured: 10,292 files / 2.6 GB in the tree put a flush in `Scanning files` for 20+ minutes — a 9 KB push took ~40 minutes and a 2.7 MB pull had not arrived after 25 — while the same bucket at 232 files / 41 MB flushes in 7 seconds. Everything in it was FINISHED pulls nobody cleared
  repro: let a sync bucket accumulate completed handoffs; measure flush latency against file count
  fix shape: warn on file count / tree size at flush time, before latency becomes the symptom. The standing lesson is that **a courier bucket needs PRUNING, not a growing ignore list — a growing ignore list is the tell that the bucket is being used as storage**; note also that ignores only apply at session-create time, so adding one does not take effect until the session is recreated, which is itself worth surfacing
