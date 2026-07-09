# Interim password authentication against the access schema.
#
# Users are provisioned by admins (seed workbooks), so there is no
# self-registration: "first time here" and "forgot password" are the same
# token flow, differing only in copy. access."user".auth_type marks the
# intended provider ('Email' or 'MicrosoftAD'); until Entra sign-in exists,
# password login is allowed for both types.

AUTH_REVIEWER_ROLES <- c("OPIReviewer", "BBMRReviewer", "SystemAdmin", "DeputyMayor", "CAOffice")
AUTH_MIN_PASSWORD_CHARS <- 10L
AUTH_TOKEN_MINUTES <- 60L
AUTH_SESSION_DAYS <- 7L
AUTH_SESSION_IDLE_MINUTES <- 60L
AUTH_MAX_FAILURES <- 5L
AUTH_LOCKOUT_MINUTES <- 15L

if (!exists("%||%", mode = "function")) {
  `%||%` <- function(x, y) if (is.null(x) || length(x) == 0 || is.na(x)) y else x
}

auth_find_user <- function(connection, email) {
  if (is.null(email) || !nzchar(trimws(email))) return(NULL)
  rows <- DBI::dbGetQuery(
    connection,
    'SELECT user_id, email, full_name, auth_type, password_hash, active FROM access."user" WHERE lower(email) = lower($1) AND active',
    params = list(trimws(email))
  )
  if (!nrow(rows)) return(NULL)
  rows[1, , drop = FALSE]
}

auth_verify_login <- function(connection, email, password) {
  user <- auth_find_user(connection, email)
  if (is.null(user)) return(NULL)
  hash <- user$password_hash[[1]]
  if (is.na(hash) || !nzchar(hash)) return(NULL)
  ok <- tryCatch(sodium::password_verify(hash, password), error = function(error) FALSE)
  if (isTRUE(ok)) user else NULL
}

auth_find_user_by_id <- function(connection, user_id) {
  user_id <- suppressWarnings(as.integer(user_id))
  if (is.na(user_id)) return(NULL)
  rows <- DBI::dbGetQuery(
    connection,
    'SELECT user_id, email, full_name, auth_type, password_hash, active FROM access."user" WHERE user_id = $1 AND active',
    params = list(user_id)
  )
  if (!nrow(rows)) return(NULL)
  rows[1, , drop = FALSE]
}

auth_password_problem <- function(password, confirm) {
  if (is.null(password) || nchar(password) < AUTH_MIN_PASSWORD_CHARS) {
    return(paste("Passwords must be at least", AUTH_MIN_PASSWORD_CHARS, "characters."))
  }
  if (!identical(password, confirm)) return("The two passwords do not match.")
  NULL
}

auth_set_password <- function(connection, user_id, password) {
  DBI::dbExecute(
    connection,
    'UPDATE access."user" SET password_hash = $1 WHERE user_id = $2',
    params = list(sodium::password_store(password), as.integer(user_id))
  )
}

# Only a hash of the token is stored; the emailed link holds the plaintext.
auth_hash_token <- function(token) sodium::bin2hex(sodium::hash(charToRaw(token)))

auth_issue_reset_token <- function(connection, user_id) {
  token <- sodium::bin2hex(sodium::random(32L))
  DBI::dbExecute(
    connection,
    paste0(
      "INSERT INTO access.password_reset_token (user_id, token_hash, expires_at) ",
      "VALUES ($1, $2, now() + interval '", AUTH_TOKEN_MINUTES, " minutes')"
    ),
    params = list(as.integer(user_id), auth_hash_token(token))
  )
  token
}

auth_issue_login_session <- function(connection, user_id) {
  token <- sodium::bin2hex(sodium::random(32L))
  DBI::dbExecute(
    connection,
    paste0(
      "INSERT INTO access.user_login_session (user_id, token_hash, expires_at) ",
      "VALUES ($1, $2, now() + interval '", AUTH_SESSION_DAYS, " days')"
    ),
    params = list(as.integer(user_id), auth_hash_token(token))
  )
  token
}

