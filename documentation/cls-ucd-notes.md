# CLS Requests — User-Centered Design Notes

Design rationale for the CLS request experience. These notes explain *why* the interface
works the way it does, for reviewers and future contributors.

## Who this is for

- **Agency Writer** — the primary user; does data entry, often collaboratively.
- **Agency Approver** — reviews and approves before anything goes to BBMR.
- **Agency Viewer** — read-only visibility.
- **BBMR / OPI** — downstream reviewers (later phase).

Design goal: let a non-budget-expert writer produce a complete, well-justified request
with minimal training and little chance of submitting something incomplete.

## Key decisions and why

**One card, agency-titled.** The list page is a single white card headed with the agency
name ("{Agency} Requests"). Removing the redundant secondary header reduces visual noise
and orients the user to *whose* requests these are. The BBMR guidance sits directly under
the title so the framing is read before acting.

**Progressive disclosure over pop-ups.** Creating/editing happens on a dedicated page, not
a modal — there is too much to capture for a dialog, and a full page avoids the cramped,
scroll-trapped feel of a large modal. Within the page, secondary complexity is hidden until
needed: the request-type reference lives behind an **info icon**, and the **Positions**
section only appears when the user opts in. This keeps the default path short.

**Progressive contrast between steps.** The request page sits on a slightly darker canvas
than the list. This gives a clear "you have drilled into a record" cue without a hard
navigation break, reinforcing where the user is.

**Guided, forgiving data entry.**
- The **request name is first and full-width** — the user names the thing before detailing
  it, matching how people think about a request.
- **One-time requests hide and clear** the FY29/FY30 fields, so the form only ever shows
  fields that apply — preventing contradictory data.
- The **300-word summary** counts live and warns (in red, with the exact overage) rather
  than hard-blocking, respecting the user's flow while making the limit unambiguous.
- **Request details** shows a running **remaining-$** message so the user always knows how
  much is left to break out and whether they've gone over — turning a reconciliation chore
  into a visible target.

**Make "done" obvious.** Required fields turn red when empty, and a complete request earns
a "This request has been justified" confirmation on the way out. A persistent reminder
names the Agency Approver and the deadline, so the user knows the next step and owner. This
is the wayfinding layer: the interface tells the user what remains and what happens next.

**High-contrast, conventional back affordance.** The back control is a prominent pill at
the top-left — the conventional place users look to leave a record — rather than a muted
link lost among the content.

**Colors carry meaning.** Orange **Submit for approval** stands apart from the neutral
primary actions because it changes ownership of the work (hands it to the approver);
destructive actions stay red; the remaining-$ note shifts to green when balanced and red
when over.

**Familiar exports.** Budget staff live in Excel, so export produces a real workbook with
one tab per table; PDF is offered for sharing/printing the full detail.

## Accessibility & robustness

- Sortable headers and the info disclosure are real buttons / native `<details>` —
  keyboard-operable and screen-reader friendly.
- Validation is advisory (red cues + messages), never a silent block.
- Wide content (the request table, the adjustment-type table) scrolls within its own
  container so the page never scrolls sideways.

## Open questions for the next round

- Should incomplete requests be blocked from **Submit**, or is the current "advisory red +
  confirmation" model preferred?
- The submission **deadline** is currently phrased generically; wire it to the plan cycle
  once that date is available in the data.
- Confirm whether service reassignment should be logged (audit trail) when a request is
  moved between services.
