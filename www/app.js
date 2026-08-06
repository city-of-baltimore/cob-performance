(function () {
  document.body.classList.add("auth-signed-out");
  var pendingGoalDeletion = null;
  var MAX_MEASURES_PER_BLOCK = 5;
  var reviewerFilterResetKey = "";
  var autosaveTimer = null;
  var serviceDescriptionAutosaveTimer = null;
  var serviceMetricsAutosaveTimer = null;
  var servicesQuietAutosaveTimer = null;
  var goalsQuietAutosaveTimer = null;
  var reviewAutosaveTimer = null;
  var pendingServiceDescriptionSave = null;
  var pendingServiceMetricsSave = null;
  var pendingServicesQuietSave = null;
  var pendingGoalsQuietSave = null;
  var draftSaveQueue = [];
  var activeDraftSave = null;
  var activeDraftSaveTimer = null;
  var backgroundSaveCount = 0;
  var backgroundSaveClearTimer = null;
  var pendingNavigationPage = null;
  var pendingNavigationTimer = null;
  var AUTH_IDLE_MS = 60 * 60 * 1000;
  var AUTH_HEARTBEAT_MS = 5 * 60 * 1000;
  var authIdleTimer = null;
  var authHeartbeatTimer = null;
  var lastAuthHeartbeatAt = 0;
  var authHandlersRegistered = false;
  var authRestorePending = false;
  var authRestoreAttempted = false;
  var openServiceIds = new Set();
  var openGoalIds = new Set();
  var serviceMetricUiState = {};
  var serviceMetricUiVersion = {};

  function dismissGoalDeleteDialog() {
    pendingGoalDeletion = null;
    var dialog = document.getElementById("delete_goal_dialog");
    if (dialog && dialog.open) dialog.close();
  }

  function setActivePage(page) {
    var navPage = page === "plan_review_detail" ? "reviewer_dashboard" : page;
    if (page === "cls_request_detail") navPage = "cls_requests";
    document.querySelectorAll("[data-page]").forEach(function (button) {
      button.classList.toggle("active", button.getAttribute("data-page") === navPage);
    });
  }

  // ---- CLS request page controller -------------------------------------
  function clsPageRoot() { return document.querySelector(".cls-detail-shell"); }
  function clsFieldInput(container) { return container.querySelector("input, textarea, select"); }
  function clsWordCount(s) { s = (s || "").trim(); return s ? s.split(/\s+/).length : 0; }
  var CLS_SUMMARY_WORD_LIMIT = 150;
  function clsLineTotal() {
    var total = 0;
    document.querySelectorAll(".cls-line-table .cls-line-row[data-cls-line-amount]").forEach(function (row) {
      var v = parseFloat(row.getAttribute("data-cls-line-amount"));
      if (!isNaN(v)) total += v;
    });
    return total;
  }
  function clsPositionTotal() {
    var total = 0;
    document.querySelectorAll(".cls-position-table .cls-position-row[data-cls-position-amount]").forEach(function (row) {
      var v = parseFloat(row.getAttribute("data-cls-position-amount"));
      if (!isNaN(v)) total += v;
    });
    return total;
  }
  function clsAccountedTotal() { return clsLineTotal() + clsPositionTotal(); }
  // ---- Money / count fields --------------------------------------------
  // A native number input cannot display a thousands separator, so the CLS
  // amount and count fields are text inputs bound to Shiny by the custom
  // binding below. Decimals are dropped outright: budget figures here are whole
  // dollars and whole positions (analyst feedback round 2).
  function clsDigitsOnly(value) {
    var s = String(value == null ? "" : value);
    var negative = s.trim().charAt(0) === "-";
    // Everything after a decimal point goes, along with any other punctuation.
    s = s.split(".")[0].replace(/[^0-9]/g, "");
    if (!s.length) return "";
    return (negative ? "-" : "") + s;
  }
  function clsGroupDigits(value) {
    var raw = clsDigitsOnly(value);
    if (!raw.length || raw === "-") return raw;
    var negative = raw.charAt(0) === "-";
    var digits = negative ? raw.slice(1) : raw;
    digits = digits.replace(/^0+(?=\d)/, "");
    return (negative ? "-" : "") + digits.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  }
  // The numeric value of a money field (or any input), commas and all.
  function clsNumberValue(el) {
    if (!el) return NaN;
    var raw = clsDigitsOnly(el.value);
    if (!raw.length || raw === "-") return NaN;
    var n = parseInt(raw, 10);
    return isNaN(n) ? NaN : n;
  }
  function clsFormatMoneyInput(el) {
    if (!el) return;
    var formatted = clsGroupDigits(el.value);
    if (el.value === formatted) return;
    // Keep the caret where the user left it, counting from the right so the
    // separators appearing to the left do not shunt it.
    var fromEnd = (el.value || "").length - (el.selectionStart == null ? 0 : el.selectionStart);
    el.value = formatted;
    if (el.setSelectionRange) {
      var pos = Math.max(0, formatted.length - fromEnd);
      try { el.setSelectionRange(pos, pos); } catch (e) { /* detached input */ }
    }
  }
  function clsRegisterMoneyBinding() {
    if (!window.Shiny || !window.Shiny.InputBinding || !window.jQuery) return false;
    if (window.__clsMoneyBindingRegistered) return true;
    var $ = window.jQuery;
    var binding = new window.Shiny.InputBinding();
    $.extend(binding, {
      find: function (scope) { return $(scope).find("input.cls-money-input"); },
      getId: function (el) { return el.id; },
      getValue: function (el) {
        var n = clsNumberValue(el);
        return isNaN(n) ? null : n;
      },
      setValue: function (el, value) { el.value = clsGroupDigits(value); },
      subscribe: function (el, callback) {
        $(el).on("input.clsMoney", function () { clsFormatMoneyInput(el); callback(true); });
        $(el).on("change.clsMoney blur.clsMoney", function () { clsFormatMoneyInput(el); callback(false); });
        // A pasted or typed decimal point never lands in the field at all.
        $(el).on("keydown.clsMoney", function (event) {
          if (event.key === "." || event.key === "e" || event.key === "E") event.preventDefault();
        });
      },
      unsubscribe: function (el) { $(el).off(".clsMoney"); },
      getRatePolicy: function () { return { policy: "debounce", delay: 350 }; }
    });
    window.Shiny.inputBindings.register(binding, "beacon.clsMoneyInput");
    window.__clsMoneyBindingRegistered = true;
    return true;
  }
  if (!clsRegisterMoneyBinding()) {
    document.addEventListener("DOMContentLoaded", clsRegisterMoneyBinding);
  }
  function clsRequestAmount() {
    var el = document.getElementById("cls_form_amount");
    if (!el) return 0;
    var v = clsNumberValue(el);
    return isNaN(v) ? 0 : v;
  }
  function clsMoney(n) {
    try { return "$" + Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }); }
    catch (e) { return "$" + n; }
  }
  function clsUpdateWordCount() {
    var ta = document.getElementById("cls_form_summary");
    var box = document.getElementById("cls_summary_wordcount");
    if (!ta || !box) return;
    var wc = clsWordCount(ta.value);
    var limit = CLS_SUMMARY_WORD_LIMIT;
    var over = wc - limit;
    if (over > 0) {
      ta.classList.add("cls-over-limit");
      box.classList.add("cls-over-limit");
      box.textContent = "This response is " + over + " word" + (over === 1 ? "" : "s") + " over the " + limit +
        "-word limit. Anything beyond " + limit + " words will be cut off for review.";
    } else {
      ta.classList.remove("cls-over-limit");
      box.classList.remove("cls-over-limit");
      box.textContent = wc + " / " + limit + " words";
    }
  }
  // The justification doubles as the description when a new spend category is
  // being created, so the prompt only appears for that option.
  var CLS_NEW_SPEND_CATEGORY = "Create Spend Category";
  // Filter dropdowns batch their ticks. Every checkbox click used to reach Shiny
  // on its own, so the table re-rendered - and closed the panel - before the user
  // had finished choosing. Ticks are now held locally and pushed once, when the
  // panel is applied or closed (analyst feedback round 2).
  var clsCdApplying = false;
  function clsApplyCheckDropdown(panel) {
    if (!panel || !panel.classList.contains("cls-cd-dirty")) return;
    panel.classList.remove("cls-cd-dirty");
    var box = panel.querySelector('input[type="checkbox"]');
    if (!box) return;
    // One change event is enough: Shiny's checkbox-group binding reads the whole
    // container, not the box that fired.
    clsCdApplying = true;
    try { box.dispatchEvent(new Event("change", { bubbles: true })); }
    finally { clsCdApplying = false; }
  }
  function clsApplyAllCheckDropdowns() {
    document.querySelectorAll(".cls-cd-panel.cls-cd-dirty").forEach(clsApplyCheckDropdown);
  }
  function clsCloseAllCheckDropdowns() {
    clsApplyAllCheckDropdowns();
    document.querySelectorAll(".cls-cd-panel").forEach(function (p) { p.style.display = "none"; });
    document.querySelectorAll("[data-cls-cd-toggle]").forEach(function (b) { b.setAttribute("aria-expanded", "false"); });
  }
  // Capture phase, so the tick never reaches the container Shiny listens on.
  document.addEventListener("change", function (event) {
    if (clsCdApplying) return;
    var target = event.target;
    if (!target || target.type !== "checkbox" || !target.closest) return;
    var panel = target.closest(".cls-cd-panel");
    if (!panel) return;
    event.stopPropagation();
    panel.classList.add("cls-cd-dirty");
    clsUpdateCheckDropdownSummary(target.closest(".shiny-input-checkboxgroup"));
    clsMarkCheckDropdownDirty(panel);
  }, true);
  function clsMarkCheckDropdownDirty(panel) {
    var apply = panel.querySelector("[data-cls-cd-apply]");
    if (apply) apply.classList.add("is-dirty");
  }
  // Keep the closed-state summary ("3 of 6 selected") in step with the boxes.
  function clsUpdateCheckDropdownSummary(group) {
    if (!group) return;
    var wrap = group.closest(".cls-check-dropdown");
    if (!wrap) return;
    var boxes = group.querySelectorAll('input[type="checkbox"]');
    var sel = group.querySelectorAll('input[type="checkbox"]:checked');
    var label = wrap.querySelector(".control-label");
    var name = label ? label.textContent.trim().toLowerCase() : "items";
    var out = wrap.querySelector(".cls-cd-summary");
    if (!out) return;
    if (!boxes.length) out.textContent = "None available";
    else if (!sel.length) out.textContent = "No " + name + " selected";
    else if (sel.length === boxes.length) out.textContent = "All " + name;
    else out.textContent = sel.length + " of " + boxes.length + " selected";
  }
  function clsUpdateNewCategoryNote(scope) {
    var root = scope || clsPageRoot() || document;
    var sel = root.querySelector("#cls_line_spend_category");
    var note = root.querySelector("#cls_new_category_note");
    if (!note) return;
    var isNew = !!sel && sel.value === CLS_NEW_SPEND_CATEGORY;
    note.style.display = isNew ? "inline" : "none";
  }
  function clsUpdateRemaining(scope) {
    var root = scope || document;
    var note = root.querySelector(".cls-remaining-note");
    if (!note) return;
    var text = note.querySelector(".cls-remaining-text");
    if (!text) return;
    var amtEl = root.querySelector("#cls_form_amount");
    var amt = amtEl ? (clsNumberValue(amtEl) || 0) : 0;
    var accounted = 0;
    root.querySelectorAll("[data-cls-line-amount], [data-cls-position-amount]").forEach(function (row) {
      var v = parseFloat(row.getAttribute("data-cls-line-amount") || row.getAttribute("data-cls-position-amount"));
      if (!isNaN(v)) accounted += v;
    });
    var remaining = amt - accounted;
    note.classList.remove("cls-remaining-ok", "cls-remaining-over");
    if (amt <= 0) {
      text.textContent = "Enter the FY28 Amount above, then describe it by object or positions.";
      return;
    }
    if (Math.abs(remaining) < 0.005) {
      note.classList.add("cls-remaining-ok");
      text.textContent = "The total request of " + clsMoney(amt) + " is fully described by object and positions.";
    } else if (remaining > 0) {
      // Unbalanced either way is a problem, so both directions read as an error.
      note.classList.add("cls-remaining-over");
      text.textContent = "The total request needs to explain " + clsMoney(remaining) + ". Describe the request amount by object or positions.";
    } else {
      note.classList.add("cls-remaining-over");
      text.textContent = "The total request exceeds " + clsMoney(Math.abs(remaining)) + ". Reduce the request amount by object or positions.";
    }
  }
  // A required field that is currently hidden does not count - the out-year
  // amounts are mandatory for a recurring request and absent for a one-time one.
  function clsFieldIsVisible(container) {
    return !!(container && container.offsetParent !== null);
  }
  function clsUpdateRequired() {
    document.querySelectorAll(".cls-summary-surface [data-cls-required]").forEach(function (c) {
      var el = clsFieldInput(c);
      var empty = clsFieldIsVisible(c) && (!el || !(el.value || "").trim());
      c.classList.toggle("cls-field-missing", empty);
    });
  }
  function clsValidate() {
    clsUpdateWordCount();
    clsUpdateRequired();
    // Each request shell totals only its own objects and positions.
    var shells = document.querySelectorAll(".cls-detail-shell");
    if (shells.length) shells.forEach(function (s) { clsUpdateRemaining(s); });
    else clsUpdateRemaining();
  }
  // Scoped to one request shell: the page can contain more than one form
  // (and a "new" form with empty fields must not make a saved request look
  // incomplete).
  // The mandatory fields in the request's first container, by label.
  function clsSummaryGaps(scope) {
    var root = scope || clsPageRoot();
    var gaps = [];
    if (!root) return gaps;
    root.querySelectorAll(".cls-summary-surface [data-cls-required]").forEach(function (c) {
      if (!clsFieldIsVisible(c)) return;
      var el = clsFieldInput(c);
      if (el && el.classList && el.classList.contains("cls-money-input")) {
        // An amount of zero is not an amount.
        var n = clsNumberValue(el);
        if (!isNaN(n) && n > 0) return;
      } else if (el && (el.value || "").trim()) {
        return;
      }
      var lab = c.querySelector(".control-label, label");
      gaps.push(lab ? lab.textContent.trim().replace(/\s+/g, " ") : "a required field");
    });
    var ta = root.querySelector("#cls_form_summary, [id$='cls_form_summary']");
    if (ta && clsWordCount(ta.value) > CLS_SUMMARY_WORD_LIMIT) {
      gaps.push("Summarize the request (over the " + CLS_SUMMARY_WORD_LIMIT + "-word limit)");
    }
    return gaps;
  }
  function clsRequestIsComplete(scope) {
    var root = scope || clsPageRoot();
    if (!root) return false;
    var ok = true;
    root.querySelectorAll(".cls-summary-surface [data-cls-required]").forEach(function (c) {
      if (!clsFieldIsVisible(c)) return;
      var el = clsFieldInput(c);
      if (el && el.classList && el.classList.contains("cls-money-input")) {
        var n = clsNumberValue(el);
        if (isNaN(n) || n <= 0) ok = false;
      } else if (!el || !(el.value || "").trim()) {
        ok = false;
      }
    });
    var ta = root.querySelector("#cls_form_summary, [id$='cls_form_summary']");
    if (ta && clsWordCount(ta.value) > CLS_SUMMARY_WORD_LIMIT) ok = false;
    var amtEl = root.querySelector("#cls_form_amount");
    var amt = amtEl ? (clsNumberValue(amtEl) || 0) : 0;
    var total = 0;
    root.querySelectorAll("[data-cls-line-amount], [data-cls-position-amount]").forEach(function (row) {
      var v = parseFloat(row.getAttribute("data-cls-line-amount") || row.getAttribute("data-cls-position-amount"));
      if (!isNaN(v)) total += v;
    });
    if (amt <= 0 || Math.abs(amt - total) >= 0.005) ok = false;
    return ok;
  }
  function clsApplyOneTime() {
    var cb = document.getElementById("cls_form_one_time");
    if (!cb) return;
    var hide = cb.checked;
    document.querySelectorAll(".cls-outyear-field").forEach(function (f) { f.style.display = hide ? "none" : ""; });
    if (hide) {
      ["cls_form_amount_next", "cls_form_amount_2next"].forEach(function (id) {
        var el = document.getElementById(id);
        if (el && el.value !== "") { el.value = ""; el.dispatchEvent(new Event("change", { bubbles: true })); }
      });
    }
  }
  function clsApplyOneTimeLabel() {
    var cb = document.getElementById("cls_form_one_time");
    var label = document.getElementById("cls_onetime_label");
    if (cb && label) label.textContent = cb.checked ? "One-Time Request" : "Recurring Request";
  }
  function clsClearPositionForm() {
    ["cls_position_classification", "cls_position_salary", "cls_position_justification",
     "cls_position_explanation"].forEach(function (id) {
      var el = document.getElementById(id);
      if (el && el.value !== "") { el.value = ""; el.dispatchEvent(new Event("change", { bubbles: true })); }
    });
    // Position Count starts empty rather than at 1, so it has to be entered.
    var count = document.getElementById("cls_position_count");
    if (count && count.value !== "") { count.value = ""; count.dispatchEvent(new Event("change", { bubbles: true })); }
  }
  function clsApplyPositionsToggle() {
    var cb = document.getElementById("cls_add_positions_toggle");
    var body = document.getElementById("cls_positions_body");
    if (!cb || !body) return;
    body.style.display = cb.checked ? "" : "none";
    // Unchecking abandons whatever was being typed, so clear the entry fields.
    if (!cb.checked) clsClearPositionForm();
  }
  function clsToggleInfoPanel(id, button) {
    // Look inside the field that owns the button first: ids repeat if more than
    // one request form is present, and getElementById would find the wrong one.
    var panel = null;
    if (button) {
      var field = button.closest(".cls-field-full") || button.closest(".cls-detail-shell");
      if (field) panel = field.querySelector("#cls_info_" + id) || field.querySelector(".cls-info-panel");
    }
    if (!panel) panel = document.getElementById("cls_info_" + id);
    if (!panel) return;
    // Read the rendered state, not the inline style: after the first toggle the
    // inline style is "" (visible), which an empty-string check misread as closed.
    var isHidden = window.getComputedStyle(panel).display === "none";
    panel.style.display = isHidden ? "block" : "none";
    if (button) button.setAttribute("aria-expanded", isHidden ? "true" : "false");
  }
  function clsSyncTitle() {
    var name = document.getElementById("cls_form_name");
    var title = document.querySelector(".cls-detail-title");
    var v = name ? (name.value || "").trim() : "";
    if (name && title) title.textContent = v || "New CLS request";
    var intro = document.querySelector(".cls-intro-name");
    if (intro) intro.textContent = v || "request";
  }
  // Analyst feedback: the Add buttons stay disabled until every field in their
  // form is filled, so an incomplete row cannot even be attempted. The server
  // still re-checks - this is the affordance, not the guard.
  var CLS_ADD_FORMS = [
    { btn: "cls_submit_line", fields: ["cls_line_category", "cls_line_spend_category", "cls_line_amount", "cls_line_justification"] },
    { btn: "cls_submit_position", fields: ["cls_position_classification", "cls_position_count", "cls_position_salary",
                                           "cls_position_justification", "cls_position_explanation"] }
  ];
  function clsUpdateAddButtons() {
    CLS_ADD_FORMS.forEach(function (form) {
      var btn = document.getElementById(form.btn);
      if (!btn) return;
      var ready = form.fields.every(function (id) {
        var el = document.getElementById(id);
        if (!el) return false;
        var v = (el.value || "").trim();
        if (!v) return false;
        if (el.type === "number" || el.classList.contains("cls-money-input")) {
          var n = clsNumberValue(el);
          return !isNaN(n) && n > 0;
        }
        return true;
      });
      btn.disabled = !ready;
      btn.classList.toggle("is-disabled", !ready);
      btn.setAttribute("title", ready ? "" : "Fill in every field above to add this row");
    });
  }
  function clsInitPage() {
    if (!clsPageRoot()) return;
    clsApplyOneTime();
    clsApplyOneTimeLabel();
    clsApplyPositionsToggle();
    clsSyncTitle();
    clsUpdateNewCategoryNote();
    clsUpdateAddButtons();
    clsValidate();
  }
  var clsAutosaveTimer = null;
  function clsScheduleAutosave() {
    if (!document.getElementById("cls_save_status")) return; // edit mode only
    var span = document.getElementById("cls_save_status");
    if (span) span.textContent = "Saving…";
    if (clsAutosaveTimer) window.clearTimeout(clsAutosaveTimer);
    clsAutosaveTimer = window.setTimeout(function () {
      if (window.Shiny) window.Shiny.setInputValue("cls_autosave", Date.now(), { priority: "event" });
    }, 900);
  }
  document.addEventListener("input", function (event) {
    if (event.target && event.target.id === "cls_form_name") clsSyncTitle();
    if (event.target && event.target.closest && event.target.closest(".cls-detail-shell")) { clsValidate(); clsUpdateAddButtons(); }
    if (event.target && event.target.closest && event.target.closest(".cls-summary-surface")) clsScheduleAutosave();
  });
  // CLS Review: the approved-amount pair appears for Approved and Partial only.
  // Approved prefills from the request; Partial is left blank on purpose.
  function clsApplyApprovedFields(sel) {
    if (!sel || !/^cls_rv_bbmr_/.test(sel.id)) return;
    var id = sel.id.replace("cls_rv_bbmr_", "");
    var wrap = document.querySelector('[data-cls-approved-for="' + id + '"]');
    if (!wrap) return;
    var show = sel.value === "Approved" || sel.value === "Partial";
    wrap.style.display = show ? "block" : "none";
    if (sel.value !== "Approved") return;
    var row = sel.closest(".cls-rv-row");
    if (!row) return;
    var amt = document.getElementById("cls_rv_appr_amount_" + id);
    var pos = document.getElementById("cls_rv_appr_positions_" + id);
    var srcAmt = row.querySelector(".cls-rv-amount");
    var srcPos = row.querySelector(".cls-rv-positions");
    if (amt && !(amt.value || "").trim() && srcAmt) {
      amt.value = clsGroupDigits((srcAmt.textContent || "").split(".")[0]);
      amt.dispatchEvent(new Event("change", { bubbles: true }));
    }
    if (pos && !(pos.value || "").trim() && srcPos) {
      pos.value = clsGroupDigits(srcPos.textContent || "");
      pos.dispatchEvent(new Event("change", { bubbles: true }));
    }
  }
  document.addEventListener("change", function (event) {
    if (!event.target) return;
    if (/^cls_rv_bbmr_/.test(event.target.id || "")) clsApplyApprovedFields(event.target);
    if (event.target.id === "cls_form_one_time") { clsApplyOneTime(); clsApplyOneTimeLabel(); clsValidate(); }
    if (event.target.id === "cls_add_positions_toggle") { clsApplyPositionsToggle(); }
    if (event.target.id === "cls_line_spend_category") { clsUpdateNewCategoryNote(); }
    if (event.target.type === "checkbox" && event.target.closest(".cls-cd-panel")) {
      clsUpdateCheckDropdownSummary(event.target.closest(".shiny-input-checkboxgroup"));
    }
    if (event.target.closest && event.target.closest(".cls-detail-shell")) { clsValidate(); clsUpdateAddButtons(); }
    if (event.target.closest && event.target.closest(".cls-summary-surface")) clsScheduleAutosave();
  });
  document.addEventListener("shiny:value", function () { window.setTimeout(clsInitPage, 0); });

  function closeMobileNav() {
    document.body.classList.remove("mobile-nav-open");
    var toggle = document.getElementById("toggle_mobile_nav");
    if (toggle) toggle.setAttribute("aria-expanded", "false");
  }

  // A modal dismissed by navigating away (rather than by its own Close button)
  // can leave its backdrop behind, and Bootstrap's backdrop is a full-page grey
  // veil that swallows every click on the page underneath. Clearing it on each
  // navigation is the fix for "the page sometimes turns grey".
  function clearStaleOverlays() {
    document.querySelectorAll(".modal-backdrop").forEach(function (b) {
      if (b.parentNode) b.parentNode.removeChild(b);
    });
    // Bootstrap parks these on <body> while a modal is up; left behind they lock
    // scrolling and keep the page padded.
    document.body.classList.remove("modal-open");
    if (document.body.style.paddingRight) document.body.style.paddingRight = "";
    // A modal shell that never got torn down hides itself but keeps the veil.
    document.querySelectorAll(".modal.in, .modal.show").forEach(function (m) {
      if (!document.querySelector(".modal-backdrop")) m.classList.remove("in", "show");
    });
  }

  function navigateToPage(page) {
    if (page !== "services") openServiceIds.clear();
    if (page !== "goals") openGoalIds.clear();
    setActivePage(page);
    closeMobileNav();
    clearStaleOverlays();
    window.scrollTo(0, 0);
    if (window.Shiny) {
      window.Shiny.setInputValue("current_page", page, { priority: "event" });
    }
  }

  function beginBackgroundAutosave() {
    backgroundSaveCount += 1;
    document.body.classList.add("background-autosave-active");
    if (backgroundSaveClearTimer) window.clearTimeout(backgroundSaveClearTimer);
    backgroundSaveClearTimer = window.setTimeout(function () {
      backgroundSaveCount = 0;
      document.body.classList.remove("background-autosave-active");
      backgroundSaveClearTimer = null;
    }, 12000);
  }

  function endBackgroundAutosave() {
    backgroundSaveCount = Math.max(0, backgroundSaveCount - 1);
    if (backgroundSaveCount === 0) {
      document.body.classList.remove("background-autosave-active");
      if (backgroundSaveClearTimer) {
        window.clearTimeout(backgroundSaveClearTimer);
        backgroundSaveClearTimer = null;
      }
    }
  }

  function clearPendingNavigation() {
    pendingNavigationPage = null;
    if (pendingNavigationTimer) {
      window.clearTimeout(pendingNavigationTimer);
      pendingNavigationTimer = null;
    }
  }

  function setReviewSaveStatus(message) {
    var status = document.querySelector(".review-save-status");
    if (status) status.textContent = message;
  }

  function requestPlanReviewSave(button, source) {
    if (!button || !window.Shiny) return;
    setReviewSaveStatus(source === "auto" ? "Autosaving review..." : "Saving review...");
    window.Shiny.setInputValue("plan_review_save_request", {
      planId: Number(button.getAttribute("data-plan-review-id")),
      source: source || "manual",
      nonce: Date.now()
    }, { priority: "event" });
  }

  function schedulePlanReviewAutosave(container) {
    var button = container ? container.querySelector("#save_plan_review_scores") : document.getElementById("save_plan_review_scores");
    if (!button) return;
    setReviewSaveStatus("Unsaved review changes. Autosaving...");
    if (reviewAutosaveTimer) window.clearTimeout(reviewAutosaveTimer);
    reviewAutosaveTimer = window.setTimeout(function () {
      requestPlanReviewSave(button, "auto");
    }, 1200);
  }

  function sendPage(page) {
    dismissGoalDeleteDialog();
    var builderPage = currentBuilderPage();
    if (builderPage && builderPage.querySelector(".services-page")) {
      flushServicesQuietAutosave();
      clearPendingNavigation();
      navigateToPage(page);
      return;
    }
    if (builderPage && builderPage.querySelector(".goals-page")) {
      flushGoalsQuietAutosave();
      clearPendingNavigation();
      navigateToPage(page);
      return;
    }
    if (builderPage && builderPage.dataset.autosaveDirty === "true") {
      saveBuilderDraft(builderPage, "navigation", { onlyIfDirty: true });
      clearPendingNavigation();
    }
    navigateToPage(page);
  }

  function applyReviewerPlanFilters() {
    var search = (document.getElementById("reviewer_plan_search") || {}).value || "";
    var status = (document.getElementById("reviewer_status_filter") || {}).value || "";
    var assignee = (document.getElementById("reviewer_assignee_filter") || {}).value || "";
    search = search.trim().toLowerCase();

    document.querySelectorAll(".reviewer-plan-row").forEach(function (row) {
      var matchesSearch = !search || (row.getAttribute("data-reviewer-search") || "").indexOf(search) !== -1;
      var matchesStatus = !status || row.getAttribute("data-reviewer-status") === status;
      var matchesAssignee = !assignee || row.getAttribute("data-reviewer-assignee") === assignee;
      row.style.display = matchesSearch && matchesStatus && matchesAssignee ? "" : "none";
    });
  }

  function clearReviewerPlanFilters() {
    var search = document.getElementById("reviewer_plan_search");
    var status = document.getElementById("reviewer_status_filter");
    var assignee = document.getElementById("reviewer_assignee_filter");
    if (search) search.value = "";
    if (status) status.value = "";
    if (assignee) assignee.value = "";
    applyReviewerPlanFilters();
  }

  function reviewerQueueRenderKey() {
    var rows = Array.prototype.slice.call(document.querySelectorAll(".reviewer-plan-row"));
    if (!rows.length) return "";
    return rows.map(function (row, index) {
      return [
        index,
        row.getAttribute("data-reviewer-status") || "",
        row.getAttribute("data-reviewer-assignee") || ""
      ].join(":");
    }).join("|");
  }

  function clearReviewerPlanFiltersOnQueueRender(force) {
    if (!document.getElementById("reviewer_assignee_filter")) return;
    var key = reviewerQueueRenderKey();
    if (!key) return;
    if (force || key !== reviewerFilterResetKey) {
      reviewerFilterResetKey = key;
      clearReviewerPlanFilters();
    } else {
      applyReviewerPlanFilters();
    }
  }

  function applyMeasureLibrarySearch() {
    var search = (document.getElementById("measure_library_search") || {}).value || "";
    var count = 0;
    search = search.trim().toLowerCase();
    document.querySelectorAll(".measure-library-row").forEach(function (row) {
      var matches = !search || (row.getAttribute("data-measure-search") || "").indexOf(search) !== -1;
      row.style.display = matches ? "" : "none";
      if (matches) count += 1;
    });
    var countLabel = document.querySelector(".measure-library-count");
    if (countLabel) countLabel.textContent = count + " " + (count === 1 ? "measure" : "measures");
  }

  function setNavigationScope(message) {
    var hideServices = Boolean(message && message.hideServices);
    var showPerformanceReviewing = Boolean(message && message.showPerformanceReviewing);
    var showMeasureReview = Boolean(message && message.showMeasureReview);
    var showApprovalQueue = Boolean(message && message.showApprovalQueue);
    var showPublishingQueue = Boolean(message && message.showPublishingQueue);
    var hidePerformancePlanning = Boolean(message && message.hidePerformancePlanning);
    var showApplicationAdmin = Boolean(message && message.showApplicationAdmin);
    var showClsRequests = Boolean(message && message.showClsRequests);
    var showClsReview = Boolean(message && message.showClsReview);
    document.body.classList.toggle("hide-cls-requests", !showClsRequests);
    document.body.classList.toggle("hide-cls-review", !showClsReview);
    document.body.classList.toggle("hide-services-page", hideServices);
    document.body.classList.toggle("hide-performance-reviewing", !showPerformanceReviewing);
    document.body.classList.toggle("hide-measure-review", !showMeasureReview);
    document.body.classList.toggle("hide-approval-queue", !showApprovalQueue);
    document.body.classList.toggle("hide-publishing-queue", !showPublishingQueue);
    document.body.classList.toggle("hide-performance-planning", hidePerformancePlanning);
    document.body.classList.toggle("hide-application-admin", !showApplicationAdmin);
    if (hideServices) {
      document.querySelectorAll('[data-page="services"].active').forEach(function () {
        setActivePage("metrics");
      });
    }
    if (!showPerformanceReviewing) {
      document.querySelectorAll('[data-page="reviewer_dashboard"].active, [data-page="plan_review_detail"].active, [data-page="approval_queue"].active, [data-page="publishing_queue"].active, [data-page="measure_review"].active').forEach(function () {
        setActivePage("landing");
      });
    }
    if (!showMeasureReview) {
      document.querySelectorAll('[data-page="measure_review"].active').forEach(function () {
        setActivePage(showApprovalQueue ? "approval_queue" : "reviewer_dashboard");
      });
    }
    if (!showApprovalQueue) {
      document.querySelectorAll('[data-page="approval_queue"].active').forEach(function () {
        setActivePage("reviewer_dashboard");
      });
    }
    if (!showPublishingQueue) {
      document.querySelectorAll('[data-page="publishing_queue"].active').forEach(function () {
        setActivePage("reviewer_dashboard");
      });
    }
    if (hidePerformancePlanning) {
      document.querySelectorAll('[data-page="strategic_plan"].active, [data-page="plan_history"].active, [data-page="overview"].active, [data-page="goals"].active, [data-page="services"].active, [data-page="metrics"].active, [data-page="risks"].active').forEach(function () {
        setActivePage("reviewer_dashboard");
      });
    }
    if (!showApplicationAdmin) {
      document.querySelectorAll('[data-page="bug_fix"].active').forEach(function () {
        setActivePage("landing");
      });
    }
    if (!showClsRequests) {
      document.querySelectorAll('[data-page="cls_requests"].active').forEach(function () {
        setActivePage("landing");
      });
    }
    if (!showClsReview) {
      document.querySelectorAll('[data-page="cls_review"].active').forEach(function () {
        setActivePage("landing");
      });
    }
  }

  function storedAuthToken() {
    try { return window.localStorage.getItem("beaconAuthToken") || ""; } catch (error) { return ""; }
  }

  function storedAuthEmail() {
    try { return window.localStorage.getItem("beaconAuthEmail") || ""; } catch (error) { return ""; }
  }

  function storeAuthSession(message) {
    if (!message || !message.token) return;
    try {
      window.localStorage.setItem("beaconAuthToken", message.token);
      if (message.email) window.localStorage.setItem("beaconAuthEmail", message.email);
    } catch (error) {}
    resetAuthIdleTimer();
    prefillLoginEmail();
  }

  function clearAuthSession(message) {
    try { window.localStorage.removeItem("beaconAuthToken"); } catch (error) {}
    if (authIdleTimer) {
      window.clearTimeout(authIdleTimer);
      authIdleTimer = null;
    }
    if (authHeartbeatTimer) {
      window.clearTimeout(authHeartbeatTimer);
      authHeartbeatTimer = null;
    }
  }

  function setAuthState(message) {
    var signedIn = Boolean(message && message.signedIn);
    authRestorePending = false;
    document.body.classList.toggle("auth-signed-in", signedIn);
    document.body.classList.toggle("auth-signed-out", !signedIn);
    if (signedIn) {
      resetAuthIdleTimer();
    }
  }

  function requestStoredAuthRestore() {
    if (!window.Shiny) return;
    var token = storedAuthToken();
    if (!token) {
      authRestorePending = false;
      authRestoreAttempted = true;
      setAuthState({ signedIn: false });
      prefillLoginEmail();
      return;
    }
    if (authRestorePending || authRestoreAttempted) return;
    authRestorePending = true;
    authRestoreAttempted = true;
    window.Shiny.setInputValue("auth_restore_session", {
      token: token,
      nonce: Date.now()
    }, { priority: "event" });
    resetAuthIdleTimer();
    prefillLoginEmail();
  }

  function scheduleStoredAuthRestore() {
    window.setTimeout(requestStoredAuthRestore, 50);
  }

  function sendAuthActivity() {
    var token = storedAuthToken();
    if (!window.Shiny || !token || !document.body.classList.contains("auth-signed-in")) return;
    var now = Date.now();
    if (now - lastAuthHeartbeatAt < AUTH_HEARTBEAT_MS) return;
    lastAuthHeartbeatAt = now;
    window.Shiny.setInputValue("auth_session_activity", {
      token: token,
      nonce: now
    }, { priority: "event" });
  }

  function resetAuthIdleTimer() {
    if (!storedAuthToken()) return;
    if (authIdleTimer) window.clearTimeout(authIdleTimer);
    authIdleTimer = window.setTimeout(function () {
      if (!document.body.classList.contains("auth-signed-in")) return;
      requestSignOut("idle");
    }, AUTH_IDLE_MS);
    if (document.body.classList.contains("auth-signed-in")) sendAuthActivity();
  }

  function requestSignOut(reason) {
    var token = storedAuthToken();
    clearAuthSession();
    setAuthState({ signedIn: false });
    if (window.Shiny) {
      window.Shiny.setInputValue("auth_sign_out", {
        token: token,
        reason: reason || "manual",
        nonce: Date.now()
      }, { priority: "event" });
    }
  }

  ["click", "keydown", "pointermove", "scroll", "touchstart"].forEach(function (eventName) {
    document.addEventListener(eventName, function () {
      if (!document.body.classList.contains("auth-signed-in")) return;
      resetAuthIdleTimer();
    }, { passive: true });
  });

  function prefillLoginEmail() {
    var email = storedAuthEmail();
    var input = document.getElementById("login_email");
    if (!email || !input || input.value) return;
    input.value = email;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function submitLoginFromDom() {
    if (!window.Shiny) return;
    var emailInput = document.getElementById("login_email");
    var passwordInput = document.getElementById("login_password");
    var email = emailInput ? emailInput.value : "";
    var password = passwordInput ? passwordInput.value : "";
    [emailInput, passwordInput].forEach(function (input) {
      if (!input) return;
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
    });
    window.Shiny.setInputValue("login_submit_request", {
      email: email,
      password: password,
      nonce: Date.now()
    }, { priority: "event" });
  }

  function registerShinyHandlers() {
    if (!window.Shiny || authHandlersRegistered) return;
    authHandlersRegistered = true;
    window.Shiny.addCustomMessageHandler("set-page", function (page) {
      setActivePage(page);
      if (page === "reviewer_dashboard") {
        reviewerFilterResetKey = "";
      }
      schedulePageInitialization();
    });
    window.Shiny.addCustomMessageHandler("shared-draft-loaded", applyLoadedDraft);
    window.Shiny.addCustomMessageHandler("shared-draft-result", handleDraftSaveResult);
    window.Shiny.addCustomMessageHandler("service-description-draft-result", handleServiceDescriptionDraftResult);
    window.Shiny.addCustomMessageHandler("service-metrics-draft-result", handleServiceMetricsDraftResult);
    window.Shiny.addCustomMessageHandler("services-draft-result", handleServicesDraftResult);
    window.Shiny.addCustomMessageHandler("goals-draft-result", handleGoalsDraftResult);
    window.Shiny.addCustomMessageHandler("plan-review-save-result", handlePlanReviewSaveResult);
    window.Shiny.addCustomMessageHandler("measure-save-result", handleMeasureSaveResult);
    window.Shiny.addCustomMessageHandler("risk-save-result", handleRiskSaveResult);
    window.Shiny.addCustomMessageHandler("team-role-save-result", handleTeamRoleSaveResult);
    window.Shiny.addCustomMessageHandler("trigger-plan-download", triggerPlanDownload);
    window.Shiny.addCustomMessageHandler("set-navigation-scope", setNavigationScope);
    window.Shiny.addCustomMessageHandler("cls-save-status", function (msg) {
      var span = document.getElementById("cls_save_status");
      if (span) span.textContent = msg;
    });
    window.Shiny.addCustomMessageHandler("set-auth-state", setAuthState);
    window.Shiny.addCustomMessageHandler("auth-session-issued", storeAuthSession);
    window.Shiny.addCustomMessageHandler("auth-session-expired", clearAuthSession);
  }

  function selectedMetricsFromEditor(editor) {
    var selected = editor ? (editor.getAttribute("data-selected-metrics") || "") : "";
    return selected.split(",").map(function (value) {
      return value.trim();
    }).filter(function (value) {
      return value !== "";
    });
  }

  function updateServiceEditorMetricMetadata(editor) {
    if (!editor) return;
    var selectors = editor.querySelector(".service-metric-selectors");
    if (!selectors) return;
    var values = Array.from(selectors.querySelectorAll("select")).map(function (select) {
      return select.value;
    }).filter(function (value) {
      return value !== "";
    });
    editor.setAttribute("data-selected-metrics", values.join(","));
    var chip = editor.querySelector(".service-metric-count");
    if (chip) chip.textContent = values.length + " " + (values.length === 1 ? "Metric" : "Metrics");
  }

  function serviceMetricStateKey(editor) {
    if (!editor) return "";
    var page = editor.closest(".builder-page-content");
    var serviceId = editor.getAttribute("data-service-id") || "";
    var planId = page ? page.getAttribute("data-plan-id") || "" : "";
    return planId && serviceId ? planId + "::" + serviceId : "";
  }

  function findServiceEditor(page, serviceId) {
    if (!page || !serviceId) return null;
    var candidates = Array.from(page.querySelectorAll(".service-editor")).filter(function (candidate) {
      return candidate.getAttribute("data-service-id") === String(serviceId);
    });
    if (!candidates.length) return null;
    var openCandidates = candidates.filter(function (candidate) { return candidate.open; });
    var visibleCandidates = (openCandidates.length ? openCandidates : candidates).filter(function (candidate) {
      return candidate.offsetParent !== null || candidate.getClientRects().length > 0;
    });
    return (visibleCandidates.length ? visibleCandidates : (openCandidates.length ? openCandidates : candidates))[0];
  }

  function serviceMetricRowValues(editor, keepBlanks) {
    var container = editor && editor.querySelector(".service-metric-selectors");
    if (!container) return [];
    var values = Array.from(container.querySelectorAll("select")).map(function (select) {
      return select.value || "";
    });
    return keepBlanks ? values : values.filter(function (value) { return value !== ""; });
  }

  function rememberServiceMetricUiState(editor, bumpVersion) {
    var key = serviceMetricStateKey(editor);
    if (!key) return;
    serviceMetricUiState[key] = serviceMetricRowValues(editor, true);
    if (bumpVersion !== false) serviceMetricUiVersion[key] = (serviceMetricUiVersion[key] || 0) + 1;
  }

  function currentServiceMetricUiVersion(editor) {
    var key = serviceMetricStateKey(editor);
    return key ? (serviceMetricUiVersion[key] || 0) : 0;
  }

  function applyServiceMetricUiState(editor) {
    var key = serviceMetricStateKey(editor);
    if (!key || !serviceMetricUiState[key]) return;
    var values = serviceMetricUiState[key];
    var container = editor.querySelector(".service-metric-selectors");
    var picker = container && container.closest(".kpi-picker");
    var firstSelect = container && container.querySelector("select");
    if (!container || !picker || !firstSelect || !values.length) return;
    while (container.querySelectorAll(".kpi-select-row").length > 1) {
      container.querySelector(".kpi-select-row:last-child").remove();
    }
    firstSelect.value = values[0] || "";
    values.slice(1).forEach(function (value) {
      addKpiSelector(picker, value, { skipRemember: true });
    });
    updateKpiPreview(firstSelect);
    updateServiceEditorMetricMetadata(editor);
  }

  function normalizeKpiSelectorRows(picker) {
    var container = picker && picker.querySelector(".kpi-selectors");
    if (!container) return;
    var goalId = container.getAttribute("data-goal-id");
    var serviceId = container.getAttribute("data-service-id");
    Array.from(container.querySelectorAll(".kpi-select-row")).forEach(function (row, index) {
      var select = row.querySelector("select");
      if (select) {
        var nextIndex = index + 1;
        select.id = goalId ? "goal_kpi_" + goalId + "_" + nextIndex : "service_metric_" + serviceId + "_" + nextIndex;
        select.name = select.id;
      }
    });
  }

  function csvValueSet(value) {
    return new Set(String(value || "").split(",").map(function (item) {
      return item.trim();
    }).filter(function (item) {
      return item !== "";
    }));
  }

  function disableLockedBuilderControls(page) {
    if (!page || page.getAttribute("data-plan-locked") !== "true") return;
    page.querySelectorAll("input, textarea, select, button").forEach(function (control) {
      if (control.closest(".rubric-section")) return;
      control.disabled = true;
      control.setAttribute("aria-disabled", "true");
    });
  }

  function requestServiceBody(editor) {
    return;
  }

  function restoreOpenServiceDrawers() {
    var page = document.querySelector(".services-page");
    if (!page || !openServiceIds.size) return;
    page.querySelectorAll(".service-editor[data-service-id]").forEach(function (editor) {
      var serviceId = editor.getAttribute("data-service-id") || "";
      if (!openServiceIds.has(serviceId)) return;
      editor.open = true;
      var body = editor.querySelector(".service-editor-body");
      if (body) body.setAttribute("aria-hidden", "false");
      requestServiceBody(editor);
    });
  }

  function restoreOpenGoalDrawers() {
    var page = document.querySelector(".goals-page");
    if (!page || !openGoalIds.size) return;
    page.querySelectorAll(".goal-editor[data-goal-id]").forEach(function (editor) {
      var goalId = editor.getAttribute("data-goal-id") || "";
      if (!openGoalIds.has(goalId)) return;
      editor.open = true;
      var body = editor.querySelector(".goal-editor-body");
      if (body) body.setAttribute("aria-hidden", "false");
    });
  }

  function applyFeedbackFilters() {
    function filterValue(id) {
      var element = document.getElementById(id);
      if (!element) return "";
      if (element.selectize && typeof element.selectize.getValue === "function") return element.selectize.getValue() || "";
      if (element.multiple) {
        return Array.prototype.map.call(element.selectedOptions || [], function (option) { return option.value; }).filter(Boolean);
      }
      return element.value || "";
    }
    function filterMatches(selected, value) {
      if (Array.isArray(selected)) return !selected.length || selected.indexOf(value) !== -1;
      return !selected || selected === value;
    }
    var search = (filterValue("feedback_search") || "").trim().toLowerCase();
    var category = filterValue("feedback_category_filter");
    var priority = filterValue("feedback_priority_filter");
    var status = filterValue("feedback_status_filter");
    document.querySelectorAll("[data-feedback-row]").forEach(function (row) {
      var matchesSearch = !search || (row.getAttribute("data-feedback-search") || "").indexOf(search) !== -1;
      var matchesCategory = filterMatches(category, row.getAttribute("data-feedback-category") || "");
      var matchesPriority = filterMatches(priority, row.getAttribute("data-feedback-priority") || "");
      var matchesStatus = filterMatches(status, row.getAttribute("data-feedback-status") || "");
      row.style.display = matchesSearch && matchesCategory && matchesPriority && matchesStatus ? "" : "none";
    });
  }

  function scheduleFeedbackFilterApply() {
    window.setTimeout(applyFeedbackFilters, 0);
    window.setTimeout(applyFeedbackFilters, 150);
  }

  function bindFeedbackFilterControls() {
    ["feedback_category_filter", "feedback_priority_filter", "feedback_status_filter"].forEach(function (id) {
      var element = document.getElementById(id);
      if (!element || element.dataset.feedbackFilterBound === "true") return;
      element.dataset.feedbackFilterBound = "true";
      element.addEventListener("change", applyFeedbackFilters);
      if (window.jQuery && window.jQuery.fn) {
        window.jQuery(element).off("change.feedbackFilter").on("change.feedbackFilter", applyFeedbackFilters);
      }
    });
  }

  function setFeedbackScreenshotData(dataUrl) {
    var hidden = document.getElementById("feedback_screenshot_data");
    var preview = document.getElementById("feedback_screenshot_preview");
    if (hidden) hidden.value = dataUrl || "";
    if (!preview) return;
    if (!dataUrl) {
      preview.textContent = "No screenshot attached";
      preview.classList.remove("has-image");
      return;
    }
    preview.classList.add("has-image");
    preview.innerHTML = "";
    var image = document.createElement("img");
    image.src = dataUrl;
    image.alt = "Screenshot preview";
    preview.appendChild(image);
  }

  function readFeedbackImageFile(file) {
    if (!file || !file.type || file.type.indexOf("image/") !== 0) return;
    var reader = new FileReader();
    reader.onload = function () {
      setFeedbackScreenshotData(String(reader.result || ""));
    };
    reader.readAsDataURL(file);
  }

  function sendFeedbackAdminUpdate(feedbackId, statusOverride) {
    var category = (document.getElementById("feedback_category_" + feedbackId) || {}).value || "Uncategorized";
    var priority = (document.getElementById("feedback_priority_" + feedbackId) || {}).value || "Unassigned";
    var status = statusOverride || (document.getElementById("feedback_status_" + feedbackId) || {}).value || "New";
    var assignedAdminId = (document.getElementById("feedback_assigned_admin_" + feedbackId) || {}).value || "";
    if (!window.Shiny) return;
    window.Shiny.setInputValue("feedback_admin_update", {
      feedbackId: feedbackId,
      category: category,
      priority: priority,
      status: status,
      assignedAdminId: assignedAdminId,
      nonce: Date.now()
    }, { priority: "event" });
  }

  function closeFeedbackImageViewer() {
    var viewer = document.getElementById("feedback_image_viewer");
    if (viewer) viewer.remove();
  }

  function openFeedbackImageViewer(src) {
    closeFeedbackImageViewer();
    if (!src) return;
    var viewer = document.createElement("div");
    viewer.id = "feedback_image_viewer";
    viewer.className = "feedback-image-viewer";
    viewer.setAttribute("role", "dialog");
    viewer.setAttribute("aria-modal", "true");
    viewer.innerHTML = [
      '<div class="feedback-image-viewer-panel">',
      '<button type="button" class="icon-button feedback-image-viewer-close" aria-label="Close screenshot">×</button>',
      '<img alt="Feedback screenshot" src="' + src.replace(/"/g, "&quot;") + '">',
      '</div>'
    ].join("");
    document.body.appendChild(viewer);
  }

  document.addEventListener("click", function (event) {
    if (event.target.closest("#clear_reviewer_filters")) {
      clearReviewerPlanFilters();
      return;
    }
    if (event.target.closest("#open_feedback_modal")) {
      if (window.Shiny) window.Shiny.setInputValue("open_feedback_modal_request", Date.now(), { priority: "event" });
      return;
    }
    if (event.target.closest("#close_feedback_modal")) {
      if (window.Shiny) window.Shiny.setInputValue("close_feedback_modal", Date.now(), { priority: "event" });
      return;
    }
    if (event.target.closest("#submit_feedback")) {
      if (window.Shiny) {
        window.Shiny.setInputValue("submit_feedback_request", {
          page: document.querySelector("[data-page].active") ? document.querySelector("[data-page].active").getAttribute("data-page") : "",
          pageUrl: window.location.href,
          screenshotData: (document.getElementById("feedback_screenshot_data") || {}).value || "",
          nonce: Date.now()
        }, { priority: "event" });
      }
      return;
    }
    if (event.target.closest(".feedback-image-viewer-close") || event.target.id === "feedback_image_viewer") {
      closeFeedbackImageViewer();
      return;
    }
    var screenshotLink = event.target.closest(".feedback-screenshot-link");
    if (screenshotLink) {
      event.preventDefault();
      openFeedbackImageViewer(screenshotLink.getAttribute("href"));
      return;
    }
    var saveFeedback = event.target.closest("[data-feedback-save]");
    if (saveFeedback) {
      sendFeedbackAdminUpdate(saveFeedback.getAttribute("data-feedback-save"));
      return;
    }
    var completeFeedback = event.target.closest("[data-feedback-complete]");
    if (completeFeedback) {
      sendFeedbackAdminUpdate(completeFeedback.getAttribute("data-feedback-complete"), "Complete");
      return;
    }
    var archiveFeedback = event.target.closest("[data-feedback-archive]");
    if (archiveFeedback) {
      sendFeedbackAdminUpdate(archiveFeedback.getAttribute("data-feedback-archive"), "Archived");
      return;
    }
    var deleteFeedback = event.target.closest("[data-feedback-delete]");
    if (deleteFeedback) {
      if (window.Shiny && window.confirm("Are you sure you want to delete this feedback request?")) {
        window.Shiny.setInputValue("feedback_admin_delete", {
          feedbackId: deleteFeedback.getAttribute("data-feedback-delete"),
          nonce: Date.now()
        }, { priority: "event" });
      }
      return;
    }
    var signOutButton = event.target.closest('[data-auth-action="sign-out"]');
    if (signOutButton) {
      event.preventDefault();
      requestSignOut();
      return;
    }
    var clsRvToggle = event.target.closest("[data-cls-rv-toggle]");
    if (clsRvToggle && !clsRvToggle.classList.contains("cls-rv-header-row")) {
      var rvRow = clsRvToggle.closest(".cls-rv-row");
      var rvBody = rvRow ? rvRow.querySelector(".cls-rv-body") : null;
      if (!rvBody) rvBody = document.getElementById("cls_rv_body_" + clsRvToggle.getAttribute("data-cls-rv-toggle"));
      if (rvBody) {
        // Read the rendered state so a second click collapses the row.
        var rvHidden = window.getComputedStyle(rvBody).display === "none";
        rvBody.style.display = rvHidden ? "block" : "none";
        clsRvToggle.setAttribute("aria-expanded", rvHidden ? "true" : "false");
      }
      return;
    }
    // Analyst feedback: pencil opens the row's inline editor; Cancel closes it.
    // Checkbox dropdown filters: toggle the panel, select all / clear.
    var cdToggle = event.target.closest("[data-cls-cd-toggle]");
    if (cdToggle) {
      var key = cdToggle.getAttribute("data-cls-cd-toggle");
      var panel = document.querySelector('[data-cls-cd-panel="' + key + '"]');
      if (panel) {
        var open = window.getComputedStyle(panel).display !== "none";
        clsCloseAllCheckDropdowns();
        if (!open) { panel.style.display = "block"; cdToggle.setAttribute("aria-expanded", "true"); }
      }
      return;
    }
    var cdAll = event.target.closest("[data-cls-cd-all]");
    var cdNone = event.target.closest("[data-cls-cd-none]");
    if (cdAll || cdNone) {
      var id = (cdAll || cdNone).getAttribute(cdAll ? "data-cls-cd-all" : "data-cls-cd-none");
      var group = document.getElementById(id);
      if (group) {
        group.querySelectorAll('input[type="checkbox"]').forEach(function (cb) {
          if (cb.checked !== !!cdAll) { cb.checked = !!cdAll; }
        });
        // Held like a manual tick: applied when the panel is applied or closed.
        var groupPanel = group.closest(".cls-cd-panel");
        if (groupPanel) {
          groupPanel.classList.add("cls-cd-dirty");
          clsMarkCheckDropdownDirty(groupPanel);
        }
        clsUpdateCheckDropdownSummary(group);
      }
      return;
    }
    // Apply pushes the held ticks and closes the panel.
    var cdApply = event.target.closest("[data-cls-cd-apply]");
    if (cdApply) {
      clsCloseAllCheckDropdowns();
      return;
    }
    // A click anywhere else closes any open filter panel, applying it on the way.
    if (!event.target.closest(".cls-cd-panel")) clsCloseAllCheckDropdowns();
    // Fold the chart away; the label and caret follow the state.
    var clsChartToggle = event.target.closest("[data-cls-chart-toggle]");
    if (clsChartToggle) {
      var panel = document.getElementById(clsChartToggle.getAttribute("data-cls-chart-toggle"));
      if (panel) {
        var hidden = window.getComputedStyle(panel).display === "none";
        panel.style.display = hidden ? "block" : "none";
        clsChartToggle.setAttribute("aria-expanded", hidden ? "true" : "false");
        var lbl = clsChartToggle.querySelector(".cls-chart-toggle-label");
        if (lbl) lbl.textContent = hidden ? "Hide chart" : "Show chart";
        clsChartToggle.classList.toggle("is-collapsed", !hidden);
      }
      return;
    }
    var clsBulk = event.target.closest("[data-cls-bulk-approve]");
    if (clsBulk && window.Shiny) {
      window.Shiny.setInputValue("cls_bulk_approve", {
        what: clsBulk.getAttribute("data-cls-bulk-approve"), nonce: Date.now()
      }, { priority: "event" });
      return;
    }
    var clsEditLine = event.target.closest("[data-cls-edit-line]");
    if (clsEditLine && window.Shiny) {
      window.Shiny.setInputValue("cls_edit_line", {
        lineId: clsEditLine.getAttribute("data-cls-edit-line"), nonce: Date.now()
      }, { priority: "event" });
      return;
    }
    var clsEditPos = event.target.closest("[data-cls-edit-position]");
    if (clsEditPos && window.Shiny) {
      window.Shiny.setInputValue("cls_edit_position", {
        posId: clsEditPos.getAttribute("data-cls-edit-position"), nonce: Date.now()
      }, { priority: "event" });
      return;
    }
    var clsCancelEdit = event.target.closest("[data-cls-cancel-edit]");
    if (clsCancelEdit && window.Shiny) {
      window.Shiny.setInputValue("cls_cancel_edit", {
        what: clsCancelEdit.getAttribute("data-cls-cancel-edit"), nonce: Date.now()
      }, { priority: "event" });
      return;
    }
    var clsInfoBtn = event.target.closest("[data-cls-info]");
    if (clsInfoBtn) {
      event.preventDefault();
      clsToggleInfoPanel(clsInfoBtn.getAttribute("data-cls-info"), clsInfoBtn);
      return;
    }
    var clsCostHelp = event.target.closest("[data-cls-cost-help]");
    if (clsCostHelp) {
      // Placeholder until the salary/benefit cost reference is wired up.
      event.preventDefault();
      return;
    }
    var clsSubmitOne = event.target.closest("[data-cls-submit]");
    if (clsSubmitOne && window.Shiny) {
      window.Shiny.setInputValue("cls_submit_one", {
        clsId: clsSubmitOne.getAttribute("data-cls-submit"),
        nonce: Date.now()
      }, { priority: "event" });
      return;
    }
    var clsSendBbmr = event.target.closest("[data-cls-send-bbmr]");
    if (clsSendBbmr && window.Shiny) {
      window.Shiny.setInputValue("cls_send_bbmr_one", {
        clsId: clsSendBbmr.getAttribute("data-cls-send-bbmr"),
        nonce: Date.now()
      }, { priority: "event" });
      return;
    }
    // Send a submitted request back to the agency, which unlocks it for editing.
    // Confirmed first: it clears the recorded decision and the agency sees the
    // change immediately.
    var clsSendBack = event.target.closest("[data-cls-send-back]");
    if (clsSendBack && window.Shiny) {
      var backName = clsSendBack.getAttribute("data-cls-name") || "this request";
      if (window.confirm('Send "' + backName + '" back to the agency?\n\nThis unlocks it for editing and clears any approval already recorded. Analyst notes are kept.')) {
        window.Shiny.setInputValue("cls_send_back", {
          clsId: clsSendBack.getAttribute("data-cls-send-back"),
          nonce: Date.now()
        }, { priority: "event" });
      }
      return;
    }
    var clsReviewSave = event.target.closest("[data-cls-review-save]");
    if (clsReviewSave && window.Shiny) {
      window.Shiny.setInputValue("cls_review_save", {
        clsId: clsReviewSave.getAttribute("data-cls-review-save"),
        nonce: Date.now()
      }, { priority: "event" });
      return;
    }
    var clsSort = event.target.closest("[data-cls-sort]");
    if (clsSort) {
      var table = clsSort.closest(".cls-request-table");
      if (table) {
        var key = clsSort.getAttribute("data-cls-sort");
        var asc = clsSort.getAttribute("data-sort-dir") !== "asc";
        table.querySelectorAll("[data-cls-sort]").forEach(function (b) {
          if (b !== clsSort) b.removeAttribute("data-sort-dir");
        });
        clsSort.setAttribute("data-sort-dir", asc ? "asc" : "desc");
        var sortRows = Array.prototype.slice.call(table.querySelectorAll(".cls-request-row:not(.table-head)"));
        sortRows.sort(function (a, b) {
          if (key === "amount") {
            var an = parseFloat(a.getAttribute("data-sort-amount"));
            var bn = parseFloat(b.getAttribute("data-sort-amount"));
            if (isNaN(an)) an = -Infinity;
            if (isNaN(bn)) bn = -Infinity;
            return asc ? an - bn : bn - an;
          }
          var av = a.getAttribute("data-sort-" + key) || "";
          var bv = b.getAttribute("data-sort-" + key) || "";
          return asc ? av.localeCompare(bv) : bv.localeCompare(av);
        });
        sortRows.forEach(function (r) { table.appendChild(r); });
      }
      return;
    }
    var clsBackLink = event.target.closest(".cls-back-link");
    if (clsBackLink) {
      var backShell = clsBackLink.closest(".cls-detail-shell");
      // Only nag when there is actually a request being edited.
      if (backShell && backShell.querySelector("#cls_form_amount")) {
        // Analyst feedback: the summary fields are mandatory, so an incomplete
        // first container blocks navigation rather than just warning.
        var summaryGaps = clsSummaryGaps(backShell);
        if (summaryGaps.length) {
          event.preventDefault();
          event.stopPropagation();
          window.alert("You have missing fields. Complete these before leaving this request:\n\n\u2022 " +
            summaryGaps.join("\n\u2022 "));
          return;
        }
        // A request that is fully justified leaves quietly - there is nothing to
        // tell the user (analyst feedback round 2).
        if (!clsRequestIsComplete(backShell)) {
          window.alert("You have missing fields. This request is not fully described by object and positions.");
        }
      }
      // fall through to the [data-page] navigation below
    }
    var clsOpen = event.target.closest("[data-cls-open]");
    if (clsOpen && window.Shiny) {
      window.Shiny.setInputValue("cls_open_detail", {
        clsId: clsOpen.getAttribute("data-cls-open"),
        nonce: Date.now()
      }, { priority: "event" });
      return;
    }
    var clsDelete = event.target.closest("[data-cls-delete]");
    if (clsDelete && window.Shiny) {
      var clsName = clsDelete.getAttribute("data-cls-name") || "this request";
      if (window.confirm('Delete "' + clsName + '"? This also removes its line items and positions.')) {
        window.Shiny.setInputValue("cls_delete", {
          clsId: clsDelete.getAttribute("data-cls-delete"),
          nonce: Date.now()
        }, { priority: "event" });
      }
      return;
    }
    var clsDeleteLine = event.target.closest("[data-cls-delete-line]");
    if (clsDeleteLine && window.Shiny) {
      if (window.confirm("Remove this line item?")) {
        window.Shiny.setInputValue("cls_delete_line", {
          lineId: clsDeleteLine.getAttribute("data-cls-delete-line"),
          nonce: Date.now()
        }, { priority: "event" });
      }
      return;
    }
    var clsDeletePosition = event.target.closest("[data-cls-delete-position]");
    if (clsDeletePosition && window.Shiny) {
      if (window.confirm("Remove this position request?")) {
        window.Shiny.setInputValue("cls_delete_position", {
          posId: clsDeletePosition.getAttribute("data-cls-delete-position"),
          nonce: Date.now()
        }, { priority: "event" });
      }
      return;
    }
    var button = event.target.closest("[data-page]");
    if (!button) return;
    if (button.hasAttribute("data-new-measure")) return;
    var targetPage = button.getAttribute("data-page");
    if (targetPage === "reviewer_dashboard") {
      reviewerFilterResetKey = "";
      window.setTimeout(function () { clearReviewerPlanFiltersOnQueueRender(true); }, 150);
      window.setTimeout(function () { clearReviewerPlanFiltersOnQueueRender(true); }, 500);
    }
    sendPage(targetPage);
  });

  document.addEventListener("change", function (event) {
    var feedbackControl = event.target.closest(".feedback-admin-controls select");
    if (feedbackControl) {
      var feedbackCard = feedbackControl.closest("[data-feedback-row]");
      if (feedbackCard) {
        sendFeedbackAdminUpdate(feedbackCard.getAttribute("data-feedback-row"));
      }
      return;
    }
  });

  document.addEventListener("input", function (event) {
    if (event.target && event.target.id === "reviewer_plan_search") {
      applyReviewerPlanFilters();
    }
    if (event.target && event.target.id === "measure_library_search") {
      applyMeasureLibrarySearch();
    }
    if (event.target && event.target.id === "feedback_search") {
      applyFeedbackFilters();
    }
  });

  document.addEventListener("change", function (event) {
    if (!event.target) return;
    if (["reviewer_status_filter", "reviewer_assignee_filter"].includes(event.target.id)) {
      applyReviewerPlanFilters();
    }
    if (["feedback_category_filter", "feedback_priority_filter", "feedback_status_filter"].includes(event.target.id)) {
      applyFeedbackFilters();
    }
    if (event.target.id === "feedback_screenshot_file") {
      readFeedbackImageFile(event.target.files && event.target.files[0]);
    }
  });

  document.addEventListener("shiny:value", function () {
    if (document.querySelector(".feedback-admin-list")) {
      bindFeedbackFilterControls();
      scheduleFeedbackFilterApply();
    }
  });

  // The measure modal renders in its own uiOutput, outside #page, so the
  // #page MutationObserver that normally calls updateMeasureNumberFormat()
  // on render never sees it -- without this, opening an existing measure
  // whose stored value already looks like an unconverted fraction wouldn't
  // show the warning until the person touched an input themselves.
  document.addEventListener("shiny:value", function () {
    if (document.querySelector(".measure-editor-modal")) updateMeasureNumberFormat();
  });

  document.addEventListener("shiny:bound", function (event) {
    if (event.target && ["feedback_category_filter", "feedback_priority_filter", "feedback_status_filter"].includes(event.target.id)) {
      bindFeedbackFilterControls();
      scheduleFeedbackFilterApply();
    }
  });

  window.setTimeout(bindFeedbackFilterControls, 500);

  document.addEventListener("paste", function (event) {
    if (!document.querySelector(".feedback-modal-panel")) return;
    var items = event.clipboardData && event.clipboardData.items;
    if (!items) return;
    for (var i = 0; i < items.length; i += 1) {
      if (items[i].type.indexOf("image/") === 0) {
        readFeedbackImageFile(items[i].getAsFile());
        break;
      }
    }
  });

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") closeFeedbackImageViewer();
  });

  document.addEventListener("click", function (event) {
    if (event.target.closest("[data-measure-review-action]")) return;
    // The Action Plan Measures row is clickable to open the measure, but
    // also holds an owning-entity <select> -- clicking or picking from
    // that select must not also open the row's measure modal underneath it.
    if (event.target.closest(".action-plan-measure-owner-select")) return;
    var row = event.target.closest("[data-measure-id]");
    var addButton = event.target.closest("[data-new-measure]");
    if ((!row && !addButton) || !window.Shiny) return;
    if (addButton) {
      sendPage(addButton.getAttribute("data-page") || "metrics");
    }
    // "new:city" (vs. plain "new") tells the server to pre-check "Citywide
    // measure" for this new measure -- used by the Add button on the
    // Action Plan Measures page, so a measure created from there doesn't
    // silently fail to show back up in that same list until someone
    // remembers to check the box by hand.
    var newMeasureValue = addButton && addButton.getAttribute("data-default-city") === "true" ? "new:city" : "new";
    window.Shiny.setInputValue("open_measure_id", addButton ? newMeasureValue : row.getAttribute("data-measure-id"), { priority: "event" });
  });

  // The Action Plan Measures row itself is a div (role="button", not a
  // real <button>) so it can host the owner <select> without nesting
  // interactive content inside a button element -- restore Enter/Space
  // keyboard activation by re-dispatching as a click, which the delegate
  // above already handles.
  document.addEventListener("keydown", function (event) {
    if (event.key !== "Enter" && event.key !== " ") return;
    var row = event.target.closest(".action-plan-measures-row[role='button']");
    if (!row || event.target.closest("select")) return;
    event.preventDefault();
    row.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });

  document.addEventListener("change", function (event) {
    var select = event.target.closest(".action-plan-measure-owner-select");
    if (!select || !window.Shiny) return;
    window.Shiny.setInputValue("action_plan_measure_owner_request", {
      measureId: Number(select.getAttribute("data-measure-id")),
      value: select.value,
      nonce: Date.now()
    }, { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    var button = event.target.closest("[data-measure-review-action]");
    if (!button || !window.Shiny) return;
    event.preventDefault();
    window.Shiny.setInputValue("measure_review_decision", {
      measureId: Number(button.getAttribute("data-measure-id")),
      action: button.getAttribute("data-measure-review-action"),
      nonce: Date.now()
    }, { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    if (!event.target.closest("[data-guidance-download]") || !window.Shiny) return;
    window.Shiny.setInputValue("guidance_download_started", Date.now(), { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    var button = event.target.closest("[data-team-access-id]");
    if (!button || !window.Shiny) return;
    event.preventDefault();
    window.Shiny.setInputValue("open_team_access_id", {
      accessId: button.getAttribute("data-team-access-id"),
      nonce: Date.now()
    }, { priority: "event" });
  });

  document.addEventListener("keydown", function (event) {
    if (event.key !== "Enter" && event.key !== " ") return;
    var row = event.target.closest("[data-team-access-id]");
    if (!row || !window.Shiny) return;
    event.preventDefault();
    window.Shiny.setInputValue("open_team_access_id", {
      accessId: row.getAttribute("data-team-access-id"),
      nonce: Date.now()
    }, { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    var row = event.target.closest("[data-risk-id]");
    var addButton = event.target.closest("[data-new-risk]");
    if ((!row && !addButton) || !window.Shiny) return;
    window.Shiny.setInputValue("open_risk_id", addButton ? "new" : row.getAttribute("data-risk-id"), { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    var duplicateButton = event.target.closest("[data-duplicate-plan]");
    var reviewButton = event.target.closest("[data-review-plan]");
    var exportButton = event.target.closest("[data-export-plan]");
    if ((!duplicateButton && !reviewButton && !exportButton) || !window.Shiny) return;
    if (duplicateButton) {
      window.Shiny.setInputValue("duplicate_plan_from", {
        planId: Number(duplicateButton.getAttribute("data-duplicate-plan")),
        nonce: Date.now()
      }, { priority: "event" });
    }
    if (reviewButton) {
      var activePage = document.querySelector("[data-page].active");
      window.Shiny.setInputValue("review_plan_request", {
        planId: Number(reviewButton.getAttribute("data-review-plan")),
        includeReview: reviewButton.getAttribute("data-include-review") !== "false",
        returnPage: activePage ? activePage.getAttribute("data-page") : "reviewer_dashboard",
        nonce: Date.now()
      }, { priority: "event" });
    }
    if (exportButton) {
      var exportPayload = {
        planId: Number(exportButton.getAttribute("data-export-plan")),
        exportType: exportButton.getAttribute("data-export-type"),
        includeReview: exportButton.getAttribute("data-include-review") !== "false",
        nonce: Date.now()
      };
      var builderPage = currentBuilderPage();
      if (
        builderPage &&
        Number(builderPage.getAttribute("data-plan-id")) === exportPayload.planId &&
        builderPage.getAttribute("data-section-key")
      ) {
        var goalsPage = builderPage.querySelector(".goals-page");
        var draft = goalsPage ? collectGoalsDraft(goalsPage) : collectBuilderDraft(builderPage);
        exportPayload.draftSectionKey = builderPage.getAttribute("data-section-key");
        exportPayload.draftPayloadJson = JSON.stringify(draft);
      }
      if (!exportPayload.draftPayloadJson) {
        var recoveryGoalsDraft = recoveryGoalsDraftForPlan(exportPayload.planId);
        if (recoveryGoalsDraft) {
          exportPayload.draftSectionKey = "goals";
          exportPayload.draftPayloadJson = recoveryGoalsDraft;
        }
      }
      window.Shiny.setInputValue("export_plan_request", exportPayload, { priority: "event" });
    }
  });

  document.addEventListener("click", function (event) {
    var saveButton = event.target.closest("#save_measure");
    var submitButton = event.target.closest("#submit_measure");
    var clickedButton = saveButton || submitButton;
    if (!clickedButton || !window.Shiny) return;
    // Ignore a repeat click while the previous one is still in flight --
    // see disableButtonsForSave()'s comment above for why.
    if (clickedButton.disabled) return;
    event.preventDefault();
    updateMeasureNumberFormat();
    disableButtonsForSave(["save_measure", "submit_measure"], clickedButton.id, saveButton ? "Saving..." : "Submitting...");
    window.Shiny.setInputValue(saveButton ? "measure_save_request" : "measure_submit_request", Date.now(), { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    if (!event.target.closest("#delete_measure") || !window.Shiny) return;
    event.preventDefault();
    event.stopPropagation();
    if (!window.confirm("Are you sure you want to delete this measure? This removes its actuals, targets, service links, goal links, and review history.")) return;
    window.Shiny.setInputValue("measure_delete_confirmed_request", Date.now(), { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    var saveButton = event.target.closest("#save_risk");
    if (!saveButton || !window.Shiny) return;
    if (saveButton.disabled) return;
    event.preventDefault();
    disableButtonsForSave(["save_risk"], "save_risk", "Saving...");
    window.Shiny.setInputValue("risk_save_request", Date.now(), { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    if (!event.target.closest("#delete_risk") || !window.Shiny) return;
    event.preventDefault();
    event.stopPropagation();
    if (!window.confirm("Are you sure you want to delete this risk?")) return;
    window.Shiny.setInputValue("risk_delete_confirmed_request", Date.now(), { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    var saveButton = event.target.closest("#save_team_role");
    if (!saveButton || !window.Shiny) return;
    if (saveButton.disabled) return;
    event.preventDefault();
    disableButtonsForSave(["save_team_role"], "save_team_role", "Saving...");
    window.Shiny.setInputValue("team_role_save_request", Date.now(), { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    if (!event.target.closest("#login_email_continue")) return;
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    submitLoginFromDom();
  }, true);

  document.addEventListener("click", function (event) {
    var pillarButton = event.target.closest("[id^='open_pillar_']");
    if (!pillarButton || !window.Shiny) return;
    var pillarId = pillarButton.id.replace(/^open_pillar_/, "");
    if (!pillarId) return;
    event.preventDefault();
    event.stopPropagation();
    window.Shiny.setInputValue("open_pillar_request", {
      pillarId: pillarId,
      nonce: Date.now()
    }, { priority: "event" });
  }, true);

  document.addEventListener("keydown", function (event) {
    if (event.key !== "Enter") return;
    var target = event.target;
    if (!target || !target.closest) return;
    var triggerShinyAction = function (id) {
      var button = document.getElementById(id);
      if (button && typeof button.click === "function") {
        button.click();
        return;
      }
      if (window.Shiny) {
        window.Shiny.setInputValue(id, Date.now(), { priority: "event" });
      }
    };
    if (target.closest("#login_email, #login_password")) {
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();
      if (target.closest("#login_password")) {
        window.setTimeout(submitLoginFromDom, 0);
      }
      return;
    }
    if (target.closest("#request_email")) {
      event.preventDefault();
      triggerShinyAction("request_submit");
    }
    if (target.closest("#reset_password, #reset_confirm")) {
      event.preventDefault();
      triggerShinyAction("reset_submit");
    }
  });

  document.addEventListener("keyup", function (event) {
    if (event.key !== "Enter") return;
    var target = event.target;
    if (!target || !target.closest || !target.closest("#login_email")) return;
    event.preventDefault();
    window.setTimeout(submitLoginFromDom, 0);
  });

  document.addEventListener("click", function (event) {
    if (!event.target.closest("#delete_team_role") || !window.Shiny) return;
    event.preventDefault();
    event.stopPropagation();
    if (!window.confirm("Are you sure you want to delete this user from this team?")) return;
    window.Shiny.setInputValue("team_role_delete_confirmed_request", Date.now(), { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    var button = event.target.closest("#save_plan_review_scores");
    if (!button || !window.Shiny) return;
    event.preventDefault();
    requestPlanReviewSave(button, "manual");
  });

  document.addEventListener("click", function (event) {
    var button = event.target.closest("#save_plan_reviewer");
    if (!button || !window.Shiny) return;
    event.preventDefault();
    window.Shiny.setInputValue("plan_reviewer_save_request", {
      planId: Number(button.getAttribute("data-plan-review-id")),
      nonce: Date.now()
    }, { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    var button = event.target.closest("#approve_plan_review");
    if (!button || !window.Shiny) return;
    event.preventDefault();
    if (button.getAttribute("data-approval-action") === "rescind") {
      if (!window.confirm("Rescind the reviewer approval stamp? This will record your user account.")) return;
      window.Shiny.setInputValue("plan_approval_stamp_request", {
        planId: Number(button.getAttribute("data-plan-review-id")),
        stage: "Reviewer",
        action: "remove",
        nonce: Date.now()
      }, { priority: "event" });
      return;
    }
    var selector = document.getElementById("plan_review_next_status");
    var routeTo = selector ? selector.value : "";
    if (!routeTo) return;
    var routeLabel = selector && selector.options[selector.selectedIndex] ? selector.options[selector.selectedIndex].text : "the selected destination";
    var confirmMessage = routeTo === "CAReview"
      ? "Are you sure you want to route this plan to CA Office?"
      : "Route this plan to " + routeLabel + "?";
    if (!window.confirm(confirmMessage)) return;
    button.disabled = true;
    button.setAttribute("aria-busy", "true");
    button.dataset.originalLabel = button.innerHTML;
    button.innerHTML = "Routing...";
    window.Shiny.setInputValue("plan_review_approve_request", {
      planId: Number(button.getAttribute("data-plan-review-id")),
      nextStatus: routeTo,
      nonce: Date.now()
    }, { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    var button = event.target.closest("#approve_plan_gate");
    if (!button || !window.Shiny) return;
    event.preventDefault();
    var stage = button.getAttribute("data-approval-stage") || "approval";
    if (button.getAttribute("data-approval-action") === "rescind") {
      if (!window.confirm("Rescind this " + stage + " approval stamp? This will record your user account.")) return;
      window.Shiny.setInputValue("plan_approval_stamp_request", {
        planId: Number(button.getAttribute("data-plan-id")),
        stage: stage,
        action: "remove",
        nonce: Date.now()
      }, { priority: "event" });
      return;
    }
    if (!window.confirm("Approve this " + stage + " step and route the plan forward?")) return;
    window.Shiny.setInputValue("plan_gate_approve_request", {
      planId: Number(button.getAttribute("data-plan-id")),
      stage: stage,
      nonce: Date.now()
    }, { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    var button = event.target.closest("#return_plan_gate");
    if (!button || !window.Shiny) return;
    event.preventDefault();
    var selector = document.getElementById("plan_gate_return_status");
    var noteField = document.getElementById("plan_gate_return_note");
    var routeTo = selector ? selector.value : "";
    var note = noteField ? noteField.value.trim() : "";
    if (!routeTo) return;
    if (!note) {
      window.alert("Add a return reason before returning this plan.");
      if (noteField) noteField.focus();
      return;
    }
    if (!window.confirm("Return this plan to the selected queue?")) return;
    window.Shiny.setInputValue("plan_gate_return_request", {
      planId: Number(button.getAttribute("data-plan-id")),
      stage: button.getAttribute("data-approval-stage") || "",
      nextStatus: routeTo,
      note: note,
      nonce: Date.now()
    }, { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    var button = event.target.closest("[data-publishing-route-plan]");
    if (!button || !window.Shiny) return;
    event.preventDefault();
    var planId = Number(button.getAttribute("data-publishing-route-plan"));
    var selector = document.getElementById("publishing_route_status_" + planId);
    var routeTo = selector ? selector.value : "";
    if (!routeTo) return;
    if (!window.confirm("Route this ready-to-publish plan back to the selected queue?")) return;
    window.Shiny.setInputValue("publishing_route_request", {
      planId: planId,
      nextStatus: routeTo,
      nonce: Date.now()
    }, { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    var button = event.target.closest("#return_publishing_plan");
    if (!button || !window.Shiny) return;
    event.preventDefault();
    var planId = Number(button.getAttribute("data-plan-id"));
    var selector = document.getElementById("publishing_detail_route_status");
    var routeTo = selector ? selector.value : "";
    if (!routeTo) return;
    if (!window.confirm("Return this ready-to-publish plan to the selected queue?")) return;
    window.Shiny.setInputValue("publishing_route_request", {
      planId: planId,
      nextStatus: routeTo,
      nonce: Date.now()
    }, { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    var button = event.target.closest("#publish_plan");
    if (!button || !window.Shiny) return;
    event.preventDefault();
    if (!window.confirm("Publish this plan and promote the approved payload into the database?")) return;
    window.Shiny.setInputValue("publish_plan_request", {
      planId: Number(button.getAttribute("data-plan-id")),
      nonce: Date.now()
    }, { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    var button = event.target.closest("[data-plan-stamp-stage]");
    if (!button || !window.Shiny) return;
    event.preventDefault();
    var stage = button.getAttribute("data-plan-stamp-stage");
    var action = button.getAttribute("data-plan-stamp-action") || "add";
    var label = button.textContent.trim();
    if (!window.confirm(label + "? This will record your user account.")) return;
    window.Shiny.setInputValue("plan_approval_stamp_request", {
      planId: Number(button.getAttribute("data-plan-id")),
      stage: stage,
      action: action,
      nonce: Date.now()
    }, { priority: "event" });
  });

  document.addEventListener("click", function (event) {
    if (!event.target.closest("#request_measure_deactivate")) return;
    var dialog = document.getElementById("deactivate_measure_dialog");
    if (dialog && dialog.showModal) dialog.showModal();
  });

  document.addEventListener("click", function (event) {
    if (!event.target.closest("#cancel_measure_deactivate")) return;
    var dialog = document.getElementById("deactivate_measure_dialog");
    if (dialog && dialog.open) dialog.close();
  });

  document.addEventListener("click", function (event) {
    if (!event.target.closest("#request_measure_revert_to_draft")) return;
    var dialog = document.getElementById("revert_measure_to_draft_dialog");
    if (dialog && dialog.showModal) dialog.showModal();
  });

  document.addEventListener("click", function (event) {
    if (!event.target.closest("#cancel_measure_revert_to_draft")) return;
    var dialog = document.getElementById("revert_measure_to_draft_dialog");
    if (dialog && dialog.open) dialog.close();
  });

  function measureValueInputs() {
    return Array.from(document.querySelectorAll(".measure-value-input"));
  }

  function normalizeMeasureNumberInput(input, format) {
    if (!input || input.value === "") return;
    var value = input.value;
    if (format === "Percent") {
      // Percent allows up to 2 decimal places now, same as Currency/Count
      // (2026-08-04) -- it no longer force-rounds to a whole number, and
      // it no longer silently rewrites a fraction like "0.75" into "75".
      // Silently rewriting it fought the whole point of loosening this:
      // the app should warn that a value looks like an unconverted
      // fraction and let the person decide, not guess and rewrite their
      // input without asking (see checkMeasureFractionWarning() below).
      var raw = value.replace(/[^\d.]/g, "");
      var percent = Number(raw);
      if (Number.isNaN(percent)) {
        input.value = "";
        return;
      }
      input.value = String(Math.max(0, Math.min(100, Math.round(percent * 100) / 100)));
      return;
    }
    value = value.replace(/[^\d.-]/g, "");
    var decimalIndex = value.indexOf(".");
    if (decimalIndex !== -1) {
      value = value.slice(0, decimalIndex + 1) + value.slice(decimalIndex + 1).replace(/\./g, "").slice(0, 2);
    }
    input.value = value;
  }

  // Louder than the corner save notification on purpose (Melanie
  // 2026-08-04: that toast wasn't noticeable enough for this audience) --
  // an inline banner directly under the specific field the person is
  // looking at, updated on every keystroke so it's visible before they
  // even click away, not just after a round-trip to the server.
  function checkMeasureFractionWarning(input) {
    var wrapper = input.closest(".measure-number-field");
    var warning = wrapper && wrapper.querySelector(".measure-fraction-warning");
    if (!warning) return;
    var percent = Number(input.value);
    var suspicious = input.value !== "" && !Number.isNaN(percent) && percent > 0 && percent < 1;
    warning.classList.toggle("measure-fraction-warning-hidden", !suspicious);
    if (suspicious) {
      warning.querySelector("span").textContent =
        "That's " + input.value + "%. If you meant " + Math.round(percent * 100) + "%, enter " + Math.round(percent * 100) + " instead of " + input.value + ".";
    }
  }

  function updateMeasureNumberFormat() {
    var formatSelect = document.getElementById("measure_format");
    if (!formatSelect) return;
    var format = formatSelect.value || "Count";
    var className = format === "Percent" ? "format-percent" : format === "Currency" ? "format-currency" : "format-count";
    measureValueInputs().forEach(function (input) {
      var wrapper = input.closest(".measure-number-field");
      if (wrapper) {
        wrapper.classList.remove("format-percent", "format-currency", "format-count");
        wrapper.classList.add(className);
      }
      if (format === "Percent") {
        input.min = "0";
        input.max = "100";
      } else {
        input.removeAttribute("min");
        input.removeAttribute("max");
      }
      input.step = "0.01";
      normalizeMeasureNumberInput(input, format);
      if (format === "Percent") checkMeasureFractionWarning(input);
    });
  }

  document.addEventListener("change", function (event) {
    if (event.target && event.target.id === "measure_format") updateMeasureNumberFormat();
    if (event.target && event.target.matches(".measure-value-input")) {
      var formatSelect = document.getElementById("measure_format");
      var format = formatSelect ? formatSelect.value : "Count";
      normalizeMeasureNumberInput(event.target, format);
      if (format === "Percent") checkMeasureFractionWarning(event.target);
    }
    if (event.target && event.target.id && event.target.id.indexOf("review_score__") === 0) {
      var reviewContainer = event.target.closest(".history-modal-panel");
      updateReviewProgress(reviewContainer);
      schedulePlanReviewAutosave(reviewContainer);
    }
  });

  document.addEventListener("input", function (event) {
    if (!event.target) return;
    if (event.target.matches("textarea[id^='review_notes__'], #plan_review_internal_notes")) {
      schedulePlanReviewAutosave(event.target.closest(".history-modal-panel"));
      return;
    }
    if (!event.target.matches(".measure-value-input")) return;
    var formatSelect = document.getElementById("measure_format");
    var format = formatSelect ? formatSelect.value : "Count";
    if (format === "Percent") {
      // Only the warning banner updates on every keystroke; the value
      // itself still only normalizes on blur (see normalizeMeasureNumberInput)
      // so mid-typing a decimal like "0.75" never gets mangled.
      checkMeasureFractionWarning(event.target);
      return;
    }
    normalizeMeasureNumberInput(event.target, format);
  });

  function updateKpiPreview(control) {
    var picker = control.closest(".kpi-picker");
    if (!picker) return;
    var selectedValues = Array.from(picker.querySelectorAll(".kpi-select-row select")).map(function (select) {
      return select.value;
    }).filter(function (value) {
      return value !== "";
    });
    picker.querySelectorAll(".kpi-measure-preview").forEach(function (preview) {
      preview.classList.toggle("active", selectedValues.indexOf(preview.getAttribute("data-measure-id")) !== -1);
    });
  }

  function updateReviewProgress(modal) {
    if (!modal) return;
    var expectedSource = modal.querySelector("[data-expected-review-items]");
    var expected = expectedSource ? Number(expectedSource.getAttribute("data-expected-review-items")) : 0;
    var scored = Array.from(modal.querySelectorAll("select[id^='review_score__']")).filter(function (select) {
      return select.value !== "";
    }).length;
    modal.querySelectorAll(".review-progress-value").forEach(function (target) {
      target.textContent = scored + " of " + expected + (target.closest(".review-save-bar") ? " scored" : "");
    });
  }

  function addMeasureBlockedMessage(reason, isService) {
    if (reason === "cap") return isService ? "Maximum 5 metrics per service." : "Maximum 5 KPIs per goal.";
    if (reason === "empty") return isService ? "Select the current metric before adding another." : "Select the current KPI before adding another.";
    if (reason === "unavailable") return "No additional unique measures are available.";
    return "";
  }

  function setAddMeasureMessage(button, reason, isService) {
    if (!button) return;
    var container = button.parentElement;
    if (!container) return;
    var message = container.querySelector(".kpi-add-message");
    if (!message) {
      message = document.createElement("span");
      message.className = "kpi-add-message";
      container.appendChild(message);
    }
    message.textContent = addMeasureBlockedMessage(reason, isService);
    message.hidden = !reason;
  }

  function updateAllKpiAvailability(page) {
    if (!page) return;
    page.querySelectorAll(".kpi-picker").forEach(function (picker) {
      var selectors = Array.from(picker.querySelectorAll(".kpi-select-row select"));
      if (selectors.length === 0) return;
      updateKpiPreview(selectors[0]);
      var container = picker.querySelector(".kpi-selectors");
      var isService = Boolean(container && container.getAttribute("data-service-id"));
      var outsideValues = new Set();
      if (isService) {
        page.querySelectorAll(".service-editor").forEach(function (editor) {
          if (editor.contains(picker)) return;
          selectedMetricsFromEditor(editor).forEach(function (value) { outsideValues.add(value); });
        });
      }
      selectors.forEach(function (select) {
        var pickerValues = selectors.map(function (innerSelect) { return innerSelect.value; }).filter(function (value) {
          return value !== "";
        });
        Array.from(select.options).forEach(function (option) {
          if (option.value === "" || option.value === select.value) {
            option.disabled = false;
            return;
          }
          option.disabled = pickerValues.indexOf(option.value) !== -1 || outsideValues.has(option.value);
        });
      });
      var optionValues = Array.from(selectors[0].options).map(function (option) { return option.value; }).filter(function (value) { return value !== ""; });
      var unavailableOptionCount = optionValues.filter(function (value) { return outsideValues.has(value); }).length;
      var measureCount = optionValues.length;
      var availableCount = measureCount - unavailableOptionCount;
      var addButton = picker.querySelector(".add-kpi-button");
      if (addButton) {
        var disabledReason = "";
        var selectedCount = selectors.filter(function (select) { return select.value !== ""; }).length;
        if (selectedCount >= MAX_MEASURES_PER_BLOCK) {
          disabledReason = "cap";
        } else if (selectors.some(function (select) { return select.value === ""; })) {
          disabledReason = "empty";
        } else if (selectedCount >= availableCount) {
          disabledReason = "unavailable";
        }
        addButton.disabled = false;
        addButton.dataset.disabledReason = disabledReason;
        addButton.setAttribute("aria-disabled", disabledReason ? "true" : "false");
        addButton.classList.toggle("is-disabled", Boolean(disabledReason));
        setAddMeasureMessage(addButton, disabledReason, isService);
      }
    });
    if (page.matches(".services-page")) {
      page.querySelectorAll(".service-editor").forEach(function (editor) {
        var selects = Array.from(editor.querySelectorAll(".kpi-select-row select"));
        var count = selects.length
          ? selects.filter(function (select) { return select.value !== ""; }).length
          : selectedMetricsFromEditor(editor).length;
        var chip = editor.querySelector(".service-metric-count");
        if (chip) chip.textContent = count + " " + (count === 1 ? "Metric" : "Metrics");
      });
    }
  }

  document.addEventListener("change", function (event) {
    if (!event.target.matches(".kpi-select-row select")) return;
    updateKpiPreview(event.target);
    updateServiceEditorMetricMetadata(event.target.closest(".service-editor"));
    rememberServiceMetricUiState(event.target.closest(".service-editor"));
    updateAllKpiAvailability(event.target.closest(".goals-page, .services-page"));
  });

  function refreshMetricAvailabilityForSelect(select) {
    if (!select || !select.matches || !select.matches(".kpi-select-row select")) return;
    var page = select.closest(".services-page, .goals-page");
    if (!page) return;
    var editor = select.closest(".service-editor");
    if (editor) updateServiceEditorMetricMetadata(editor);
    updateAllKpiAvailability(page);
  }

  document.addEventListener("pointerdown", function (event) {
    refreshMetricAvailabilityForSelect(event.target);
  }, true);

  document.addEventListener("focusin", function (event) {
    refreshMetricAvailabilityForSelect(event.target);
  });

  function addKpiSelector(picker, value, options) {
    options = options || {};
    var container = picker.querySelector(".kpi-selectors");
    var sourceRow = container && container.querySelector(".kpi-select-row");
    if (!container || !sourceRow) return null;
    var selectedCount = Array.from(container.querySelectorAll(".kpi-select-row select")).filter(function (select) { return select.value !== ""; }).length;
    if (selectedCount >= MAX_MEASURES_PER_BLOCK) {
      if (window.Shiny) {
        window.Shiny.setInputValue("measure_cap_error", {
          message: container.getAttribute("data-service-id") ? "A service can have no more than 5 metrics." : "A goal can have no more than 5 KPIs.",
          nonce: Date.now()
        }, { priority: "event" });
      }
      return null;
    }
    var row = sourceRow.cloneNode(true);
    var select = row.querySelector("select");
    var existingIndexes = Array.from(container.querySelectorAll(".kpi-select-row select")).map(function (existingSelect) {
      return Number(existingSelect.id.split("_").pop()) || 0;
    });
    var nextIndex = Math.max.apply(Math, existingIndexes) + 1;
    select.classList.remove("shiny-bound-input");
    var goalId = container.getAttribute("data-goal-id");
    var serviceId = container.getAttribute("data-service-id");
    select.id = goalId ? "goal_kpi_" + goalId + "_" + nextIndex : "service_metric_" + serviceId + "_" + nextIndex;
    select.name = select.id;
    select.value = value || "";
    var removeButton = row.querySelector(".kpi-remove-button");
    if (!removeButton) {
      removeButton = document.createElement("button");
      removeButton.type = "button";
      removeButton.className = "kpi-remove-button";
      var removeLabel = goalId ? "Remove KPI" : "Remove metric";
      removeButton.title = removeLabel;
      removeButton.setAttribute("aria-label", removeLabel);
      removeButton.textContent = "\u00d7";
      row.appendChild(removeButton);
    }
    container.appendChild(row);
    normalizeKpiSelectorRows(picker);
    updateAllKpiAvailability(picker.closest(".goals-page, .services-page"));
    if (!options.skipRemember && serviceId) rememberServiceMetricUiState(container.closest(".service-editor"));
    return select;
  }

  function unbindDraftOnlyControls(root) {
    if (!root || !window.Shiny || !window.Shiny.unbindAll) return;
    root.querySelectorAll(".goals-page .kpi-picker, .goals-page .initiative-picker, .services-page .kpi-picker").forEach(function (picker) {
      if (picker.dataset.draftOnlyUnbound === "true") return;
      window.Shiny.unbindAll(picker);
      picker.dataset.draftOnlyUnbound = "true";
    });
  }

  document.addEventListener("click", function (event) {
    var addButton = event.target.closest(".add-kpi-button");
    if (!addButton) return;
    var page = addButton.closest(".goals-page, .services-page");
    var picker = addButton.closest(".kpi-picker");
    var container = picker && picker.querySelector(".kpi-selectors");
    var isService = container && container.getAttribute("data-service-id");
    var reason = addButton.dataset.disabledReason || "";
    if (reason) {
      var message = reason === "cap"
        ? (isService ? "A service can have no more than 5 metrics." : "A goal can have no more than 5 KPIs.")
        : reason === "empty"
          ? (isService ? "Select the current metric before adding another metric." : "Select the current KPI before adding another KPI.")
          : "No additional unique measures are available for this selection.";
      if (window.Shiny) {
        window.Shiny.setInputValue("measure_cap_error", { message: message, nonce: Date.now() }, { priority: "event" });
      }
      return;
    }
    addKpiSelector(picker, "");
    updateServiceEditorMetricMetadata(addButton.closest(".service-editor"));
    rememberServiceMetricUiState(addButton.closest(".service-editor"));
    if (page && page.matches(".goals-page")) updateGoalRequirements(page);
    if (page && page.matches(".services-page")) {
      setGoalsSaveStatus("Not saved yet");
    } else if (page && page.matches(".goals-page")) {
      setGoalsSaveStatus("Not saved yet");
    } else {
      scheduleBuilderAutosave(page && page.closest(".builder-page-content"), 500);
    }
  });

  document.addEventListener("click", function (event) {
    var removeButton = event.target.closest(".kpi-remove-button");
    if (!removeButton) return;
    var picker = removeButton.closest(".kpi-picker");
    var row = removeButton.closest(".kpi-select-row");
    var serviceEditor = removeButton.closest(".service-editor");
    var page = picker.closest(".goals-page, .services-page");
    if (page && page.matches(".services-page") && picker.querySelectorAll(".kpi-select-row").length === 1) {
      var onlySelect = row && row.querySelector("select");
      if (onlySelect) {
        onlySelect.value = "";
        updateKpiPreview(onlySelect);
      }
      normalizeKpiSelectorRows(picker);
      updateServiceEditorMetricMetadata(serviceEditor);
      rememberServiceMetricUiState(serviceEditor);
      updateAllKpiAvailability(page);
      scheduleServiceMetricsAutosave(page.closest(".builder-page-content"), serviceEditor, 1600);
      return;
    }
    row.remove();
    normalizeKpiSelectorRows(picker);
    updateServiceEditorMetricMetadata(serviceEditor);
    rememberServiceMetricUiState(serviceEditor);
    updateAllKpiAvailability(page);
    if (page && page.matches(".goals-page")) updateGoalRequirements(page);
    if (page && page.matches(".services-page")) {
      scheduleServiceMetricsAutosave(page.closest(".builder-page-content"), serviceEditor, 1600);
    } else if (page && page.matches(".goals-page")) {
      scheduleGoalsQuietAutosave(page.closest(".builder-page-content"), 1600);
    } else {
      scheduleBuilderAutosave(page && page.closest(".builder-page-content"), 500);
    }
  });

  function addInitiativeInput(picker, value) {
    var container = picker && picker.querySelector(".initiative-inputs");
    var sourceRow = container && container.querySelector(".initiative-input-row");
    if (!container || !sourceRow) return null;
    var goalId = container.getAttribute("data-goal-id");
    var baseId = "goal_initiative_" + goalId;
    var existingIndexes = Array.from(container.querySelectorAll("textarea")).map(function (textarea) {
      if (textarea.id === baseId) return 1;
      return Number(textarea.id.slice(baseId.length + 1)) || 1;
    });
    var nextIndex = Math.max.apply(Math, existingIndexes) + 1;
    var row = sourceRow.cloneNode(true);
    var textarea = row.querySelector("textarea");
    textarea.classList.remove("shiny-bound-input");
    textarea.id = baseId + "_" + nextIndex;
    textarea.name = textarea.id;
    textarea.value = value || "";
    var removeButton = row.querySelector(".initiative-remove-button");
    if (!removeButton) {
      removeButton = document.createElement("button");
      removeButton.type = "button";
      removeButton.className = "initiative-remove-button";
      removeButton.title = "Remove initiative";
      removeButton.setAttribute("aria-label", "Remove initiative");
      removeButton.textContent = "\u00d7";
      row.appendChild(removeButton);
    }
    container.appendChild(row);
    return textarea;
  }

  document.addEventListener("click", function (event) {
    var addButton = event.target.closest(".add-initiative-button");
    if (!addButton) return;
    var page = addButton.closest(".goals-page");
    addInitiativeInput(addButton.closest(".initiative-picker"), "");
    updateGoalRequirements(page);
    setGoalsSaveStatus("Not saved yet");
  });

  document.addEventListener("click", function (event) {
    var removeButton = event.target.closest(".initiative-remove-button");
    if (!removeButton) return;
    var row = removeButton.closest(".initiative-input-row");
    row.remove();
    updateGoalRequirements(removeButton.closest(".goals-page"));
    scheduleGoalsQuietAutosave(removeButton.closest(".builder-page-content"), 300);
  });

  function updateScrollProxy(proxy) {
    var target = document.getElementById(proxy.getAttribute("data-scroll-target"));
    var spacer = proxy.firstElementChild;
    if (!target || !spacer) return;
    spacer.style.width = target.scrollWidth + "px";
    if (proxy.dataset.bound === "true") return;
    proxy.dataset.bound = "true";
    var syncing = false;
    proxy.addEventListener("scroll", function () {
      if (syncing) return;
      syncing = true;
      target.scrollLeft = proxy.scrollLeft;
      syncing = false;
    });
    target.addEventListener("scroll", function () {
      if (syncing) return;
      syncing = true;
      proxy.scrollLeft = target.scrollLeft;
      syncing = false;
    });
  }

  function initializeScrollProxies() {
    document.querySelectorAll(".rubric-scroll-top").forEach(updateScrollProxy);
  }

  function goalsDraftKey(page) {
    return "cob-performance:goals-draft:v1:" + page.getAttribute("data-agency-id") + ":" + page.getAttribute("data-plan-id");
  }

  function recoveryGoalsDraftForPlan(planId) {
    var suffix = ":" + String(planId);
    try {
      for (var index = 0; index < window.localStorage.length; index += 1) {
        var key = window.localStorage.key(index);
        if (key && key.indexOf("cob-performance:goals-draft:v1:") === 0 && key.slice(-suffix.length) === suffix) {
          return window.localStorage.getItem(key);
        }
      }
    } catch (error) {
      return "";
    }
    return "";
  }

  function setGoalsSaveStatus(message) {
    var status = document.getElementById("plan_save_status");
    if (status) status.textContent = message;
  }

  function lockPageHeightForAutosave() {
    var page = document.getElementById("page");
    if (!page) return;
    var height = Math.max(page.offsetHeight || 0, page.scrollHeight || 0);
    if (height > 0) page.style.setProperty("--autosave-page-min-height", height + "px");
  }

  function unlockPageHeightAfterAutosave() {
    if (draftSaveQueue.length || activeDraftSave) return;
    window.setTimeout(function () {
      if (draftSaveQueue.length || activeDraftSave) return;
      var page = document.getElementById("page");
      if (page) page.style.removeProperty("--autosave-page-min-height");
    }, 250);
  }

  function enqueueDraftSave(inputName, payload) {
    if (!window.Shiny || !window.Shiny.setInputValue || !inputName || !payload) return false;
    if (inputName === "service_metrics_draft_save" && payload.planId != null && payload.serviceId != null) {
      draftSaveQueue = draftSaveQueue.filter(function (item) {
        return !(
          item.inputName === inputName &&
          item.payload &&
          String(item.payload.planId) === String(payload.planId) &&
          String(item.payload.serviceId) === String(payload.serviceId)
        );
      });
    }
    if (inputName === "goals_draft_quiet_save" && payload.planId != null) {
      draftSaveQueue = draftSaveQueue.filter(function (item) {
        return !(
          item.inputName === inputName &&
          item.payload &&
          String(item.payload.planId) === String(payload.planId)
        );
      });
    }
    if (inputName === "services_draft_quiet_save" && payload.planId != null) {
      draftSaveQueue = draftSaveQueue.filter(function (item) {
        return !(
          item.inputName === inputName &&
          item.payload &&
          String(item.payload.planId) === String(payload.planId)
        );
      });
    }
    draftSaveQueue.push({ inputName: inputName, payload: payload });
    processDraftSaveQueue();
    return true;
  }

  function processDraftSaveQueue() {
    if (activeDraftSave || !draftSaveQueue.length || !window.Shiny || !window.Shiny.setInputValue) return;
    activeDraftSave = draftSaveQueue.shift();
    lockPageHeightForAutosave();
    document.body.classList.add("builder-autosave-active");
    if (activeDraftSaveTimer) window.clearTimeout(activeDraftSaveTimer);
    activeDraftSaveTimer = window.setTimeout(function () {
      if (!activeDraftSave) return;
      setGoalsSaveStatus("Still saving. Your browser recovery copy is available if this takes too long.");
      completeDraftSaveQueue();
    }, 12000);
    window.Shiny.setInputValue(activeDraftSave.inputName, activeDraftSave.payload, { priority: "event" });
  }

  function completeDraftSaveQueue() {
    if (activeDraftSaveTimer) {
      window.clearTimeout(activeDraftSaveTimer);
      activeDraftSaveTimer = null;
    }
    activeDraftSave = null;
    if (!draftSaveQueue.length) {
      document.body.classList.remove("builder-autosave-active");
      unlockPageHeightAfterAutosave();
    }
    processDraftSaveQueue();
  }

  function currentBuilderPage() {
    return document.querySelector(".builder-page-content[data-plan-locked='false']");
  }

  function saveBuilderDraft(page, reason, options) {
    options = options || {};
    var builderPage = page || currentBuilderPage();
    var goalsPage = builderPage && builderPage.querySelector(".goals-page");
    if (!builderPage || !builderPage.isConnected || builderPage.dataset.restoringDraft === "true" || (goalsPage && goalsPage.dataset.restoringDraft === "true")) return false;
    if (options.onlyIfDirty && builderPage.dataset.autosaveDirty !== "true") return false;
    if (autosaveTimer) {
      window.clearTimeout(autosaveTimer);
      autosaveTimer = null;
    }
    var draft = goalsPage ? collectGoalsDraft(goalsPage) : collectBuilderDraft(builderPage);
    window.localStorage.setItem(goalsPage ? goalsDraftKey(goalsPage) : builderDraftKey(builderPage), JSON.stringify(draft));
    if (goalsPage) {
      updateGoalSummaries(goalsPage);
      updateGoalRequirements(goalsPage);
    }
    builderPage.dataset.autosaveDirty = "false";
    setGoalsSaveStatus(reason === "manual" ? "Saving shared draft..." : "Saving...");
    if (window.Shiny && window.Shiny.setInputValue) {
      var savePayload = {
        planId: Number(builderPage.getAttribute("data-plan-id")),
        sectionKey: builderPage.getAttribute("data-section-key"),
        revision: Number(builderPage.dataset.draftRevision || 0),
        payloadJson: JSON.stringify(draft),
        nonce: Date.now()
      };
      builderPage.dataset.pendingAutosaveNonce = String(savePayload.nonce);
      window.setTimeout(function () {
        if (builderPage.isConnected && builderPage.dataset.pendingAutosaveNonce === String(savePayload.nonce)) {
          setGoalsSaveStatus("Still saving. Your browser recovery copy is available if this takes too long.");
        }
      }, 8000);
      window.Shiny.setInputValue("shared_draft_save", savePayload, { priority: "event" });
      return true;
    } else {
      setGoalsSaveStatus("The server is unavailable. Your browser recovery copy is still available.");
      return false;
    }
  }

  function scheduleBuilderAutosave(page, delay) {
    var builderPage = page || currentBuilderPage();
    var goalsPage = builderPage && builderPage.querySelector(".goals-page");
    if (!builderPage || !builderPage.isConnected || builderPage.dataset.restoringDraft === "true" || (goalsPage && goalsPage.dataset.restoringDraft === "true")) return;
    builderPage.dataset.autosaveDirty = "true";
    setGoalsSaveStatus("Unsaved changes. Saving soon...");
    var draft = goalsPage ? collectGoalsDraft(goalsPage) : collectBuilderDraft(builderPage);
    window.localStorage.setItem(goalsPage ? goalsDraftKey(goalsPage) : builderDraftKey(builderPage), JSON.stringify(draft));
    if (autosaveTimer) window.clearTimeout(autosaveTimer);
    autosaveTimer = window.setTimeout(function () {
      saveBuilderDraft(builderPage, "auto", { onlyIfDirty: true });
    }, delay || 1800);
  }

  function scheduleServiceDescriptionAutosave(page, input, delay) {
    if (!page || !input || !input.id) return;
    var match = input.id.match(/^service_description_(.+)$/);
    if (!match) return;
    scheduleServicesQuietAutosave(page, delay || 1100);
  }

  function flushServiceDescriptionAutosave() {
    if (serviceDescriptionAutosaveTimer) {
      window.clearTimeout(serviceDescriptionAutosaveTimer);
      serviceDescriptionAutosaveTimer = null;
    }
    if (!pendingServiceDescriptionSave || !window.Shiny || !window.Shiny.setInputValue) return false;
    var payload = Object.assign({}, pendingServiceDescriptionSave, { nonce: Date.now() });
    pendingServiceDescriptionSave = null;
    setGoalsSaveStatus("Saving...");
    return enqueueDraftSave("service_description_draft_save", payload);
  }

  function scheduleServiceMetricsAutosave(page, editor, delay) {
    if (!page || !editor) return;
    var serviceId = editor.getAttribute("data-service-id") || "";
    if (!serviceId) return;
    updateServiceEditorMetricMetadata(editor);
    rememberServiceMetricUiState(editor);
    scheduleServicesQuietAutosave(page, delay || 700);
  }

  function scheduleServicesQuietAutosave(page, delay) {
    if (!page || !page.isConnected || page.dataset.restoringDraft === "true") return;
    page.dataset.autosaveDirty = "true";
    page.querySelectorAll(".service-editor").forEach(updateServiceEditorMetricMetadata);
    setGoalsSaveStatus("Unsaved changes. Saving soon...");
    var draft = collectBuilderDraft(page);
    window.localStorage.setItem(builderDraftKey(page), JSON.stringify(draft));
    pendingServicesQuietSave = {
      planId: Number(page.getAttribute("data-plan-id")),
      sectionKey: page.getAttribute("data-section-key"),
      payloadJson: JSON.stringify(draft)
    };
    if (servicesQuietAutosaveTimer) window.clearTimeout(servicesQuietAutosaveTimer);
    servicesQuietAutosaveTimer = window.setTimeout(function () {
      flushServicesQuietAutosave();
    }, delay || 1100);
  }

  function flushServicesQuietAutosave() {
    if (servicesQuietAutosaveTimer) {
      window.clearTimeout(servicesQuietAutosaveTimer);
      servicesQuietAutosaveTimer = null;
    }
    if (!pendingServicesQuietSave || !window.Shiny || !window.Shiny.setInputValue) return false;
    var page = document.querySelector(".builder-page-content[data-section-key='services']");
    if (page) {
      page.querySelectorAll(".service-editor").forEach(updateServiceEditorMetricMetadata);
      var draft = collectBuilderDraft(page);
      window.localStorage.setItem(builderDraftKey(page), JSON.stringify(draft));
      pendingServicesQuietSave.payloadJson = JSON.stringify(draft);
    }
    var payload = Object.assign({}, pendingServicesQuietSave, { nonce: Date.now() });
    pendingServicesQuietSave = null;
    setGoalsSaveStatus("Saving...");
    return enqueueDraftSave("services_draft_quiet_save", payload);
  }

  function flushServiceMetricsAutosave() {
    if (serviceMetricsAutosaveTimer) {
      window.clearTimeout(serviceMetricsAutosaveTimer);
      serviceMetricsAutosaveTimer = null;
    }
    if (!pendingServiceMetricsSave || !window.Shiny || !window.Shiny.setInputValue) return false;
    var page = document.querySelector(".builder-page-content[data-section-key='services']");
    var serviceId = String(pendingServiceMetricsSave.serviceId || "");
    var editor = pendingServiceMetricsSave.editorRef;
    if (!editor || !editor.isConnected || editor.getAttribute("data-service-id") !== serviceId) {
      editor = findServiceEditor(page, serviceId);
    }
    if (editor) {
      updateServiceEditorMetricMetadata(editor);
      rememberServiceMetricUiState(editor, false);
      var metricIds = serviceMetricRowValues(editor, false);
      pendingServiceMetricsSave.metricIds = metricIds.length ? metricIds : [""];
      pendingServiceMetricsSave.cleared = metricIds.length === 0;
      pendingServiceMetricsSave.uiVersion = currentServiceMetricUiVersion(editor);
    }
    var payload = Object.assign({}, pendingServiceMetricsSave, { nonce: Date.now() });
    delete payload.editorRef;
    pendingServiceMetricsSave = null;
    setGoalsSaveStatus("Saving...");
    return enqueueDraftSave("service_metrics_draft_save", payload);
  }

  function scheduleGoalsQuietAutosave(page, delay) {
    if (!page || !page.querySelector(".goals-page")) return;
    var goalsPage = page.querySelector(".goals-page");
    if (page.dataset.restoringDraft === "true" || goalsPage.dataset.restoringDraft === "true") return;
    updateGoalRequirements(goalsPage);
    var draft = collectGoalsDraft(goalsPage);
    window.localStorage.setItem(goalsDraftKey(goalsPage), JSON.stringify(draft));
    pendingGoalsQuietSave = {
      planId: Number(page.getAttribute("data-plan-id")),
      sectionKey: "goals",
      payloadJson: JSON.stringify(draft)
    };
    if (goalsQuietAutosaveTimer) window.clearTimeout(goalsQuietAutosaveTimer);
    goalsQuietAutosaveTimer = window.setTimeout(function () {
      flushGoalsQuietAutosave();
    }, delay || 1100);
  }

  function flushGoalsQuietAutosave() {
    if (goalsQuietAutosaveTimer) {
      window.clearTimeout(goalsQuietAutosaveTimer);
      goalsQuietAutosaveTimer = null;
    }
    if (!pendingGoalsQuietSave || !window.Shiny || !window.Shiny.setInputValue) return false;
    var payload = Object.assign({}, pendingGoalsQuietSave, { nonce: Date.now() });
    pendingGoalsQuietSave = null;
    setGoalsSaveStatus("Saving...");
    return enqueueDraftSave("goals_draft_quiet_save", payload);
  }

  function builderDraftKey(page) {
    var title = page.getAttribute("data-builder-title") || "builder";
    var agency = document.querySelector(".header-agency-name");
    return "cob-performance:builder-draft:v1:" + (agency ? agency.textContent.trim() : "agency") + ":" + title;
  }

  function collectBuilderDraft(page) {
    var values = {};
    var serviceMetrics = {};
    page.querySelectorAll("textarea[id], input[id]:not([type='button']):not([type='submit']), select[id]").forEach(function (input) {
      if (input.type === "checkbox") return;
      // Service metric selections are stored canonically in serviceMetrics.
      // Keeping them again in values can replay stale row indexes after a
      // middle metric is removed and the remaining selects are renumbered.
      if (/^service_metric_/.test(input.id || "")) return;
      values[input.id] = input.value;
    });
    page.querySelectorAll(".service-editor[data-service-id]").forEach(function (editor) {
      var serviceId = editor.getAttribute("data-service-id");
      var container = editor.querySelector(".service-metric-selectors");
      if (container) {
        serviceMetrics[serviceId] = Array.from(container.querySelectorAll("select")).map(function (select) {
          return select.value;
        }).filter(function (value) {
          return value !== "";
        });
        editor.setAttribute("data-selected-metrics", serviceMetrics[serviceId].join(","));
      } else {
        serviceMetrics[serviceId] = selectedMetricsFromEditor(editor);
      }
    });
    return { savedAt: new Date().toISOString(), values: values, serviceMetrics: serviceMetrics };
  }

  function restoreBuilderDraft(page, suppliedDraft, sourceLabel) {
    if (page.dataset.builderDraftRestored === "true" || page.querySelector(".goals-page")) return;
    page.dataset.builderDraftRestored = "true";
    var draft = suppliedDraft;
    if (!draft) {
      try {
        draft = JSON.parse(window.localStorage.getItem(builderDraftKey(page)));
      } catch (error) {
        draft = null;
      }
    }
    if (!draft || !draft.values) return;
    page.dataset.restoringDraft = "true";
    if (draft.serviceMetrics) {
      Object.keys(draft.serviceMetrics).forEach(function (serviceId) {
        var container = page.querySelector(".service-metric-selectors[data-service-id='" + serviceId + "']");
        if (!container) return;
        var picker = container.closest(".kpi-picker");
        var savedMetrics = (draft.serviceMetrics[serviceId] || []).filter(function (value) {
          return value !== "";
        });
        while (container.querySelectorAll(".kpi-select-row").length > 1) {
          container.querySelector(".kpi-select-row:last-child").remove();
        }
        var firstSelect = container.querySelector("select");
        if (!firstSelect) return;
        if (savedMetrics.length === 0) {
          firstSelect.value = "";
          updateKpiPreview(firstSelect);
          var editor = container.closest(".service-editor");
          if (editor) editor.setAttribute("data-selected-metrics", "");
          return;
        }
        firstSelect.value = savedMetrics[0] || "";
        savedMetrics.slice(1).forEach(function (value) {
          addKpiSelector(picker, value);
        });
        updateKpiPreview(firstSelect);
      });
    }
    Object.keys(draft.values).forEach(function (id) {
      if (/^service_metric_/.test(id || "")) return;
      var control = document.getElementById(id);
      if (!control) return;
      control.value = draft.values[id];
      control.dispatchEvent(new Event("input", { bubbles: true }));
      control.dispatchEvent(new Event("change", { bubbles: true }));
    });
    delete page.dataset.restoringDraft;
    page.dataset.autosaveDirty = "false";
    setGoalsSaveStatus((sourceLabel || "Recovery draft") + " restored from " + new Date(draft.savedAt).toLocaleString() + ".");
  }

  function collectGoalsDraft(page) {
    var values = {};
    var kpis = {};
    var initiatives = {};
    page.querySelectorAll("textarea[id], select[id]").forEach(function (input) {
      values[input.id] = input.value;
    });
    page.querySelectorAll(".kpi-selectors").forEach(function (container) {
      kpis[container.getAttribute("data-goal-id")] = Array.from(container.querySelectorAll("select")).map(function (select) {
        return select.value;
      }).filter(function (value) {
        return value !== "";
      });
    });
    page.querySelectorAll(".initiative-inputs").forEach(function (container) {
      initiatives[container.getAttribute("data-goal-id")] = Array.from(container.querySelectorAll("textarea")).map(function (textarea) {
        return textarea.value;
      });
    });
    var goalIds = Array.from(page.querySelectorAll(".goal-editor")).map(function (editor) {
      return editor.getAttribute("data-goal-id");
    });
    return { savedAt: new Date().toISOString(), values: values, kpis: kpis, initiatives: initiatives, goalIds: goalIds };
  }

  function setRequirementChip(chip, label, tone) {
    if (!chip) return;
    chip.textContent = label;
    chip.classList.toggle("tone-success", tone === "success");
    chip.classList.toggle("tone-warning", tone === "warning");
    chip.classList.toggle("tone-error", tone === "error");
  }

  function goalMinimumCount(page) {
    var minimumGoals = parseInt(page.getAttribute("data-min-goals") || "3", 10);
    return !Number.isFinite(minimumGoals) || minimumGoals < 1 ? 3 : minimumGoals;
  }

  function updateGoalControls(page) {
    var editors = Array.from(page.querySelectorAll(".goal-editor"));
    var goalCount = editors.length;
    var maximumGoals = parseInt(page.getAttribute("data-max-goals") || "5", 10);
    if (!Number.isFinite(maximumGoals) || maximumGoals < 1) maximumGoals = 5;
    // Any goal can be removed, including the first, as long as the plan's
    // actual minimum (data-min-goals, e.g. 2 for an entity submitter, 3
    // otherwise -- see goal_minimum_count() in app.R) still holds afterward.
    // Previously the first goal specifically could never be removed; that
    // singled-out rule didn't match the real per-plan minimum enforced
    // everywhere else (goal_minimum_count()/goal_maximum_count()), so a
    // plan whose minimum is 1 goal below its current count still couldn't
    // remove goal #1 even though removing any *other* goal was fine.
    var minimumGoals = goalMinimumCount(page);
    var addButton = page.querySelector("#add_goal");
    if (addButton) addButton.disabled = goalCount >= maximumGoals;
    editors.forEach(function (editor, index) {
      var number = editor.querySelector("summary .goal-number");
      var removeButton = editor.querySelector(".remove-goal-button");
      if (number) number.textContent = "Goal " + (index + 1);
      if (removeButton) {
        removeButton.disabled = goalCount <= minimumGoals;
        removeButton.title = goalCount <= minimumGoals
          ? "At least " + minimumGoals + " goal" + (minimumGoals === 1 ? "" : "s") + " must remain while editing"
          : "Remove goal";
      }
    });
  }

  function updateGoalRequirements(page) {
    var editors = Array.from(page.querySelectorAll(".goal-editor"));
    var minimumGoals = parseInt(page.getAttribute("data-min-goals") || "3", 10);
    if (!Number.isFinite(minimumGoals) || minimumGoals < 1) minimumGoals = 3;
    var draftedCount = editors.filter(function (editor) {
      var statement = editor.querySelector("textarea[id^='goal_statement_']");
      var hasStatement = statement && statement.value.trim() !== "";
      var hasInitiative = Array.from(editor.querySelectorAll(".initiative-inputs textarea")).some(function (textarea) {
        return textarea.value.trim() !== "";
      });
      var hasKpi = Array.from(editor.querySelectorAll(".kpi-select-row select")).some(function (select) {
        return select.value !== "";
      });
      return hasStatement && hasInitiative && hasKpi;
    }).length;
    var alignedCount = editors.filter(function (editor) {
      var alignment = editor.querySelector("select[id^='goal_alignment_']");
      return alignment && alignment.value !== "";
    }).length;
    var goalCountLabel = page.querySelector(".draft-goal-count");
    var alignedCountLabel = page.querySelector(".draft-aligned-count");
    var minimumChip = page.querySelector(".goals-drafted-stat .status-chip");
    var alignmentChip = page.querySelector(".pillar-alignment-stat .status-chip");
    if (goalCountLabel) goalCountLabel.textContent = draftedCount;
    if (alignedCountLabel) alignedCountLabel.textContent = alignedCount;
    setRequirementChip(minimumChip, draftedCount >= minimumGoals ? "Minimum met" : (minimumGoals - draftedCount) + " more required", draftedCount >= minimumGoals ? "success" : "error");
    setRequirementChip(alignmentChip, alignedCount >= 1 ? "Minimum met" : "One required", alignedCount >= 1 ? "success" : "error");
    updateGoalControls(page);
  }

  function addGoalEditor(page, requestedId) {
    var list = page.querySelector(".goal-editor-list");
    var source = list && list.querySelector(".goal-editor");
    if (!list || !source) return null;
    var goalId = requestedId || "draft-" + Date.now();
    var editor = source.cloneNode(true);
    editor.setAttribute("data-goal-id", goalId);
    editor.open = true;
    editor.querySelectorAll(".shiny-bound-input").forEach(function (control) {
      control.classList.remove("shiny-bound-input");
    });
    var extraKpis = Array.from(editor.querySelectorAll(".kpi-select-row")).slice(1);
    extraKpis.forEach(function (row) { row.remove(); });
    var extraInitiatives = Array.from(editor.querySelectorAll(".initiative-input-row")).slice(1);
    extraInitiatives.forEach(function (row) { row.remove(); });
    var statement = editor.querySelector("textarea[id^='goal_statement_']");
    var initiative = editor.querySelector("textarea[id^='goal_initiative_']");
    var alignment = editor.querySelector("select[id^='goal_alignment_']");
    var kpi = editor.querySelector(".kpi-select-row select");
    if (statement) {
      statement.id = "goal_statement_" + goalId;
      statement.name = statement.id;
      statement.value = "";
    }
    if (initiative) {
      initiative.id = "goal_initiative_" + goalId;
      initiative.name = initiative.id;
      initiative.value = "";
    }
    if (alignment) {
      alignment.id = "goal_alignment_" + goalId;
      alignment.name = alignment.id;
      alignment.value = "";
    }
    if (kpi) {
      kpi.id = "goal_kpi_" + goalId + "_1";
      kpi.name = kpi.id;
      kpi.value = "";
      Array.from(kpi.options).forEach(function (option) { option.disabled = false; });
    }
    editor.querySelectorAll("textarea, select").forEach(function (control) {
      var label = control.closest(".form-group") && control.closest(".form-group").querySelector("label");
      if (label) label.setAttribute("for", control.id);
    });
    var kpiContainer = editor.querySelector(".kpi-selectors");
    var kpiLabel = editor.querySelector(".kpi-picker > label");
    var goalLabel = editor.querySelector(".goal-statement-field > label");
    var initiativeContainer = editor.querySelector(".initiative-inputs");
    var initiativeLabel = editor.querySelector(".initiative-picker > label");
    if (kpiContainer) kpiContainer.setAttribute("data-goal-id", goalId);
    if (kpiLabel && kpi) kpiLabel.setAttribute("for", kpi.id);
    if (goalLabel && statement) goalLabel.setAttribute("for", statement.id);
    if (initiativeContainer) initiativeContainer.setAttribute("data-goal-id", goalId);
    if (initiativeLabel && initiative) initiativeLabel.setAttribute("for", initiative.id);
    editor.querySelectorAll(".kpi-measure-preview").forEach(function (preview) {
      preview.classList.remove("active");
    });
    var summaryTitle = editor.querySelector("summary strong");
    var summaryChip = editor.querySelector("summary .status-chip");
    var body = editor.querySelector(".goal-editor-body");
    if (summaryTitle) summaryTitle.textContent = "Untitled goal";
    if (summaryChip) {
      summaryChip.textContent = "Not Action Plan Aligned";
      summaryChip.classList.remove("tone-success");
      summaryChip.classList.add("tone-primary");
    }
    if (body) body.setAttribute("aria-hidden", "false");
    list.appendChild(editor);
    if (window.Shiny && window.Shiny.bindAll) window.Shiny.bindAll(editor);
    return editor;
  }

  function restoreGoalEditors(page, goalIds) {
    if (!Array.isArray(goalIds) || goalIds.length < 1) return;
    var wanted = new Set(goalIds.map(String));
    goalIds.forEach(function (goalId) {
      var id = String(goalId);
      var exists = Array.from(page.querySelectorAll(".goal-editor")).some(function (candidate) {
        return candidate.getAttribute("data-goal-id") === id;
      });
      if (!exists) addGoalEditor(page, id);
    });
    page.querySelectorAll(".goal-editor").forEach(function (editor) {
      if (wanted.has(editor.getAttribute("data-goal-id"))) return;
      if (window.Shiny && window.Shiny.unbindAll) window.Shiny.unbindAll(editor);
      editor.remove();
    });
    goalIds.forEach(function (goalId) {
      var id = String(goalId);
      var editor = Array.from(page.querySelectorAll(".goal-editor")).find(function (candidate) {
        return candidate.getAttribute("data-goal-id") === id;
      });
      if (editor) page.querySelector(".goal-editor-list").appendChild(editor);
    });
  }

  function updateGoalSummaries(page) {
    page.querySelectorAll(".goal-editor").forEach(function (editor) {
      var statement = editor.querySelector("textarea[id^='goal_statement_']");
      var summaryTitle = editor.querySelector("summary strong");
      if (statement && summaryTitle) summaryTitle.textContent = statement.value;
      updateGoalAlignmentSummary(editor);
    });
  }

  function updateGoalAlignmentSummary(editor) {
    var alignment = editor && editor.querySelector("select[id^='goal_alignment_']");
    var chip = editor && editor.querySelector("summary .status-chip");
    if (!alignment || !chip) return;
    var aligned = alignment.value !== "";
    chip.textContent = aligned ? "Action Plan Aligned" : "Not Action Plan Aligned";
    chip.classList.toggle("tone-success", aligned);
    chip.classList.toggle("tone-primary", !aligned);
  }

  function restoreGoalsDraft(page, suppliedDraft, sourceLabel) {
    if (page.dataset.draftRestored === "true") return;
    page.dataset.draftRestored = "true";
    var draft = suppliedDraft;
    if (!draft || !draft.values) return;
    page.dataset.restoringDraft = "true";
    restoreGoalEditors(page, draft.goalIds);
    if (draft.initiatives) {
      Object.keys(draft.initiatives).forEach(function (goalId) {
        var container = page.querySelector(".initiative-inputs[data-goal-id='" + goalId + "']");
        if (!container) return;
        var picker = container.closest(".initiative-picker");
        var savedInitiatives = draft.initiatives[goalId];
        while (container.querySelectorAll(".initiative-input-row").length > 1) {
          container.querySelector(".initiative-input-row:last-child").remove();
        }
        var firstTextarea = container.querySelector("textarea");
        firstTextarea.value = savedInitiatives[0] || "";
        savedInitiatives.slice(1).forEach(function (value) {
          addInitiativeInput(picker, value);
        });
      });
    }
    if (draft.kpis) {
      Object.keys(draft.kpis).forEach(function (goalId) {
        var container = page.querySelector(".kpi-selectors[data-goal-id='" + goalId + "']");
        if (!container) return;
        var picker = container.closest(".kpi-picker");
        var savedKpis = draft.kpis[goalId];
        while (container.querySelectorAll(".kpi-select-row").length > 1) {
          container.querySelector(".kpi-select-row:last-child").remove();
        }
        var firstSelect = container.querySelector("select");
        firstSelect.value = savedKpis[0] || "";
        savedKpis.slice(1).forEach(function (value) {
          addKpiSelector(picker, value);
        });
        updateKpiPreview(firstSelect);
      });
    }
    Object.keys(draft.values).forEach(function (id) {
      var control = document.getElementById(id);
      if (!control) return;
      control.value = draft.values[id];
      control.dispatchEvent(new Event("input", { bubbles: true }));
      control.dispatchEvent(new Event("change", { bubbles: true }));
    });
    delete page.dataset.restoringDraft;
    page.dataset.autosaveDirty = "false";
    updateGoalSummaries(page);
    updateGoalRequirements(page);
    setGoalsSaveStatus((sourceLabel || "Recovery draft") + " restored from " + new Date(draft.savedAt).toLocaleString() + ".");
  }

  function draftMatchesPage(message, page) {
    return page && String(message.planId) === page.getAttribute("data-plan-id") && message.sectionKey === page.getAttribute("data-section-key");
  }

  function restoreLocalRecovery(page) {
    var goalsPage = page.querySelector(".goals-page");
    if (goalsPage) restoreGoalsDraft(goalsPage, null, "Unsynced browser recovery");
    else restoreBuilderDraft(page, null, "Unsynced browser recovery");
  }

  function applyLoadedDraft(message) {
    var page = document.querySelector(".builder-page-content");
    if (!draftMatchesPage(message, page)) return;
    page.dataset.draftRevision = String(message.revision || 0);
    if (!message.found || !message.payloadJson) {
      restoreLocalRecovery(page);
      var status = document.getElementById("plan_save_status");
      if (status && status.textContent === "Loading the shared draft...") {
        setGoalsSaveStatus("Autosave ready. Seeded plan data is shown.");
      }
      return;
    }
    var draft;
    try {
      draft = JSON.parse(message.payloadJson);
    } catch (error) {
      setGoalsSaveStatus("The shared draft could not be read. Seeded plan data is shown.");
      return;
    }
    var goalsPage = page.querySelector(".goals-page");
    if (goalsPage) restoreGoalsDraft(goalsPage, draft, "Shared draft");
    else restoreBuilderDraft(page, draft, "Shared draft");
  }

  function handleDraftSaveResult(message) {
    endBackgroundAutosave();
    var page = document.querySelector(".builder-page-content");
    if (!draftMatchesPage(message, page)) return;
    if (message.ok) {
      delete page.dataset.pendingAutosaveNonce;
      page.dataset.draftRevision = String(message.revision);
      page.dataset.autosaveDirty = "false";
      var goalsPage = page.querySelector(".goals-page");
      window.localStorage.removeItem(goalsPage ? goalsDraftKey(goalsPage) : builderDraftKey(page));
      setGoalsSaveStatus("Saved");
      if (pendingNavigationPage) {
        var nextPage = pendingNavigationPage;
        clearPendingNavigation();
        navigateToPage(nextPage);
      }
      return;
    }
    if (message.conflict) {
      delete page.dataset.pendingAutosaveNonce;
      page.dataset.autosaveDirty = "true";
      clearPendingNavigation();
      setGoalsSaveStatus(message.message || "A newer shared draft was saved by someone else. Your browser recovery copy is still available; reload before saving again.");
      return;
    }
    delete page.dataset.pendingAutosaveNonce;
    page.dataset.autosaveDirty = "true";
    clearPendingNavigation();
    setGoalsSaveStatus(message.message || "The shared draft could not be saved. Your browser recovery copy is still available.");
  }

  function handleServiceDescriptionDraftResult(message) {
    endBackgroundAutosave();
    completeDraftSaveQueue();
    var page = document.querySelector(".builder-page-content[data-section-key='services']");
    if (!page) return;
    if (message && message.ok) {
      page.dataset.autosaveDirty = "false";
      if (message.revision != null) page.dataset.draftRevision = String(message.revision);
      window.localStorage.removeItem(builderDraftKey(page));
      setGoalsSaveStatus("Saved");
      return;
    }
    setGoalsSaveStatus((message && message.message) || "The service description could not be saved. Your browser recovery copy is still available.");
  }

  function handleServiceMetricsDraftResult(message) {
    endBackgroundAutosave();
    completeDraftSaveQueue();
    var page = document.querySelector(".builder-page-content[data-section-key='services']");
    if (!page) return;
    if (message && message.ok) {
      page.dataset.autosaveDirty = "false";
      if (message.revision != null) page.dataset.draftRevision = String(message.revision);
      // Keep the currently visible metric editor as the source of truth.
      // Touching selector rows here can replay stale server-rendered order
      // while someone is editing a service drawer.
      window.localStorage.removeItem(builderDraftKey(page));
      setGoalsSaveStatus("Saved");
      return;
    }
    setGoalsSaveStatus((message && message.message) || "The service metrics could not be saved. Your browser recovery copy is still available.");
  }

  function handleServicesDraftResult(message) {
    endBackgroundAutosave();
    completeDraftSaveQueue();
    var page = document.querySelector(".builder-page-content[data-section-key='services']");
    if (!page) return;
    if (message && message.ok) {
      page.dataset.autosaveDirty = "false";
      if (message.revision != null) page.dataset.draftRevision = String(message.revision);
      window.localStorage.removeItem(builderDraftKey(page));
      setGoalsSaveStatus("Saved");
      return;
    }
    page.dataset.autosaveDirty = "true";
    setGoalsSaveStatus((message && message.message) || "The services draft could not be saved. Your browser recovery copy is still available.");
  }

  function handleGoalsDraftResult(message) {
    endBackgroundAutosave();
    completeDraftSaveQueue();
    var page = document.querySelector(".builder-page-content[data-section-key='goals']");
    if (!page) return;
    if (message && message.ok) {
      page.dataset.autosaveDirty = "false";
      if (message.revision != null) page.dataset.draftRevision = String(message.revision);
      var goalsPage = page.querySelector(".goals-page");
      if (goalsPage) {
        updateGoalRequirements(goalsPage);
        updateAllKpiAvailability(goalsPage);
        window.localStorage.removeItem(goalsDraftKey(goalsPage));
      }
      setGoalsSaveStatus("Saved");
      return;
    }
    page.dataset.autosaveDirty = "true";
    setGoalsSaveStatus((message && message.message) || "The goals draft could not be saved. Your browser recovery copy is still available.");
  }

  // Reported 2026-08-05 (DHR): saving a new measure created several
  // duplicate copies -- the Save button gave no feedback that a save was
  // already in flight (app_data() refreshes in the background after the
  // click returns, so "the request was sent" and "the save is done" are
  // not the same moment), so a repeat click re-entered the save before the
  // first one had finished. Disabling the button(s) here on click, and
  // re-enabling only once the server confirms the save has genuinely
  // finished (success, a validation error, or a failed background
  // refresh -- see reenableButtonsForSaveResult()'s callers in app.R),
  // closes that window. Reused for every modal with the same "Save" shape
  // (measures, risks, team roles).
  function disableButtonsForSave(ids, activeId, activeLabel) {
    ids.forEach(function (id) {
      var button = document.getElementById(id);
      if (!button) return;
      if (!button.dataset.originalLabel) button.dataset.originalLabel = button.textContent;
      button.disabled = true;
    });
    var activeButton = activeId && document.getElementById(activeId);
    if (activeButton && activeLabel) activeButton.textContent = activeLabel;
  }

  function reenableButtonsForSaveResult(ids) {
    ids.forEach(function (id) {
      var button = document.getElementById(id);
      if (!button) return;
      button.disabled = false;
      if (button.dataset.originalLabel) {
        button.textContent = button.dataset.originalLabel;
        delete button.dataset.originalLabel;
      }
    });
  }

  function handleMeasureSaveResult(message) {
    reenableButtonsForSaveResult(["save_measure", "submit_measure"]);
  }

  function handleRiskSaveResult(message) {
    reenableButtonsForSaveResult(["save_risk"]);
  }

  function handleTeamRoleSaveResult(message) {
    reenableButtonsForSaveResult(["save_team_role"]);
  }

  function handlePlanReviewSaveResult(message) {
    if (!message || !message.ok) return;
    setReviewSaveStatus("Review autosaved at " + message.savedAt + ". Current score: " + message.score + "/100.");
    // The "Overall score" summary card is server-rendered once and never
    // re-rendered during autosave (see plan_review_save_request's comment
    // in app.R -- a re-render would collapse open scoring drawers), so it
    // needs to be patched here directly or it stays frozen at whatever it
    // showed on page load while the status line above already moved on.
    var overallScore = document.getElementById("review_overall_score_value");
    if (overallScore) overallScore.textContent = message.score + "/100";
  }

  function requestSharedDraft(page) {
    if (!window.Shiny || !window.Shiny.setInputValue) {
      restoreLocalRecovery(page);
      return;
    }
    window.Shiny.setInputValue("shared_draft_load", {
      planId: Number(page.getAttribute("data-plan-id")),
      sectionKey: page.getAttribute("data-section-key"),
      nonce: Date.now()
    }, { priority: "event" });
  }

  function triggerPlanDownload(message) {
    var type = message && message.type === "pptx" ? "pptx" : "pdf";
    var link = document.getElementById(type === "pptx" ? "download_plan_pptx" : "download_plan_pdf");
    if (!link) return;
    var attempts = 0;
    var clickWhenReady = function () {
      attempts += 1;
      var href = link.getAttribute("href") || "";
      if (href && href !== "#" && href !== window.location.pathname && href.indexOf("session/") !== -1) {
        link.click();
        return;
      }
      if (attempts < 20) window.setTimeout(clickWhenReady, 100);
    };
    clickWhenReady();
  }

  function initializeGoalsPage() {
    var page = document.querySelector(".goals-page");
    if (!page || page.dataset.goalsInitialized === "true") return;
    page.dataset.goalsInitialized = "true";
    unbindDraftOnlyControls(page);
    restoreOpenGoalDrawers();
    page.querySelectorAll(".goal-editor").forEach(function (editor) {
      var body = editor.querySelector(".goal-editor-body");
      if (body) body.setAttribute("aria-hidden", editor.open ? "false" : "true");
    });
    page.querySelectorAll(".rubric-section").forEach(function (section) {
      var table = section.querySelector(".rubric-section-table-wrap");
      if (table) table.setAttribute("aria-hidden", section.open ? "false" : "true");
    });
    updateAllKpiAvailability(page);
    updateGoalRequirements(page);
    initializeScrollProxies();
  }

  function initializeBuilderPage() {
    var page = document.querySelector(".builder-page-content");
    if (!page || page.dataset.builderInitialized === "true") return;
    page.dataset.builderInitialized = "true";
    page.dataset.autosaveDirty = "false";
    if (autosaveTimer) {
      window.clearTimeout(autosaveTimer);
      autosaveTimer = null;
    }
    if (page.getAttribute("data-plan-locked") === "true") {
      disableLockedBuilderControls(page);
      return;
    }
    requestSharedDraft(page);
  }

  function initializeServicesPage() {
    var page = document.querySelector(".services-page");
    if (!page || page.dataset.servicesInitialized === "true") return;
    page.dataset.servicesInitialized = "true";
    unbindDraftOnlyControls(page);
    restoreOpenServiceDrawers();
    page.querySelectorAll(".service-editor").forEach(function (editor) {
      var body = editor.querySelector(".service-editor-body");
      if (body) body.setAttribute("aria-hidden", editor.open ? "false" : "true");
      if (editor.open) requestServiceBody(editor);
    });
    updateAllKpiAvailability(page);
  }

  function initializeReadOnlyModals() {
    document.querySelectorAll('[data-can-edit="false"]').forEach(function (modal) {
      if (modal.dataset.readOnlyInitialized === "true") return;
      modal.dataset.readOnlyInitialized = "true";
      modal.querySelectorAll("input, textarea, select, button").forEach(function (control) {
        if (control.id === "close_measure_modal" || control.id === "close_risk_modal" || control.id === "close_team_role_modal") return;
        control.disabled = true;
        control.setAttribute("aria-disabled", "true");
      });
    });
  }

  document.addEventListener("toggle", function (event) {
    if (!event.target.matches) return;
    if (event.target.matches(".goal-editor")) {
      var goalId = event.target.getAttribute("data-goal-id") || "";
      if (goalId) {
        if (event.target.open) openGoalIds.add(goalId);
        else openGoalIds.delete(goalId);
      }
      var body = event.target.querySelector(".goal-editor-body");
      if (body) body.setAttribute("aria-hidden", event.target.open ? "false" : "true");
    }
    if (event.target.matches(".service-editor")) {
      var serviceId = event.target.getAttribute("data-service-id") || "";
      if (serviceId) {
        if (event.target.open) openServiceIds.add(serviceId);
        else openServiceIds.delete(serviceId);
      }
      var serviceBody = event.target.querySelector(".service-editor-body");
      if (serviceBody) serviceBody.setAttribute("aria-hidden", event.target.open ? "false" : "true");
      if (event.target.open) requestServiceBody(event.target);
    }
    if (event.target.matches(".rubric-section")) {
      var table = event.target.querySelector(".rubric-section-table-wrap");
      if (table) table.setAttribute("aria-hidden", event.target.open ? "false" : "true");
    }
  }, true);

  document.addEventListener("shiny:value", function (event) {
    var target = event.target;
    if (!target || !target.id || target.id.indexOf("service_body_") !== 0) return;
    window.setTimeout(function () {
      var page = target.closest(".services-page");
      var editor = target.closest(".service-editor");
      unbindDraftOnlyControls(target);
      applyServiceMetricUiState(editor);
      updateServiceEditorMetricMetadata(editor);
      if (page) updateAllKpiAvailability(page);
      disableLockedBuilderControls(target.closest(".builder-page-content"));
    }, 0);
  });

  document.addEventListener("input", function (event) {
    var page = event.target.closest(".builder-page-content");
    var goalsPage = event.target.closest(".goals-page");
    if (!page || page.dataset.restoringDraft === "true" || (goalsPage && goalsPage.dataset.restoringDraft === "true")) return;
    if (event.target.matches(".kpi-select-row select")) return;
    if (goalsPage && event.target.matches("textarea[id^='goal_statement_'], .initiative-inputs textarea")) {
      updateGoalRequirements(goalsPage);
      scheduleGoalsQuietAutosave(page, 1200);
      return;
    }
    if (event.target.closest(".services-page") && event.target.matches("textarea[id^='service_description_']")) {
      page.dataset.autosaveDirty = "false";
      scheduleServiceDescriptionAutosave(page, event.target, 1200);
      return;
    }
    scheduleBuilderAutosave(page, event.target.closest(".services-page") ? 250 : 900);
  });

  document.addEventListener("change", function (event) {
    var page = event.target.closest(".builder-page-content");
    var goalsPage = event.target.closest(".goals-page");
    if (!page || page.dataset.restoringDraft === "true" || (goalsPage && goalsPage.dataset.restoringDraft === "true")) return;
    if (goalsPage && event.target.matches("select[id^='goal_alignment_']")) {
      updateGoalAlignmentSummary(event.target.closest(".goal-editor"));
      updateGoalRequirements(goalsPage);
      scheduleGoalsQuietAutosave(page, 700);
      return;
    }
    if (goalsPage && event.target.matches(".kpi-select-row select")) {
      updateGoalRequirements(goalsPage);
      updateAllKpiAvailability(goalsPage);
      scheduleGoalsQuietAutosave(page, 1600);
      return;
    }
    if (event.target.closest(".services-page") && event.target.matches(".kpi-select-row select")) {
      scheduleServiceMetricsAutosave(page, event.target.closest(".service-editor"), 1600);
      return;
    }
    scheduleBuilderAutosave(page);
  });

  document.addEventListener("click", function (event) {
    var addButton = event.target.closest("#add_goal");
    if (!addButton) return;
    event.preventDefault();
    var page = addButton.closest(".goals-page") || document.querySelector(".goals-page");
    if (!page) return;
    var maximumGoals = parseInt(page.getAttribute("data-max-goals") || "5", 10);
    if (!Number.isFinite(maximumGoals) || maximumGoals < 1) maximumGoals = 5;
    if (page.querySelectorAll(".goal-editor").length >= maximumGoals) {
      if (window.Shiny) {
        window.Shiny.setInputValue("measure_cap_error", {
          message: "This plan can have no more than " + maximumGoals + " goals.",
          nonce: Date.now()
        }, { priority: "event" });
      }
      updateGoalControls(page);
      return;
    }
    addGoalEditor(page);
    updateAllKpiAvailability(page);
    updateGoalRequirements(page);
    scheduleGoalsQuietAutosave(page.closest(".builder-page-content"), 700);
  });

  document.addEventListener("click", function (event) {
    var removeButton = event.target.closest(".remove-goal-button");
    if (!removeButton) return;
    event.preventDefault();
    var page = removeButton.closest(".goals-page");
    var editor = removeButton.closest(".goal-editor");
    if (!page || !editor || page.querySelectorAll(".goal-editor").length <= goalMinimumCount(page)) return;
    pendingGoalDeletion = { page: page, editor: editor };
    var dialog = document.getElementById("delete_goal_dialog");
    if (dialog && dialog.showModal) dialog.showModal();
  });

  document.addEventListener("click", function (event) {
    if (!event.target.closest("#cancel_goal_delete")) return;
    dismissGoalDeleteDialog();
  });

  document.addEventListener("click", function (event) {
    if (!event.target.closest("#confirm_goal_delete") || !pendingGoalDeletion) return;
    var page = pendingGoalDeletion.page;
    var editor = pendingGoalDeletion.editor;
    dismissGoalDeleteDialog();
    if (!page.isConnected || !editor.isConnected || page.querySelectorAll(".goal-editor").length <= goalMinimumCount(page)) return;
    if (window.Shiny && window.Shiny.unbindAll) window.Shiny.unbindAll(editor);
    editor.remove();
    updateAllKpiAvailability(page);
    updateGoalRequirements(page);
    scheduleGoalsQuietAutosave(page.closest(".builder-page-content"), 700);
  });

  document.addEventListener("click", function (event) {
    var dialog = event.target.closest("#delete_goal_dialog");
    if (dialog && event.target === dialog) dismissGoalDeleteDialog();
  });

  document.addEventListener("cancel", function (event) {
    if (!event.target.matches || !event.target.matches("#delete_goal_dialog")) return;
    pendingGoalDeletion = null;
  }, true);

  document.addEventListener("close", function (event) {
    if (!event.target.matches || !event.target.matches("#delete_goal_dialog")) return;
    pendingGoalDeletion = null;
  }, true);

  document.addEventListener("click", function (event) {
    var saveButton = event.target.closest("#save_plan_draft");
    if (!saveButton) return;
    saveBuilderDraft(document.querySelector(".builder-page-content"), "manual");
  });

  document.addEventListener("click", function (event) {
    var submitButton = event.target.closest("[data-submit-plan]");
    if (!submitButton) return;
    if (!window.confirm("Are you sure you want to submit this plan? Fields will lock while it is in review.")) return;
    flushServicesQuietAutosave();
    flushGoalsQuietAutosave();
    saveBuilderDraft(currentBuilderPage(), "auto", { onlyIfDirty: true });
    if (window.Shiny && window.Shiny.setInputValue) {
      window.Shiny.setInputValue("submit_plan_request", {
        planId: Number(submitButton.getAttribute("data-submit-plan")),
        nonce: Date.now()
      }, { priority: "event" });
    }
  });

  function syncDesktopNavToggles() {
    var collapsed = document.body.classList.contains("desktop-nav-collapsed");
    var expanded = collapsed ? "false" : "true";
    var label = collapsed ? "Expand navigation" : "Collapse navigation";
    ["toggle_desktop_nav", "toggle_desktop_nav_edge"].forEach(function (id) {
      var toggle = document.getElementById(id);
      if (toggle) {
        toggle.setAttribute("aria-expanded", expanded);
        toggle.setAttribute("aria-label", label);
        toggle.setAttribute("title", label);
      }
    });
  }

  document.addEventListener("click", function (event) {
    var toggle = event.target.closest("#toggle_desktop_nav, #toggle_desktop_nav_edge");
    if (!toggle) return;
    document.body.classList.toggle("desktop-nav-collapsed");
    window.localStorage.setItem("cob-performance:desktop-nav-collapsed", document.body.classList.contains("desktop-nav-collapsed") ? "true" : "false");
    syncDesktopNavToggles();
    setTimeout(initializeScrollProxies, 0);
  });

  document.addEventListener("click", function (event) {
    var toggle = event.target.closest("#toggle_mobile_nav");
    if (!toggle) return;
    document.body.classList.toggle("mobile-nav-open");
    toggle.setAttribute("aria-expanded", document.body.classList.contains("mobile-nav-open") ? "true" : "false");
  });

  document.addEventListener("click", function (event) {
    if (!event.target.closest("#close_mobile_nav") && !event.target.closest("[data-close-mobile-nav]")) return;
    closeMobileNav();
  });

  if (window.localStorage.getItem("cob-performance:desktop-nav-collapsed") === "true") {
    document.body.classList.add("desktop-nav-collapsed");
  }
  syncDesktopNavToggles();

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") closeMobileNav();
  });

  var initializationTimer;
  function schedulePageInitialization() {
    window.clearTimeout(initializationTimer);
    initializationTimer = window.setTimeout(function () {
      initializeGoalsPage();
      initializeBuilderPage();
      initializeServicesPage();
      initializeReadOnlyModals();
      updateReviewProgress(document.querySelector(".history-modal-panel"));
      updateMeasureNumberFormat();
      clearReviewerPlanFiltersOnQueueRender(false);
      prefillLoginEmail();
    }, 0);
  }

  var pageRoot = document.getElementById("page");
  if (pageRoot) {
    var pageObserver = new MutationObserver(schedulePageInitialization);
    pageObserver.observe(pageRoot, { childList: true });
  }
  schedulePageInitialization();
  window.addEventListener("resize", initializeScrollProxies);

  document.addEventListener("click", function (event) {
    var backdrop = event.target.closest("[data-close-input]");
    if (!backdrop || event.target !== backdrop || !window.Shiny) return;
    window.Shiny.setInputValue(backdrop.getAttribute("data-close-input"), Date.now(), { priority: "event" });
  });

  document.addEventListener("shiny:connected", function () {
    registerShinyHandlers();
    if (!storedAuthToken()) {
      setActivePage("login");
    }
    scheduleStoredAuthRestore();
    schedulePageInitialization();
  });

  if (window.Shiny) {
    registerShinyHandlers();
  } else {
    document.addEventListener("shiny:connected", function () {
      registerShinyHandlers();
      scheduleStoredAuthRestore();
    });
  }
})();
