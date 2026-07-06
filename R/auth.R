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
AUTH_MAX_FAILURES <- 5L
AUTH_LOCKOUT_MINUTES <- 15L

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
    "SELECT agency_id, agency_role FROM access.user_agency_access WHERE user_id = $1",
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

auth_smtp_configured <- function() nzchar(Sys.getenv("SMTP_HOST"))

# Demo-only escape hatch: with no SMTP configured, the reset link can be shown
# on screen instead of emailed. Never enable outside local/demo environments —
# it lets anyone claim any account.
auth_dev_links_enabled <- function() tolower(Sys.getenv("AUTH_DEV_LINKS")) %in% c("true", "1", "yes")

auth_send_reset_email <- function(email, link, first_time = FALSE) {
  if (!auth_smtp_configured()) return(FALSE)
  from <- Sys.getenv("SMTP_FROM", "performance@baltimorecity.gov")
  subject <- if (first_time) "Set your Beacon password" else "Reset your Beacon password"
  message <- paste0(
    "From: ", from, "\r\n",
    "To: ", email, "\r\n",
    "Subject: ", subject, "\r\n\r\n",
    "Use this link within ", AUTH_TOKEN_MINUTES, " minutes to choose your Beacon password:\r\n\r\n",
    link, "\r\n\r\n",
    "If you did not request this, you can ignore this message.\r\n"
  )
  tryCatch({
    curl::send_mail(
      mail_from = from,
      mail_rcpt = email,
      message = message,
      smtp_server = paste0("smtp://", Sys.getenv("SMTP_HOST"), ":", Sys.getenv("SMTP_PORT", "587")),
      use_ssl = "force",
      username = Sys.getenv("SMTP_USER"),
      password = Sys.getenv("SMTP_PASSWORD")
    )
    TRUE
  }, error = function(error) {
    warning(paste("Password email to", email, "failed:", conditionMessage(error)))
    FALSE
  })
}
