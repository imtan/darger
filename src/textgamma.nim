import std/math
import pixie

type TextGammaLut* = array[256, uint8]

proc textGammaLut*(gamma: float): TextGammaLut {.noSideEffect.} =
  ## Maps linear coverage to gamma-corrected premultiplied white.
  for i in 0..255:
    result[i] = if gamma == 1.0: uint8(i)
                else: uint8(round(255 * pow(i.float / 255, 1 / gamma)))

proc applyTextGamma*(img: Image, lut: TextGammaLut) {.noSideEffect.} =
  ## Maps all four channels together, preserving premultiplied white.
  for pixel in img.data.mitems:
    pixel.r = lut[pixel.r]
    pixel.g = lut[pixel.g]
    pixel.b = lut[pixel.b]
    pixel.a = lut[pixel.a]
