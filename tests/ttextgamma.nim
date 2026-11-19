import pixie
import ../src/textgamma

for gamma in [1.0, 2.0, 3.0]:
  let lut = textGammaLut(gamma)
  doAssert lut[0] == 0
  doAssert lut[255] == 255
  for i in 1..255: doAssert lut[i] >= lut[i - 1]

let identity = textGammaLut(1.0)
for i in 0..255: doAssert identity[i] == uint8(i)

let lut = textGammaLut(2.0)
doAssert lut[64] == 128
let img = newImage(3, 1)
for i, coverage in [0'u8, 64'u8, 255'u8]:
  img.data[i] = ColorRGBX(r: coverage, g: coverage, b: coverage, a: coverage)
img.applyTextGamma(identity)
doAssert img.data[1] == ColorRGBX(r: 64, g: 64, b: 64, a: 64)
img.applyTextGamma(lut)
for i, coverage in [0'u8, 128'u8, 255'u8]:
  doAssert img.data[i] == ColorRGBX(r: coverage, g: coverage, b: coverage, a: coverage)

echo "text gamma: ok"
