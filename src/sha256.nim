## SHA-256 with unsigned arithmetic, including debug builds.
import std/strutils

const k = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32, 0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32, 0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32, 0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32, 0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32, 0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32, 0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32, 0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32, 0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc rotr(x: uint32, n: int): uint32 = (x shr n) or (x shl (32 - n))

proc sha256Hex*(data: string): string =
  var h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  let length = ((data.len + 9 + 63) div 64) * 64
  let bits = data.len.uint64 * 8
  for offset in countup(0, length - 1, 64):
    var w: array[64, uint32]
    for j in 0..<64:
      let at = offset + j
      let b = if at < data.len: data[at].uint32
              elif at == data.len: 128'u32
              elif at >= length - 8: uint32((bits shr ((length - 1 - at) * 8)) and 255)
              else: 0'u32
      w[j div 4] = (w[j div 4] shl 8) or b
    for j in 16..<64:
      let a = w[j - 15]
      let b = w[j - 2]
      w[j] = w[j - 16] + (rotr(a, 7) xor rotr(a, 18) xor (a shr 3)) +
        w[j - 7] + (rotr(b, 17) xor rotr(b, 19) xor (b shr 10))
    var v = h
    for j in 0..<64:
      let t = v[7] + (rotr(v[4], 6) xor rotr(v[4], 11) xor rotr(v[4], 25)) +
        ((v[4] and v[5]) xor (not v[4] and v[6])) + k[j] + w[j]
      let s = (rotr(v[0], 2) xor rotr(v[0], 13) xor rotr(v[0], 22)) +
        ((v[0] and v[1]) xor (v[0] and v[2]) xor (v[1] and v[2]))
      for j in countdown(7, 1): v[j] = v[j - 1]
      v[4] += t
      v[0] = t + s
    for j in 0..<8: h[j] += v[j]
  for word in h: result.add toHex(word, 8).toLowerAscii
