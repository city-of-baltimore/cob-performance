# CLS Requests — User-Centered Design Notes

Design rationale for the CLS request experience. These notes explain *why* the interface
works the way it does, for reviewers and future contributors.

## Who this is for

- **Agency Writer** — the primary user; does data entry, often collaboratively.
- **Agency Submitter** — holds final sign-off; sends requests on to BBMR. (This was
  originally a separate **Agency Approver** role, since retired — the live data contained
  zero Approvers, so a gate on it would have blocked everyone.)
- **Agency Viewer** — read-only visibility.
- **BBMR Reviewer** — records the decision on the CLS Review page.

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
- The **150-word summary** counts live and warns (in red, with the exact overage) rather
  than hard-blocking, respecting the user's flow while making the limit unambiguous.
- **A recurring request must give FY29 and FY30.** The out-years are what "recurring"
  means; a one-time request hides them entirely. The form only ever asks for fields that
  apply to the answer already given.
- **Amounts carry thousands separators and refuse decimals.** Budget figures here are whole
  dollars, and a seven-digit number without separators is genuinely hard to read back.
- **Position Count starts empty.** It used to default to 1, which was being submitted
  unread. An empty required field asks the question rather than answering it wrongly.
- **Request details** shows a running **remaining-$** message so the user always knows how
  much is left to break out and whether they've gone over — turning a reconciliation chore
  into a visible target.

**Make "done" obvious — and stay quiet when it is.** Required fields turn red when empty,
and leaving with one blank is blocked, naming the fields. An unbalanced request warns on the
way out. A *complete* request now says nothing at all: the earlier "This request has been
justified" confirmation was noise on the happy path, and an interruption that only ever
tells you things are fine trains people to dismiss the ones that matter.

A persistent reminder names every **Agency Submitter** for the agency and the deadline, so
the user knows the next step and owner. The list page repeats that under the heading and
adds the **Budget Analyst**, so "who do I ask?" is answered on the page rather than in
someone's inbox.

**High-contrast, conventional back affordance.** The back control is a prominent pill at
the top-left — the conventional place users look to leave a record — rather than a muted
link lost among the content.

**Colors carry meaning.** Orange **Submit for approval** stands apart from the neutral
primary actions because it changes ownership of the work (hands it to the submitter);
destructive actions stay red; the remaining-$ note shifts to green when balanced and red
when over.

**Every status gets its own colour.** Six workflow states were being drawn with five
generic tones, so *Agency Review* and *Partially Approved* looked identical — a request
waiting on a colleague and a request BBMR had partly funded were indistinguishable at a
glance, which is exactly what a status chip exists to prevent. Each now has its own.

**The chart tells the truth about partial approvals.** A partially approved request used to
paint its whole requested amount in the "partially approved" colour, which read as though
all of it had been funded. Only the approved dollars are yellow now; the shortfall is its
own "Not approved" segment. A partial with no approved figure recorded shows entirely as
not approved — which surfaces the missing number instead of flattering it.

**Filters wait for the user to finish.** Each tick used to reload the table and shut the
dropdown mid-selection, so choosing three statuses meant reopening the panel three times.
Ticks are now held and applied once, on **Apply** or on close. The general principle: a
control the user is still operating should not act on a partial answer.

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
