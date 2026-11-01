import test from "node:test";
import assert from "node:assert";
import { sniff } from "../../pin/lib/image.js";

const be32 = (n) => [n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
function png(w, h, extra = []) {
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  const ihdr = [0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, ...be32(w), ...be32(h), 8, 6, 0, 0, 0, 0, 0, 0, 0];
  const iend = [0, 0, 0, 0, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82];
  return Uint8Array.from([...sig, ...ihdr, ...iend, ...extra]);
}
const gif = (w, h, last = 0x3b) => Uint8Array.from([...Buffer.from("GIF89a"), w & 255, w >> 8, h & 255, h >> 8, 0, 0, 0, 1, 2, 3, last]);
function jpeg(w, h, last = 0xd9) {
  return Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 0, 4, 1, 2, 0xff, 0xc0, 0, 11, 8, h >> 8, h & 255, w >> 8, w & 255, 1, 1, 1, 0, 0xff, last]);
}
function webp(w, h, pad = 0) {
  const body = [...Buffer.from("WEBPVP8X"), 10, 0, 0, 0, 0, 0, 0, 0, (w - 1) & 255, (w - 1) >> 8, 0, (h - 1) & 255, (h - 1) >> 8, 0, 0, 0, 0, 0, 0, 0];
  const size = body.length;
  return Uint8Array.from([...Buffer.from("RIFF"), size & 255, size >> 8, 0, 0, ...body, ...new Array(pad).fill(0)]);
}

test("accepts complete files and reads their size", () => {
  assert.deepEqual([sniff(png(64, 64))].map((r) => [r.type, r.w, r.h]), [["image/png", 64, 64]]);
  assert.deepEqual([sniff(gif(32, 32))].map((r) => [r.type, r.w, r.h]), [["image/gif", 32, 32]]);
  assert.deepEqual([sniff(jpeg(500, 500))].map((r) => [r.type, r.w, r.h]), [["image/jpeg", 500, 500]]);
  assert.deepEqual([sniff(webp(100, 100))].map((r) => [r.type, r.w, r.h]), [["image/webp", 100, 100]]);
  assert.deepEqual([sniff(png(80, 64))].map((r) => [r.w, r.h]), [[80, 64]], "non-square is reported for the endpoint to reject");
});

test("rejects anything else, and files with data hidden after the image", () => {
  assert.equal(sniff(Buffer.from("hello world, this is not an image at all, not even close")), null);
  assert.equal(sniff(new Uint8Array(0)), null);
  assert.equal(sniff(png(64, 64, [1, 2, 3, 4])), null, "bytes after IEND");
  assert.equal(sniff(gif(32, 32, 0x00)), null, "no GIF trailer");
  assert.equal(sniff(jpeg(500, 500, 0x00)), null, "no JPEG end marker");
  assert.equal(sniff(webp(100, 100, 8)), null, "bytes beyond the RIFF size");
  assert.equal(sniff(Buffer.from("<svg xmlns='http://www.w3.org/2000/svg' onload='alert(1)'></svg>")), null, "SVG can carry script");
});
