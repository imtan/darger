## Extra left margin for a centred writing column.
proc olivettiMargin*(paneWidth, gutter, bodyWidth: int): int =
  max(0, (paneWidth - gutter - bodyWidth) div 2)
