(function () {
  function setActivePage(page) {
    document.querySelectorAll("[data-page]").forEach(function (button) {
      button.classList.toggle("active", button.getAttribute("data-page") === page);
    });
  }

  function sendPage(page) {
    setActivePage(page);
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
    var backdrop = event.target.closest("[data-close-input]");
    if (!backdrop || event.target !== backdrop || !window.Shiny) return;
    window.Shiny.setInputValue(backdrop.getAttribute("data-close-input"), Date.now(), { priority: "event" });
  });

  document.addEventListener("shiny:connected", function () {
    setActivePage("login");
  });

  if (window.Shiny) {
    window.Shiny.addCustomMessageHandler("set-page", setActivePage);
  } else {
    document.addEventListener("shiny:connected", function () {
      window.Shiny.addCustomMessageHandler("set-page", setActivePage);
    });
  }
})();
