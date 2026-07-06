args <- commandArgs(trailingOnly = TRUE)

arg_value <- function(name, default) {
  idx <- match(name, args)
  if (is.na(idx) || idx == length(args)) return(default)
  args[[idx + 1L]]
}

cmd_args <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", cmd_args, value = TRUE)
script_path <- if (length(file_arg)) sub("^--file=", "", file_arg[[1]]) else file.path("scripts", "run_app.R")
repo_root <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/", mustWork = TRUE)
setwd(repo_root)

host <- arg_value("--host", "127.0.0.1")
port <- as.integer(arg_value("--port", "3841"))

if (is.na(port)) stop("Port must be a number.")

message(sprintf("Starting Beacon Shiny app at http://%s:%s/", host, port))
shiny::runApp(repo_root, host = host, port = port, launch.browser = FALSE)