auth_lookup_login_session <- function(connection, token) {
  if (is.null(token) || !nzchar(token)) return(NULL)
  rows <- DBI::dbGetQuery(
    connection,
    paste(
      "SELECT session_id, user_id FROM access.user_login_session",
      "WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > now()",
      paste0("AND COALESCE(last_seen_at, created_at) > now() - interval '", AUTH_SESSION_IDLE_MINUTES, " minutes'"),
      "ORDER BY created_at DESC LIMIT 1"
    ),
    params = list(auth_hash_token(token))
  )
  if (!nrow(rows)) return(NULL)
  user <- auth_find_user_by_id(connection, rows$user_id[[1]])
  if (is.null(user)) return(NULL)
  DBI::dbExecute(
    connection,
    "UPDATE access.user_login_session SET last_seen_at = now() WHERE session_id = $1",
    params = list(rows$session_id[[1]])
  )
  user
}

auth_touch_login_session <- function(connection, token) {
  if (is.null(token) || !nzchar(token)) return(FALSE)
  updated <- DBI::dbExecute(
    connection,
    paste(
      "UPDATE access.user_login_session SET last_seen_at = now()",
      "WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > now()",
      paste0("AND COALESCE(last_seen_at, created_at) > now() - interval '", AUTH_SESSION_IDLE_MINUTES, " minutes'")
    ),
    params = list(auth_hash_token(token))
  )
  isTRUE(updated > 0)
}

auth_revoke_login_session <- function(connection, token) {
  if (is.null(token) || !nzchar(token)) return(invisible(FALSE))
  DBI::dbExecute(
    connection,
    "UPDATE access.user_login_session SET revoked_at = now() WHERE token_hash = $1 AND revoked_at IS NULL",
    params = list(auth_hash_token(token))
  )
  invisible(TRUE)
}

auth_lookup_reset_token <- function(connection, token) {
  if (is.null(token) || !nzchar(token)) return(NULL)
  rows <- DBI::dbGetQuery(
    connection,
    "SELECT token_id, user_id FROM access.password_reset_token WHERE token_hash = $1 AND used_at IS NULL AND expires_at > now()",
    params = list(auth_hash_token(token))
  )
  if (!nrow(rows)) return(NULL)
  rows[1, , drop = FALSE]
}

auth_complete_reset <- function(connection, token, password) {
  row <- auth_lookup_reset_token(connection, token)
  if (is.null(row)) return(FALSE)
  auth_set_password(connection, row$user_id[[1]], password)
  DBI::dbExecute(
    connection,
    "UPDATE access.password_reset_token SET used_at = now() WHERE user_id = $1 AND used_at IS NULL",
    params = list(as.integer(row$user_id[[1]]))
  )
  TRUE
}

auth_user_roles <- function(connection, user_id) {
  DBI::dbGetQuery(
    connection,
    "SELECT app_role, agency_id FROM access.user_role WHERE user_id = $1",
    params = list(as.integer(user_id))
  )
}

auth_user_agencies <- function(connection, user_id) {
  DBI::dbGetQuery(
    connection,
    "SELECT agency_id, agency_role, COALESCE(NULLIF(agency_roles, ''), agency_role) AS agency_roles FROM access.user_agency_access WHERE user_id = $1",
    params = list(as.integer(user_id))
  )
}

auth_home_page <- function(roles) {
  if (nrow(roles) && any(roles$app_role %in% AUTH_REVIEWER_ROLES)) "reviewer_dashboard" else "landing"
}

# In-process failed-attempt throttle, keyed by lowercased email.
auth_throttle <- new.env(parent = emptyenv())

auth_attempt_blocked <- function(email) {
  entry <- auth_throttle[[tolower(trimws(email))]]
  !is.null(entry) && entry$count >= AUTH_MAX_FAILURES && Sys.time() < entry$until
}

