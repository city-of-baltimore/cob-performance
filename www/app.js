(function () {
  document.body.classList.add("auth-signed-out");
  var pendingGoalDeletion = null;
  var MAX_MEASURES_PER_BLOCK = 5;
  var reviewerFilterResetKey = "";
  var autosaveTimer = null;
  var serviceDescriptionAutosaveTimer = null;
  var serviceMetricsAutosaveTimer = null;
  var goalsQuietAutosaveTimer = null;
  var reviewAutosaveTimer = null;
  var pendingServiceDescriptionSave = null;
  var pendingServiceMetricsSave = null;
  var pendingGoalsQuietSave = null;
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

  function dismissGoalDeleteDialog() {
    pendingGoalDeletion = null;
    var dialog = document.getElementById("delete_goal_dialog");
    if (dialog && dialog.open) dialog.close();
  }

  function setActivePage(page) {
    var navPage = page === "plan_review_detail" ? "reviewer_dashboard" : page;
    document.querySelectorAll("[data-page]").forEach(function (button) {
      button.classList.toggle("active", button.getAttribute("data-page") === navPage);
    });
  }

  function closeMobileNav() {
    document.body.classList.remove("mobile-nav-open");
    var toggle = document.getElementById("toggle_mobile_nav");
    if (toggle) toggle.setAttribute("aria-expanded", "false");
  }

  function navigateToPage(page) {
    if (page !== "services") openServiceIds.clear();
    setActivePage(page);
    closeMobileNav();
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
      flushServiceDescriptionAutosave();
      flushServiceMetricsAutosave();
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

  function clearAuthSession() {
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
    window.Shiny.addCustomMessageHandler("goals-draft-result", handleGoalsDraftResult);
    window.Shiny.addCustomMessageHandler("plan-review-save-result", handlePlanReviewSaveResult);
    window.Shiny.addCustomMessageHandler("trigger-plan-download", triggerPlanDownload);
    window.Shiny.addCustomMessageHandler("set-navigation-scope", setNavigationScope);
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
    if (!editor || !editor.open || editor.dataset.serviceBodyRequested === "true") return;
    var serviceId = editor.getAttribute("data-service-id") || "";
    if (!serviceId || !window.Shiny) return;
    editor.dataset.serviceBodyRequested = "true";
    window.Shiny.setInputValue("service_lazy_open", {
      serviceId: serviceId,
      nonce: Date.now()
    }, { priority: "event" });
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
    var row = event.target.closest("[data-measure-id]");
    var addButton = event.target.closest("[data-new-measure]");
    if ((!row && !addButton) || !window.Shiny) return;
    if (addButton) {
      sendPage(addButton.getAttribute("data-page") || "metrics");
    }
    window.Shiny.setInputValue("open_measure_id", addButton ? "new" : row.getAttribute("data-measure-id"), { priority: "event" });
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
    if ((!saveButton && !submitButton) || !window.Shiny) return;
    event.preventDefault();
    updateMeasureNumberFormat();
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
    if (!event.target.closest("#save_risk") || !window.Shiny) return;
    event.preventDefault();
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
    if (!event.target.closest("#save_team_role") || !window.Shiny) return;
    event.preventDefault();
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

  function measureValueInputs() {
    return Array.from(document.querySelectorAll(".measure-value-input"));
  }

  function normalizeMeasureNumberInput(input, format) {
    if (!input || input.value === "") return;
    var value = input.value;
    if (format === "Percent") {
      value = value.replace(/[^\d.]/g, "");
      if (value.indexOf(".") !== -1) value = value.slice(0, value.indexOf("."));
      var percent = Number(value);
      if (Number.isNaN(percent)) {
        input.value = "";
        return;
      }
      input.value = String(Math.max(0, Math.min(100, Math.round(percent))));
      return;
    }
    value = value.replace(/[^\d.-]/g, "");
    var decimalIndex = value.indexOf(".");
    if (decimalIndex !== -1) {
      value = value.slice(0, decimalIndex + 1) + value.slice(decimalIndex + 1).replace(/\./g, "").slice(0, 2);
    }
    input.value = value;
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
        input.step = "1";
      } else {
        input.removeAttribute("min");
        input.removeAttribute("max");
        input.step = "0.01";
      }
      normalizeMeasureNumberInput(input, format);
    });
  }

  document.addEventListener("change", function (event) {
    if (event.target && event.target.id === "measure_format") updateMeasureNumberFormat();
    if (event.target && event.target.matches(".measure-value-input")) {
      var formatSelect = document.getElementById("measure_format");
      normalizeMeasureNumberInput(event.target, formatSelect ? formatSelect.value : "Count");
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
    normalizeMeasureNumberInput(event.target, formatSelect ? formatSelect.value : "Count");
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

  function addKpiSelector(picker, value) {
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
    if (window.Shiny && window.Shiny.bindAll) window.Shiny.bindAll(row);
    updateAllKpiAvailability(picker.closest(".goals-page, .services-page"));
    return select;
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
    if (page && page.matches(".goals-page")) updateGoalRequirements(page);
    if (page && page.matches(".services-page")) {
      setGoalsSaveStatus("Select a metric to autosave this service.");
    } else if (page && page.matches(".goals-page")) {
      setGoalsSaveStatus("Select a KPI to autosave this goal.");
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
      updateServiceEditorMetricMetadata(serviceEditor);
      updateAllKpiAvailability(page);
      scheduleServiceMetricsAutosave(page.closest(".builder-page-content"), serviceEditor, 500);
      return;
    }
    if (window.Shiny && window.Shiny.unbindAll) window.Shiny.unbindAll(row);
    row.remove();
    updateServiceEditorMetricMetadata(serviceEditor);
    updateAllKpiAvailability(page);
    if (page && page.matches(".goals-page")) updateGoalRequirements(page);
    if (page && page.matches(".services-page")) {
      scheduleServiceMetricsAutosave(page.closest(".builder-page-content"), serviceEditor, 500);
    } else if (page && page.matches(".goals-page")) {
      scheduleGoalsQuietAutosave(page.closest(".builder-page-content"), 500);
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
    if (window.Shiny && window.Shiny.bindAll) window.Shiny.bindAll(row);
    return textarea;
  }

  document.addEventListener("click", function (event) {
    var addButton = event.target.closest(".add-initiative-button");
    if (!addButton) return;
    var page = addButton.closest(".goals-page");
    addInitiativeInput(addButton.closest(".initiative-picker"), "");
    updateGoalRequirements(page);
    setGoalsSaveStatus("Add initiative text to autosave this goal.");
  });

  document.addEventListener("click", function (event) {
    var removeButton = event.target.closest(".initiative-remove-button");
    if (!removeButton) return;
    var row = removeButton.closest(".initiative-input-row");
    if (window.Shiny && window.Shiny.unbindAll) window.Shiny.unbindAll(row);
    row.remove();
    updateGoalRequirements(removeButton.closest(".goals-page"));
    scheduleGoalsQuietAutosave(removeButton.closest(".builder-page-content"), 500);
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
    setGoalsSaveStatus(reason === "manual" ? "Saving shared draft..." : "Autosaving...");
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
      if (reason !== "manual") beginBackgroundAutosave();
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
    setGoalsSaveStatus("Unsaved changes. Autosaving...");
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
    setGoalsSaveStatus("Unsaved changes. Autosaving...");
    var draft = collectBuilderDraft(page);
    window.localStorage.setItem(builderDraftKey(page), JSON.stringify(draft));
    pendingServiceDescriptionSave = {
      planId: Number(page.getAttribute("data-plan-id")),
      sectionKey: page.getAttribute("data-section-key"),
      serviceId: match[1],
      fieldId: input.id,
      value: input.value
    };
    if (serviceDescriptionAutosaveTimer) window.clearTimeout(serviceDescriptionAutosaveTimer);
    serviceDescriptionAutosaveTimer = window.setTimeout(function () {
      flushServiceDescriptionAutosave();
    }, delay || 500);
  }

  function flushServiceDescriptionAutosave() {
    if (serviceDescriptionAutosaveTimer) {
      window.clearTimeout(serviceDescriptionAutosaveTimer);
      serviceDescriptionAutosaveTimer = null;
    }
    if (!pendingServiceDescriptionSave || !window.Shiny || !window.Shiny.setInputValue) return false;
    var payload = Object.assign({}, pendingServiceDescriptionSave, { nonce: Date.now() });
    pendingServiceDescriptionSave = null;
    setGoalsSaveStatus("Autosaving...");
    beginBackgroundAutosave();
    window.Shiny.setInputValue("service_description_draft_save", payload, { priority: "event" });
    return true;
  }

  function scheduleServiceMetricsAutosave(page, editor, delay) {
    if (!page || !editor) return;
    var serviceId = editor.getAttribute("data-service-id") || "";
    if (!serviceId) return;
    updateServiceEditorMetricMetadata(editor);
    setGoalsSaveStatus("Unsaved changes. Autosaving...");
    var draft = collectBuilderDraft(page);
    window.localStorage.setItem(builderDraftKey(page), JSON.stringify(draft));
    var metricIds = selectedMetricsFromEditor(editor);
    pendingServiceMetricsSave = {
      planId: Number(page.getAttribute("data-plan-id")),
      sectionKey: page.getAttribute("data-section-key"),
      serviceId: serviceId,
      metricIds: metricIds.length ? metricIds : [""],
      cleared: metricIds.length === 0
    };
    if (serviceMetricsAutosaveTimer) window.clearTimeout(serviceMetricsAutosaveTimer);
    serviceMetricsAutosaveTimer = window.setTimeout(function () {
      flushServiceMetricsAutosave();
    }, delay || 500);
  }

  function flushServiceMetricsAutosave() {
    if (serviceMetricsAutosaveTimer) {
      window.clearTimeout(serviceMetricsAutosaveTimer);
      serviceMetricsAutosaveTimer = null;
    }
    if (!pendingServiceMetricsSave || !window.Shiny || !window.Shiny.setInputValue) return false;
    var payload = Object.assign({}, pendingServiceMetricsSave, { nonce: Date.now() });
    pendingServiceMetricsSave = null;
    setGoalsSaveStatus("Autosaving...");
    beginBackgroundAutosave();
    window.Shiny.setInputValue("service_metrics_draft_save", payload, { priority: "event" });
    return true;
  }

  function scheduleGoalsQuietAutosave(page, delay) {
    if (!page || !page.querySelector(".goals-page")) return;
    var goalsPage = page.querySelector(".goals-page");
    if (page.dataset.restoringDraft === "true" || goalsPage.dataset.restoringDraft === "true") return;
    updateGoalRequirements(goalsPage);
    setGoalsSaveStatus("Unsaved changes. Autosaving...");
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
    }, delay || 900);
  }

  function flushGoalsQuietAutosave() {
    if (goalsQuietAutosaveTimer) {
      window.clearTimeout(goalsQuietAutosaveTimer);
      goalsQuietAutosaveTimer = null;
    }
    if (!pendingGoalsQuietSave || !window.Shiny || !window.Shiny.setInputValue) return false;
    var payload = Object.assign({}, pendingGoalsQuietSave, { nonce: Date.now() });
    pendingGoalsQuietSave = null;
    setGoalsSaveStatus("Autosaving...");
    beginBackgroundAutosave();
    window.Shiny.setInputValue("goals_draft_quiet_save", payload, { priority: "event" });
    return true;
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

  function updateGoalControls(page) {
    var editors = Array.from(page.querySelectorAll(".goal-editor"));
    var goalCount = editors.length;
    var maximumGoals = parseInt(page.getAttribute("data-max-goals") || "5", 10);
    if (!Number.isFinite(maximumGoals) || maximumGoals < 1) maximumGoals = 5;
    var addButton = page.querySelector("#add_goal");
    if (addButton) addButton.disabled = goalCount >= maximumGoals;
    editors.forEach(function (editor, index) {
      var number = editor.querySelector("summary .goal-number");
      var removeButton = editor.querySelector(".remove-goal-button");
      if (number) number.textContent = "Goal " + (index + 1);
      if (removeButton) {
        removeButton.disabled = index === 0 || goalCount <= 1;
        removeButton.title = index === 0 ? "The first goal is required to create additional goals" : (goalCount <= 1 ? "At least one goal must remain while editing" : "Remove goal");
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
      setGoalsSaveStatus("Autosaved at " + new Date(message.updatedAt).toLocaleTimeString() + ".");
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
    var page = document.querySelector(".builder-page-content[data-section-key='services']");
    if (!page) return;
    if (message && message.ok) {
      page.dataset.autosaveDirty = "false";
      if (message.revision != null) page.dataset.draftRevision = String(message.revision);
      window.localStorage.removeItem(builderDraftKey(page));
      setGoalsSaveStatus("Autosaved at " + new Date(message.updatedAt).toLocaleTimeString() + ".");
      return;
    }
    setGoalsSaveStatus((message && message.message) || "The service description could not be saved. Your browser recovery copy is still available.");
  }

  function handleServiceMetricsDraftResult(message) {
    endBackgroundAutosave();
    var page = document.querySelector(".builder-page-content[data-section-key='services']");
    if (!page) return;
    if (message && message.ok) {
      page.dataset.autosaveDirty = "false";
      if (message.revision != null) page.dataset.draftRevision = String(message.revision);
      var serviceId = String(message.serviceId || "");
      var editor = serviceId ? Array.from(page.querySelectorAll(".service-editor")).find(function (candidate) {
        return candidate.getAttribute("data-service-id") === serviceId;
      }) : null;
      if (editor) {
        updateServiceEditorMetricMetadata(editor);
      }
      updateAllKpiAvailability(page.querySelector(".services-page"));
      window.localStorage.removeItem(builderDraftKey(page));
      setGoalsSaveStatus("Autosaved at " + new Date(message.updatedAt).toLocaleTimeString() + ".");
      return;
    }
    setGoalsSaveStatus((message && message.message) || "The service metrics could not be saved. Your browser recovery copy is still available.");
  }

  function handleGoalsDraftResult(message) {
    endBackgroundAutosave();
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
      setGoalsSaveStatus("Autosaved at " + new Date(message.updatedAt).toLocaleTimeString() + ".");
      return;
    }
    page.dataset.autosaveDirty = "true";
    setGoalsSaveStatus((message && message.message) || "The goals draft could not be saved. Your browser recovery copy is still available.");
  }

  function handlePlanReviewSaveResult(message) {
    if (!message || !message.ok) return;
    setReviewSaveStatus("Review autosaved at " + message.savedAt + ". Current score: " + message.score + "/100.");
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
      updateServiceEditorMetricMetadata(editor);
      if (page) updateAllKpiAvailability(page);
      disableLockedBuilderControls(target.closest(".builder-page-content"));
    }, 0);
  });

  document.addEventListener("input", function (event) {
    var page = event.target.closest(".builder-page-content");
    var goalsPage = event.target.closest(".goals-page");
    if (!page || page.dataset.restoringDraft === "true" || (goalsPage && goalsPage.dataset.restoringDraft === "true")) return;
    if (goalsPage && event.target.matches("textarea[id^='goal_statement_'], .initiative-inputs textarea")) {
      updateGoalRequirements(goalsPage);
      scheduleGoalsQuietAutosave(page, 900);
      return;
    }
    if (event.target.closest(".services-page") && event.target.matches("textarea[id^='service_description_']")) {
      page.dataset.autosaveDirty = "false";
      scheduleServiceDescriptionAutosave(page, event.target, 500);
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
      scheduleGoalsQuietAutosave(page, 500);
      return;
    }
    if (goalsPage && event.target.matches(".kpi-select-row select")) {
      updateGoalRequirements(goalsPage);
      updateAllKpiAvailability(goalsPage);
      scheduleGoalsQuietAutosave(page, 700);
      return;
    }
    if (event.target.closest(".services-page") && event.target.matches(".kpi-select-row select")) {
      scheduleServiceMetricsAutosave(page, event.target.closest(".service-editor"), 1200);
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
    scheduleBuilderAutosave(page.closest(".builder-page-content"), 500);
  });

  document.addEventListener("click", function (event) {
    var removeButton = event.target.closest(".remove-goal-button");
    if (!removeButton) return;
    event.preventDefault();
    var page = removeButton.closest(".goals-page");
    var editor = removeButton.closest(".goal-editor");
    if (!page || !editor || page.querySelectorAll(".goal-editor").length <= 1) return;
    if (Array.from(page.querySelectorAll(".goal-editor")).indexOf(editor) === 0) return;
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
    if (!page.isConnected || !editor.isConnected || page.querySelectorAll(".goal-editor").length <= 1) return;
    if (window.Shiny && window.Shiny.unbindAll) window.Shiny.unbindAll(editor);
    editor.remove();
    updateAllKpiAvailability(page);
    updateGoalRequirements(page);
    scheduleBuilderAutosave(page.closest(".builder-page-content"), 500);
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
    flushServiceDescriptionAutosave();
    flushServiceMetricsAutosave();
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
