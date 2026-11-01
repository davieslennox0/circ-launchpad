// Identifies an image from its bytes and checks it is one complete file: right header, right ending, nothing appended.
// Reads the pixel size from the header. Doesn't decode pixels, so it can't prove the picture itself is valid.
export function sniff(b) {
  const u32be = (o) => (b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3]) >>> 0;
  const u32le = (o) => (b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24) >>> 0;
  const u16le = (o) => b[o] | b[o + 1] << 8;
  const u24le = (o) => b[o] | b[o + 1] << 8 | b[o + 2] << 16;
  const ascii = (o, n) => String.fromCharCode(...b.slice(o, o + n));
  const end = b.length;

  // PNG: signature, IHDR first, IEND exactly last
  if (end >= 45 && b[0] === 0x89 && ascii(1, 3) === "PNG" && b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a) {
    if (ascii(12, 4) !== "IHDR" || ascii(end - 8, 4) !== "IEND") return null;
    return { type: "image/png", ext: "png", w: u32be(16), h: u32be(20) };
  }
  // GIF: version, trailer byte last
  if (end > 13 && (ascii(0, 6) === "GIF87a" || ascii(0, 6) === "GIF89a")) {
    if (b[end - 1] !== 0x3b) return null;
    return { type: "image/gif", ext: "gif", w: u16le(6), h: u16le(8) };
  }
  // WebP: the RIFF size must account for the whole file
  if (end > 30 && ascii(0, 4) === "RIFF" && ascii(8, 4) === "WEBP") {
    if (u32le(4) + 8 !== end) return null;
    const chunk = ascii(12, 4);
    if (chunk === "VP8X") return { type: "image/webp", ext: "webp", w: u24le(24) + 1, h: u24le(27) + 1 };
    if (chunk === "VP8L") {
      const v = u32le(21);
      return { type: "image/webp", ext: "webp", w: (v & 0x3fff) + 1, h: ((v >>> 14) & 0x3fff) + 1 };
    }
    if (chunk === "VP8 ") return { type: "image/webp", ext: "webp", w: u16le(26) & 0x3fff, h: u16le(28) & 0x3fff };
    return null;
  }
  // JPEG: end-of-image marker last, size from the first frame header
  if (end > 4 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) {
    if (b[end - 2] !== 0xff || b[end - 1] !== 0xd9) return null;
    let o = 2;
    while (o + 9 < end) {
      if (b[o] !== 0xff) { o++; continue; }
      const m = b[o + 1];
      if (m === 0xd8 || m === 0x01 || (m >= 0xd0 && m <= 0xd7)) { o += 2; continue; }
      const len = b[o + 2] << 8 | b[o + 3];
      if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) {
        return { type: "image/jpeg", ext: "jpg", h: b[o + 5] << 8 | b[o + 6], w: b[o + 7] << 8 | b[o + 8] };
      }
      o += 2 + len;
    }
  }
  return null;
}
