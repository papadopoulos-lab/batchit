# Generates man/figures/logo.png. Run from the package root:
#   Rscript dev/logo.R
#
# R packages, none of which is a batchit dependency (this script is in dev/ and
# is .Rbuildignore'd, so it never ships):
#   pak::pak(c("hexSticker", "ggplot2", "data.table"))
#
# hexSticker pulls in ggimage -> magick, which links against the system
# ImageMagick C++ library. Install that first or `library(hexSticker)` fails at
# dyn.load:
#   sudo apt install -y libmagick++-dev      # Debian/Ubuntu
#   brew install imagemagick@6               # macOS
# The exact missing-object message names whichever libMagick++ SONAME your
# `magick` binary was built against; it is not a fixed string.
#
# The motif is what batchit does: item bars laid across worker lanes, each lane
# packed independently, so the lanes end ragged rather than aligned. Items are
# dispatched as workers free up, not in lockstep rounds.

library(hexSticker)
library(ggplot2)
library(data.table)

CFG <- list(
  bg      = "#16232E",
  border  = "#4FB3A9",
  bar     = "#4FB3A9",
  bar_alt = "#7FD3CA",
  text    = "#EAF4F3",
  out     = "man/figures/logo.png"
)

# One row per dispatched item. `lane` is the worker, `t0`/`t1` its span. The
# gaps between items keep the individual items visible, and the lanes stop at
# different times because a worker takes the next item as soon as it is free.
# The gaps must clear the round line caps, which each extend half a linewidth
# past the endpoint; too small a gap and the lane renders as one unbroken bar.
d <- data.table(
  lane = c(1, 1, 1, 2, 2, 3, 3, 3),
  t0   = c(0.00, 2.40, 4.10, 0.00, 3.15, 0.00, 1.50, 3.75),
  t1   = c(2.00, 3.70, 5.30, 2.75, 6.00, 1.10, 3.35, 4.85)
)
d[, alt := seq_len(.N) %% 2 == 0, by = .(lane)]

q <- ggplot(d, aes(y = lane, x = t0, xend = t1, yend = lane, colour = alt))
q <- q + geom_segment(linewidth = 2.7, lineend = "round")
q <- q + scale_colour_manual(values = c(`FALSE` = CFG$bar, `TRUE` = CFG$bar_alt))
q <- q + scale_y_reverse()
q <- q + expand_limits(x = c(-0.35, 6.35))
q <- q + theme_void()
q <- q + theme(legend.position = "none")

sticker(
  q,
  package  = "batchit",
  p_size   = 20,
  p_y      = 1.44,
  p_color  = CFG$text,
  p_family = "sans",
  s_x      = 1.0,
  s_y      = 0.86,
  s_width  = 1.38,
  s_height = 0.74,
  h_fill   = CFG$bg,
  h_color  = CFG$border,
  h_size   = 1.5,
  dpi      = 600,
  filename = CFG$out
)