auth_note_failure <- function(email) {
  key <- tolower(trimws(email))
  entry <- auth_throttle[[key]]
  count <- if (is.null(entry) || Sys.time() >= entry$until) 1L else entry$count + 1L
  auth_throttle[[key]] <- list(count = count, until = Sys.time() + AUTH_LOCKOUT_MINUTES * 60)
}

auth_clear_failures <- function(email) {
  key <- tolower(trimws(email))
  if (!is.null(auth_throttle[[key]])) rm(list = key, envir = auth_throttle)
}

auth_reset_link <- function(session, token) {
  base <- Sys.getenv("APP_BASE_URL")
  if (!nzchar(base)) {
    client <- session$clientData
    port <- client$url_port
    base <- paste0(client$url_protocol, "//", client$url_hostname, if (nzchar(port)) paste0(":", port) else "")
  }
  paste0(sub("/+$", "", base), "/?reset=", token)
}

auth_env_first <- function(..., default = "") {
  names <- c(...)
  for (name in names) {
    value <- Sys.getenv(name)
    if (nzchar(value)) return(value)
  }
  default
}

# Explicit SMTP_* settings win; otherwise SENDGRID_API_KEY selects SendGrid's
# SMTP relay (username is the literal string "apikey").
auth_smtp_settings <- function() {
  host <- Sys.getenv("SMTP_HOST")
  default_from <- auth_env_first("SMTP_FROM", "DEFAULT_FROM_EMAIL", "ORF_DEFAULT_FROM_EMAIL", default = "performance@baltimorecity.gov")
  if (nzchar(host)) {
    return(list(
      host = host,
      port = Sys.getenv("SMTP_PORT", "587"),
      username = Sys.getenv("SMTP_USER"),
      password = Sys.getenv("SMTP_PASSWORD"),
      from = default_from
    ))
  }
  sendgrid_key <- auth_env_first("SENDGRID_API_KEY", "ORF_SENDGRID_API_KEY")
  if (nzchar(sendgrid_key)) {
    return(list(
      host = "smtp.sendgrid.net",
      port = Sys.getenv("SMTP_PORT", "587"),
      username = "apikey",
      password = sendgrid_key,
      from = default_from
    ))
  }
  NULL
}

auth_smtp_configured <- function() !is.null(auth_smtp_settings())

# Demo-only escape hatch: shows password links on screen and suppresses all
# outbound email (seeded addresses belong to real employees). Never enable
# outside local/demo environments — it lets anyone claim any account.
auth_dev_links_enabled <- function() tolower(Sys.getenv("AUTH_DEV_LINKS")) %in% c("true", "1", "yes")

# "Display Name <user@host>" -> "user@host" for the SMTP envelope; the
# friendly form still goes in the From: header.
auth_bare_address <- function(address) {
  match <- regmatches(address, regexec("<([^>]+)>", address))[[1]]
  if (length(match) == 2) match[[2]] else address
}

auth_email_escape <- function(value) {
  value <- as.character(value %||% "")
  value <- gsub("&", "&amp;", value, fixed = TRUE)
  value <- gsub("<", "&lt;", value, fixed = TRUE)
  value <- gsub(">", "&gt;", value, fixed = TRUE)
  value <- gsub('"', "&quot;", value, fixed = TRUE)
  value
}

auth_email_plain_url <- function(url) {
  paste0("<", gsub(">", "%3E", as.character(url %||% ""), fixed = TRUE), ">")
}

auth_email_logo_url <- function() {
  configured <- Sys.getenv("BEACON_EMAIL_LOGO_URL")
  if (nzchar(configured)) return(configured)
  base <- Sys.getenv("APP_BASE_URL")
  if (!nzchar(base)) return("")
  paste0(sub("/+$", "", base), "/baltimore-city-logo.png")
}

