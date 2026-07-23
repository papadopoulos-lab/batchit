#' @keywords internal
"_PACKAGE"

# mirai injects these by NAME into the quoted `mirai::mirai()` / `everywhere()`
# expressions in stream_from_parent_and_write_files_atomically() (.consumer /
# .runner / .dev are cross-process load hints; .env is the envelope), so
# codetools sees them as free variables inside those blocks. They are not
# package globals -- declare them so the spurious "no visible binding for
# global variable" NOTE does not fire.
utils::globalVariables(c(".consumer", ".dev", ".env", ".runner"))
