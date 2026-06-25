(function () {
  var pendingGoalDeletion = null;

  function dismissGoalDeleteDialog() {
    pendingGoalDeletion = null;
    var dialog = document.getElementById("delete_goal_dialog");
    if (dialog && dialog.open) dialog.close();
  }

  function setActivePage(page) {
    document.querySelectorAll("[data-page]").forEach(function (button) {
      button.classList.toggle("active", button.getAttribute("data-page") === page);
    });
  }

  function closeMobileNav() {
    document.body.classList.remove("mobile-nav-open");
    var toggle = document.getElementById("toggle_mobile_nav");
    if (toggle) toggle.setAttribute("aria-expanded", "false");
  }

  function sendPage(page) {
    dismissGoalDeleteDialog();
    setActivePage(page);
    closeMobileNav();
    if (window.Shiny) {
      window.Shiny.setInputValue("current_page", page, { priority: "event" });
    }
  }

  document.addEventListener("click", function (event) {
    var button = event.target.closest("[data-page]");
    if (!button) return;
    sendPage(button.getAttribute("data-page"));
  });

  document.addEventListener("click", function (event) {
    var row = event.target.closest("[data-measure-id]");
    var addButton = event.target.closest("[data-new-measure]");
    if ((!row && !addButton) || !window.Shiny) return;
    window.Shiny.setInputValue("open_measure_id", addButton ? "new" : row.getAttribute("data-measure-id"), { priority: "event" });
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
      window.Shiny.setInputValue("review_plan_request", {
        planId: Number(reviewButton.getAttribute("data-review-plan")),
        nonce: Date.now()
      }, { priority: "event" });
    }
    if (exportButton) {
      window.Shiny.setInputValue("export_plan_request", {
        planId: Number(exportButton.getAttribute("data-export-plan")),
        exportType: exportButton.getAttribute("data-export-type"),
        nonce: Date.now()
      }, { priority: "event" });
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
    if (!event.target.closest("#save_risk") || !window.Shiny) return;
    event.preventDefault();
    window.Shiny.setInputValue("risk_save_request", Date.now(), { priority: "event" });
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
  });

  document.addEventListener("input", function (event) {
    if (!event.target || !event.target.matches(".measure-value-input")) return;
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

  function updateAllKpiAvailability(page) {
    if (!page) return;
    var allSelects = Array.from(page.querySelectorAll(".kpi-select-row select"));
    var selectedValues = allSelects.map(function (select) { return select.value; }).filter(function (value) { return value !== ""; });
    allSelects.forEach(function (select) {
      Array.from(select.options).forEach(function (option) {
        option.disabled = option.value !== "" && option.value !== select.value && selectedValues.indexOf(option.value) !== -1;
      });
    });
    page.querySelectorAll(".kpi-picker").forEach(function (picker) {
      var selectors = Array.from(picker.querySelectorAll(".kpi-select-row select"));
      if (selectors.length === 0) return;
      updateKpiPreview(selectors[0]);
      var outsideValues = new Set(allSelects.filter(function (select) {
        return !picker.contains(select) && select.value !== "";
      }).map(function (select) { return select.value; }));
      var measureCount = selectors[0].options.length - 1;
      var availableCount = measureCount - outsideValues.size;
      var addButton = picker.querySelector(".add-kpi-button");
      if (addButton) addButton.disabled = selectors.length >= availableCount || selectors.some(function (select) { return select.value === ""; });
    });
    if (page.matches(".services-page")) {
      page.querySelectorAll(".service-editor").forEach(function (editor) {
        var count = Array.from(editor.querySelectorAll(".kpi-select-row select")).filter(function (select) { return select.value !== ""; }).length;
        var chip = editor.querySelector(".service-metric-count");
        if (chip) chip.textContent = count + " " + (count === 1 ? "Metric" : "Metrics");
      });
    }
  }

  document.addEventListener("change", function (event) {
    if (!event.target.matches(".kpi-select-row select")) return;
    updateKpiPreview(event.target);
    updateAllKpiAvailability(event.target.closest(".goals-page, .services-page"));
  });

  function addKpiSelector(picker, value) {
    var container = picker.querySelector(".kpi-selectors");
    var sourceRow = container && container.querySelector(".kpi-select-row");
    if (!container || !sourceRow) return null;
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
    addKpiSelector(addButton.closest(".kpi-picker"), "");
    if (page && page.matches(".goals-page")) updateGoalRequirements(page);
    setGoalsSaveStatus("Unsaved changes");
  });

  document.addEventListener("click", function (event) {
    var removeButton = event.target.closest(".kpi-remove-button");
    if (!removeButton) return;
    var picker = removeButton.closest(".kpi-picker");
    var row = removeButton.closest(".kpi-select-row");
    if (window.Shiny && window.Shiny.unbindAll) window.Shiny.unbindAll(row);
    row.remove();
    var remaining = picker.querySelector(".kpi-select-row select");
    var page = picker.closest(".goals-page, .services-page");
    if (remaining) updateAllKpiAvailability(page);
    if (page && page.matches(".goals-page")) updateGoalRequirements(page);
    setGoalsSaveStatus("Unsaved changes");
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
    setGoalsSaveStatus("Unsaved changes");
  });

  document.addEventListener("click", function (event) {
    var removeButton = event.target.closest(".initiative-remove-button");
    if (!removeButton) return;
    var row = removeButton.closest(".initiative-input-row");
    if (window.Shiny && window.Shiny.unbindAll) window.Shiny.unbindAll(row);
    row.remove();
    updateGoalRequirements(removeButton.closest(".goals-page"));
    setGoalsSaveStatus("Unsaved changes");
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

  function setGoalsSaveStatus(message) {
    var status = document.getElementById("plan_save_status");
    if (status) status.textContent = message;
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
    page.querySelectorAll(".service-metric-selectors").forEach(function (container) {
      serviceMetrics[container.getAttribute("data-service-id")] = Array.from(container.querySelectorAll("select")).map(function (select) {
        return select.value;
      }).filter(function (value) {
        return value !== "";
      });
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
    if (draft.serviceMetrics) {
      Object.keys(draft.serviceMetrics).forEach(function (serviceId) {
        var container = page.querySelector(".service-metric-selectors[data-service-id='" + serviceId + "']");
        if (!container) return;
        var picker = container.closest(".kpi-picker");
        var savedMetrics = draft.serviceMetrics[serviceId];
        while (container.querySelectorAll(".kpi-select-row").length > 1) {
          container.querySelector(".kpi-select-row:last-child").remove();
        }
        var firstSelect = container.querySelector("select");
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
    var addButton = page.querySelector("#add_goal");
    if (addButton) addButton.disabled = goalCount >= 5;
    editors.forEach(function (editor, index) {
      var number = editor.querySelector("summary .goal-number");
      var removeButton = editor.querySelector(".remove-goal-button");
      if (number) number.textContent = "Goal " + (index + 1);
      if (removeButton) {
        removeButton.disabled = goalCount <= 1;
        removeButton.title = goalCount <= 1 ? "At least one goal must remain while editing" : "Remove goal";
      }
    });
  }

  function updateGoalRequirements(page) {
    var editors = Array.from(page.querySelectorAll(".goal-editor"));
    var goalCount = editors.length;
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
    var remainingLabel = page.querySelector(".remaining-goal-count");
    var minimumChip = page.querySelector(".goals-drafted-stat .status-chip");
    var alignmentChip = page.querySelector(".pillar-alignment-stat .status-chip");
    if (goalCountLabel) goalCountLabel.textContent = draftedCount;
    if (alignedCountLabel) alignedCountLabel.textContent = alignedCount;
    if (remainingLabel) {
      var remaining = 5 - goalCount;
      remainingLabel.textContent = remaining > 0 ? "You can add " + remaining + " more " + (remaining === 1 ? "goal." : "goals.") : "The five-goal maximum has been reached.";
    }
    setRequirementChip(minimumChip, draftedCount >= 3 ? "Minimum met" : (3 - draftedCount) + " more required", draftedCount >= 3 ? "success" : "error");
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
    if (!draft) {
      try {
        draft = JSON.parse(window.localStorage.getItem(goalsDraftKey(page)));
      } catch (error) {
        draft = null;
      }
    }
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
        setGoalsSaveStatus("No shared draft yet. Seeded plan data is shown.");
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
    var page = document.querySelector(".builder-page-content");
    if (!draftMatchesPage(message, page)) return;
    if (message.ok) {
      page.dataset.draftRevision = String(message.revision);
      var goalsPage = page.querySelector(".goals-page");
      window.localStorage.removeItem(goalsPage ? goalsDraftKey(goalsPage) : builderDraftKey(page));
      setGoalsSaveStatus("Shared draft saved at " + new Date(message.updatedAt).toLocaleTimeString() + ".");
      return;
    }
    if (message.conflict) {
      setGoalsSaveStatus("A newer shared draft was saved by someone else. Your browser recovery copy is still available; reload before saving again.");
      return;
    }
    setGoalsSaveStatus("The shared draft could not be saved. Your browser recovery copy is still available.");
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
    if (page.getAttribute("data-plan-locked") === "true") {
      page.querySelectorAll("input, textarea, select, button").forEach(function (control) {
        if (control.closest(".rubric-section")) return;
        control.disabled = true;
        control.setAttribute("aria-disabled", "true");
      });
      return;
    }
    requestSharedDraft(page);
  }

  function initializeServicesPage() {
    var page = document.querySelector(".services-page");
    if (!page || page.dataset.servicesInitialized === "true") return;
    page.dataset.servicesInitialized = "true";
    page.querySelectorAll(".service-editor").forEach(function (editor) {
      var body = editor.querySelector(".service-editor-body");
      if (body) body.setAttribute("aria-hidden", editor.open ? "false" : "true");
    });
    updateAllKpiAvailability(page);
  }

  document.addEventListener("toggle", function (event) {
    if (!event.target.matches) return;
    if (event.target.matches(".goal-editor")) {
      var body = event.target.querySelector(".goal-editor-body");
      if (body) body.setAttribute("aria-hidden", event.target.open ? "false" : "true");
    }
    if (event.target.matches(".service-editor")) {
      var serviceBody = event.target.querySelector(".service-editor-body");
      if (serviceBody) serviceBody.setAttribute("aria-hidden", event.target.open ? "false" : "true");
    }
    if (event.target.matches(".rubric-section")) {
      var table = event.target.querySelector(".rubric-section-table-wrap");
      if (table) table.setAttribute("aria-hidden", event.target.open ? "false" : "true");
    }
  }, true);

  document.addEventListener("input", function (event) {
    var page = event.target.closest(".builder-page-content");
    var goalsPage = event.target.closest(".goals-page");
    if (!page || (goalsPage && goalsPage.dataset.restoringDraft === "true")) return;
    if (goalsPage && event.target.matches("textarea[id^='goal_statement_'], .initiative-inputs textarea")) updateGoalRequirements(goalsPage);
    setGoalsSaveStatus("Unsaved changes");
  });

  document.addEventListener("change", function (event) {
    var page = event.target.closest(".builder-page-content");
    var goalsPage = event.target.closest(".goals-page");
    if (!page || (goalsPage && goalsPage.dataset.restoringDraft === "true")) return;
    if (goalsPage && event.target.matches("select[id^='goal_alignment_']")) {
      updateGoalAlignmentSummary(event.target.closest(".goal-editor"));
      updateGoalRequirements(goalsPage);
    }
    if (goalsPage && event.target.matches(".kpi-select-row select")) updateGoalRequirements(goalsPage);
    setGoalsSaveStatus("Unsaved changes");
  });

  document.addEventListener("click", function (event) {
    var addButton = event.target.closest("#add_goal");
    if (!addButton) return;
    event.preventDefault();
    var page = addButton.closest(".goals-page");
    if (!page || page.querySelectorAll(".goal-editor").length >= 5) return;
    addGoalEditor(page);
    updateAllKpiAvailability(page);
    updateGoalRequirements(page);
    setGoalsSaveStatus("Unsaved changes");
  });

  document.addEventListener("click", function (event) {
    var removeButton = event.target.closest(".remove-goal-button");
    if (!removeButton) return;
    event.preventDefault();
    var page = removeButton.closest(".goals-page");
    var editor = removeButton.closest(".goal-editor");
    if (!page || !editor || page.querySelectorAll(".goal-editor").length <= 1) return;
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
    setGoalsSaveStatus("Goal deleted. Unsaved changes");
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
    var builderPage = document.querySelector(".builder-page-content");
    var goalsPage = builderPage && builderPage.querySelector(".goals-page");
    if (!builderPage) return;
    var draft = goalsPage ? collectGoalsDraft(goalsPage) : collectBuilderDraft(builderPage);
    window.localStorage.setItem(goalsPage ? goalsDraftKey(goalsPage) : builderDraftKey(builderPage), JSON.stringify(draft));
    if (goalsPage) {
      updateGoalSummaries(goalsPage);
      updateGoalRequirements(goalsPage);
    }
    setGoalsSaveStatus("Saving shared draft...");
    if (window.Shiny && window.Shiny.setInputValue) {
      window.Shiny.setInputValue("shared_draft_save", {
        planId: Number(builderPage.getAttribute("data-plan-id")),
        sectionKey: builderPage.getAttribute("data-section-key"),
        revision: Number(builderPage.dataset.draftRevision || 0),
        payloadJson: JSON.stringify(draft),
        nonce: Date.now()
      }, { priority: "event" });
    } else {
      setGoalsSaveStatus("The server is unavailable. Your browser recovery copy is still available.");
    }
  });

  document.addEventListener("click", function (event) {
    var submitButton = event.target.closest("[data-submit-plan]");
    if (!submitButton) return;
    if (!window.confirm("Are you sure you want to submit this plan? Fields will lock while it is in review.")) return;
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
      updateMeasureNumberFormat();
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
    setActivePage("login");
    schedulePageInitialization();
  });

  if (window.Shiny) {
    window.Shiny.addCustomMessageHandler("set-page", setActivePage);
    window.Shiny.addCustomMessageHandler("shared-draft-loaded", applyLoadedDraft);
    window.Shiny.addCustomMessageHandler("shared-draft-result", handleDraftSaveResult);
    window.Shiny.addCustomMessageHandler("trigger-plan-download", triggerPlanDownload);
  } else {
    document.addEventListener("shiny:connected", function () {
      window.Shiny.addCustomMessageHandler("set-page", setActivePage);
      window.Shiny.addCustomMessageHandler("shared-draft-loaded", applyLoadedDraft);
      window.Shiny.addCustomMessageHandler("shared-draft-result", handleDraftSaveResult);
      window.Shiny.addCustomMessageHandler("trigger-plan-download", triggerPlanDownload);
    });
  }
})();