auth_build_app_email <- function(from, to, subject, preheader, eyebrow, title, intro, button_label = NULL, button_url = NULL, detail_lines = character(), footer_note = NULL) {
  boundary <- paste0("beacon-", format(Sys.time(), "%Y%m%d%H%M%S"), "-", paste(sample(c(letters, 0:9), 12, replace = TRUE), collapse = ""))
  safe_subject <- gsub("[\r\n]+", " ", as.character(subject %||% "Beacon notification"))
  logo_url <- auth_email_logo_url()
  logo_html <- if (nzchar(logo_url)) {
    paste0(
      "<td width=\"58\" style=\"padding:0 14px 0 0;vertical-align:middle;\">",
      "<img src=\"", auth_email_escape(logo_url), "\" width=\"48\" height=\"48\" alt=\"City of Baltimore logo\" style=\"display:block;width:48px;height:48px;border-radius:50%;background:#ffffff;object-fit:contain;border:2px solid rgba(255,255,255,0.72);\">",
      "</td>"
    )
  } else {
    ""
  }
  text_lines <- c(
    title,
    "",
    intro,
    "",
    if (!is.null(button_label) && !is.null(button_url)) c(paste0(button_label, ": ", button_url), "") else character(),
    detail_lines,
    "",
    footer_note %||% "If you were not expecting this message, you can ignore it."
  )
  text_body <- paste(text_lines[nzchar(text_lines) | text_lines == ""], collapse = "\r\n")
  details_html <- if (length(detail_lines)) {
    paste0(
      "<div style=\"margin:20px 0 0;padding:14px 16px;background:#f7fbfc;border:1px solid #d8e2e8;border-radius:8px;color:#526270;font-size:14px;line-height:1.5;\">",
      paste(auth_email_escape(detail_lines), collapse = "<br>"),
      "</div>"
    )
  } else {
    ""
  }
  button_html <- if (!is.null(button_label) && !is.null(button_url)) {
    paste0(
      "<a href=\"", auth_email_escape(button_url), "\" style=\"display:inline-block;margin:22px 0 4px;padding:13px 18px;background:#2f1c3d;color:#ffffff;text-decoration:none;border-radius:8px;font-weight:800;\">",
      auth_email_escape(button_label),
      "</a>",
      "<p style=\"margin:14px 0 0;color:#526270;font-size:13px;line-height:1.5;\">If the button does not work, copy and paste this link into your browser:<br>",
      "<a href=\"", auth_email_escape(button_url), "\" style=\"color:#2f1c3d;word-break:break-all;\">", auth_email_escape(button_url), "</a></p>"
    )
  } else {
    ""
  }
  html_body <- paste0(
    "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head>",
    "<body style=\"margin:0;padding:0;background:#f7fbfc;font-family:Arial,Helvetica,sans-serif;color:#161616;\">",
    "<div style=\"display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;\">", auth_email_escape(preheader), "</div>",
    "<table role=\"presentation\" width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" style=\"background:#f7fbfc;padding:28px 12px;\"><tr><td align=\"center\">",
    "<table role=\"presentation\" width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" style=\"max-width:640px;background:#ffffff;border:1px solid #d8e2e8;border-radius:12px;overflow:hidden;box-shadow:0 12px 30px rgba(25,14,33,0.08);\">",
    "<tr><td style=\"background:#190e21;padding:22px 26px;color:#ffffff;\">",
    "<table role=\"presentation\" cellspacing=\"0\" cellpadding=\"0\"><tr>",
    logo_html,
    "<td style=\"vertical-align:middle;\">",
    "<div style=\"font-size:22px;font-weight:800;line-height:1.2;\">Beacon</div>",
    "<div style=\"margin-top:4px;color:rgba(255,255,255,0.78);font-size:13px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;\">Baltimore City Performance &amp; Budgeting</div>",
    "</td></tr></table>",
    "</td></tr>",
    "<tr><td style=\"padding:28px 26px 24px;\">",
    "<div style=\"color:#3f454a;font-size:12px;font-weight:800;letter-spacing:.12em;text-transform:uppercase;\">", auth_email_escape(eyebrow), "</div>",
    "<h1 style=\"margin:8px 0 12px;color:#2f1c3d;font-size:28px;line-height:1.2;\">", auth_email_escape(title), "</h1>",
    "<p style=\"margin:0;color:#526270;font-size:16px;line-height:1.55;\">", auth_email_escape(intro), "</p>",
    button_html,
    details_html,
    "</td></tr>",
    "<tr><td style=\"padding:18px 26px;background:#fbf8fd;border-top:1px solid #d8e2e8;color:#526270;font-size:13px;line-height:1.5;\">",
    auth_email_escape(footer_note %||% "If you were not expecting this message, you can ignore it."),
    "<br><span style=\"color:#3f454a;font-weight:800;\">City of Baltimore</span>",
    "</td></tr>",
    "</table></td></tr></table></body></html>"
  )
  paste0(
    "From: ", from, "\r\n",
    "To: ", to, "\r\n",
    "Subject: ", safe_subject, "\r\n",
    "MIME-Version: 1.0\r\n",
    "Content-Type: multipart/alternative; boundary=\"", boundary, "\"\r\n\r\n",
    "--", boundary, "\r\n",
    "Content-Type: text/plain; charset=UTF-8\r\n",
    "Content-Transfer-Encoding: 8bit\r\n\r\n",
    text_body, "\r\n\r\n",
    "--", boundary, "\r\n",
    "Content-Type: text/html; charset=UTF-8\r\n",
    "Content-Transfer-Encoding: 8bit\r\n\r\n",
    html_body, "\r\n\r\n",
    "--", boundary, "--\r\n"
  )
}

