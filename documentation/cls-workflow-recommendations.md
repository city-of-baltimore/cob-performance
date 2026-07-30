# CLS approval workflow — recommendations

You raised three things that don't quite fit together today:

1. **Agency Approvers need to know** when writers have sent requests to them.
2. **A writer needs an approver's approval** before anything goes to BBMR.
3. **An approver can send all requests** — i.e. wants a bulk action.

Below is what the app does now, where it falls short, and what I recommend. **Nothing here
is built yet** — these are proposals for you to pick from.

---

## What exists today

| Step | Who | Action | Result |
|------|-----|--------|--------|
| 1 | Writer | fills in a request | status **In Progress** |
| 2 | Writer | **Submit** on that row | status **Agency Review** |
| 3 | Approver | **Send to BBMR** on that row | status **BBMR Review**, marked complete |
| 4 | BBMR | records a decision | **Approved / Partially Approved / Denied** |

Both hand-offs are per request, each with a confirmation dialog. The email to the submitter
exists but is switched off.

## The three gaps

**Gap 1 — nothing tells the approver.** A writer submits and the status changes, but the
approver only finds out by opening the page and looking. There is no count, no queue, no
notification.

**Gap 2 — the approver can bypass the writer.** *Send to BBMR* is offered on requests that
are still **In Progress**, so an approver can push a request the writer hasn't finished or
submitted. That contradicts "a writer needs approval of an approver" — the sequence isn't
enforced.

**Gap 3 — no bulk action.** Sending twelve requests means twelve clicks and twelve
confirmations.

---

## Recommendations

### R1 — Show approvers what's waiting (do this first)

Add a count of requests in **Agency Review** wherever an approver lands:

- a chip in the page header — *"3 awaiting your approval"*
- the same number as a badge on the **CLS Requests** nav item
- default the table's sort to Status so those rows surface at the top

Cheap, no schema change, and it removes the "I didn't know" problem entirely.
**Recommended.**

### R2 — Enforce the sequence, with a deliberate override

Restrict **Send to BBMR** to requests in **Agency Review** — so the writer's submission is
a real gate. For the case where an approver legitimately needs to move something a writer
hasn't submitted, offer a distinct secondary action, e.g. *Approve and send (skip writer
submission)*, that is visibly different and logs who used it.

This keeps the intended order without trapping anyone. **Recommended.**

> Alternative if you'd rather stay flexible: leave the current behaviour but label the
> button differently on an In Progress row (*Send draft to BBMR*) so the approver can see
> they're skipping a step.

### R3 — Add a bulk "Send all ready" for approvers

One button above the table: **Send all in Agency Review (N)**. The confirmation lists what
will go, and the action only touches those rows — never a draft, never an already-decided
request. (`set_plan_cls_status()` already supports exactly this with its `only_from` guard;
it's currently unused by the UI.)

Pair it with per-row *Send to BBMR* so approvers can still be selective.
**Recommended** — this is the "approver can send all requests" you described.

### R4 — Let approvers return a request to the writer

Today an approver's only options are edit it themselves or send it on. A **Return to
writer** action — status back to **In Progress** with a short reason — makes the loop
two-way and mirrors how the plan-review workflow already behaves elsewhere in Beacon.
**Recommended**, though it needs one new field for the return note.

### R5 — Turn the notification on when you're ready

The email hook is in place and disabled. When you want it:

- writer submits → email the **approver** (not the submitter — that's arguably the bug in
  the current wiring)
- approver sends to BBMR → optional confirmation to the writer
- BBMR decides → email the writer and approver

Worth deciding **who** should be emailed at each step before switching anything on.

### R6 — Record who did what

Right now `modified_by` holds only the last person to touch a request. For an audit trail,
a small `cls_status_history` table (request, from, to, who, when, note) would mirror
`PLAN_STATUS_HISTORY` in the target schema and answer "who sent this and when".
**Worth doing before go-live**, low effort.

---

## Suggested order

| Priority | Item | Effort | Schema change |
|----------|------|--------|---------------|
| 1 | R1 — awaiting-approval count | small | none |
| 2 | R3 — bulk send for approvers | small | none |
| 3 | R2 — enforce sequence + override | small | none |
| 4 | R6 — status history | medium | one new table |
| 5 | R4 — return to writer | medium | one column |
| 6 | R5 — email notifications | medium | none |

R1–R3 together address everything you described and need no database change. Tell me which
you want and I'll build them.

## One open question

**Should an approver be able to approve their own request?** If someone holds both roles,
or an approver writes a request themselves, nothing currently stops them submitting and
sending it. Whether that's fine or needs a second pair of eyes is a policy call, not a
technical one.
