sendgrid_env <- function(primary, fallback = NULL) {
  load_env_file()
  value <- Sys.getenv(primary)
  if (!nzchar(value) && !is.null(fallback)) value <- Sys.getenv(fallback)
  trimws(value)
}

sendgrid_from <- function(value) {
  value <- trimws(as.character(value %||% ""))
  match <- regexec("^(.*)<([^>]+)>\\s*$", value)
  parts <- regmatches(value, match)[[1]]
  if (length(parts) == 3) {
    return(list(email = trimws(parts[[3]]), name = trimws(parts[[2]])))
  }
  list(email = value)
}

sendgrid_enabled <- function() {
  nzchar(sendgrid_env("SENDGRID_API_KEY", "ORF_SENDGRID_API_KEY")) &&
    nzchar(sendgrid_env("DEFAULT_FROM_EMAIL", "ORF_DEFAULT_FROM_EMAIL")) &&
    nzchar(Sys.which("curl.exe"))
}

send_sendgrid_email <- function(to_email, subject, html_body, text_body = NULL) {
  api_key <- sendgrid_env("SENDGRID_API_KEY", "ORF_SENDGRID_API_KEY")
  from_value <- sendgrid_env("DEFAULT_FROM_EMAIL", "ORF_DEFAULT_FROM_EMAIL")
  to_email <- trimws(as.character(to_email %||% ""))
  if (!nzchar(api_key) || !nzchar(from_value)) stop("SendGrid is not configured.")
  if (!nzchar(to_email) || !grepl("@", to_email, fixed = TRUE)) stop("A valid recipient email is required.")
  curl_path <- Sys.which("curl.exe")
  if (!nzchar(curl_path)) stop("curl.exe is not available for SendGrid delivery.")
  if (is.null(text_body)) {
    text_body <- gsub("<[^>]+>", " ", html_body)
    text_body <- gsub("\\s+", " ", text_body)
  }
  payload <- list(
    personalizations = list(list(to = list(list(email = to_email)))),
    from = sendgrid_from(from_value),
    subject = subject,
    content = list(
      list(type = "text/plain", value = text_body),
      list(type = "text/html", value = html_body)
    )
  )
  body_file <- tempfile(fileext = ".json")
  config_file <- tempfile(fileext = ".curl")
  on.exit(unlink(c(body_file, config_file)), add = TRUE)
  writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null"), body_file, useBytes = TRUE)
  writeLines(
    c(
      "silent",
      "show-error",
      "fail-with-body",
      "request = \"POST\"",
      "url = \"https://api.sendgrid.com/v3/mail/send\"",
      "noproxy = \"*\"",
      sprintf("header = \"Authorization: Bearer %s\"", api_key),
      "header = \"Content-Type: application/json\"",
      sprintf("data = \"@%s\"", normalizePath(body_file, winslash = "/", mustWork = TRUE))
    ),
    config_file,
    useBytes = TRUE
  )
  output <- system2(
    curl_path,
    args = c("--config", normalizePath(config_file, winslash = "/", mustWork = TRUE)),
    stdout = TRUE,
    stderr = TRUE
  )
  status <- attr(output, "status")
  if (!is.null(status) && !identical(status, 0L)) {
    stop(paste("SendGrid delivery failed:", paste(output, collapse = " ")))
  }
  invisible(TRUE)
}

send_account_email <- function(email, subject, message) {
  html <- paste0(
    "<p>", htmltools::htmlEscape(message), "</p>",
    "<p><strong>Beacon</strong><br>Baltimore City Performance &amp; Budgeting</p>"
  )
  send_sendgrid_email(email, subject, html, message)
}