auth_send_app_email <- function(email, subject, preheader, eyebrow, title, intro, button_label = NULL, button_url = NULL, detail_lines = character(), footer_note = NULL) {
  smtp <- auth_smtp_settings()
  if (is.null(smtp)) return(FALSE)
  message <- auth_build_app_email(
    from = smtp$from,
    to = email,
    subject = subject,
    preheader = preheader,
    eyebrow = eyebrow,
    title = title,
    intro = intro,
    button_label = button_label,
    button_url = button_url,
    detail_lines = detail_lines,
    footer_note = footer_note
  )
  tryCatch({
    curl::send_mail(
      mail_from = auth_bare_address(smtp$from),
      mail_rcpt = email,
      message = message,
      smtp_server = paste0("smtp://", smtp$host, ":", smtp$port),
      use_ssl = "force",
      username = smtp$username,
      password = smtp$password,
      # Never verbose: curl's SMTP trace prints the AUTH line, which would
      # leak the credential into container logs.
      verbose = FALSE
    )
    TRUE
  }, error = function(error) {
    warning(paste("Email to", email, "failed:", conditionMessage(error)))
    FALSE
  })
}

auth_send_reset_email <- function(email, link, first_time = FALSE) {
  subject <- if (first_time) "Set your Beacon password" else "Reset your Beacon password"
  title <- if (first_time) "Set your Beacon password" else "Reset your Beacon password"
  intro <- if (first_time) {
    "Welcome to Beacon. Use the secure link below to create a password for your account."
  } else {
    "We received a request to reset your Beacon password. Use the secure link below to choose a new password."
  }
  auth_send_app_email(
    email = email,
    subject = subject,
    preheader = paste0("This secure link expires in ", AUTH_TOKEN_MINUTES, " minutes."),
    eyebrow = "Account access",
    title = title,
    intro = intro,
    button_label = if (first_time) "Set password" else "Reset password",
    button_url = link,
    detail_lines = c(
      paste0("This link expires in ", AUTH_TOKEN_MINUTES, " minutes."),
      paste0("Plain link: ", auth_email_plain_url(link))
    ),
    footer_note = "If you did not request this Beacon account email, you can ignore it."
  )
}
