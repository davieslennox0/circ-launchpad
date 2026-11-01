// Circ Launchpad: logo pinning endpoint (Vercel Function, Node runtime).
// POST multipart/form-data with field "file" -> pins to IPFS via Pinata -> { uri: "ipfs://<CID>", cid }.
// The Pinata JWT lives only in the Vercel env (PINATA_JWT, Sensitive). It is never sent to the browser.
// The Origin check stops other websites, not scripts (Origin can be forged), and the per-IP limit is per server instance.
// Hard limits against abuse belong in the Vercel Firewall (rate-limit rule) and in Pinata's account limits.

import { sniff } from "../lib/image.js";

const ALLOWED_ORIGINS = new Set(["https://circ.getsarf.xyz"]);
const MAX_BYTES = 2 * 1024 * 1024;
const MAX_DIM = 4096;
const RATE = { windowMs: 10 * 60 * 1000, max: 10 }; // per IP per instance (best effort on serverless)
const hits = new Map();

function cors(origin) {
  const h = { "Vary": "Origin", "Content-Type": "application/json" };
  if (ALLOWED_ORIGINS.has(origin)) {
    h["Access-Control-Allow-Origin"] = origin;
    h["Access-Control-Allow-Methods"] = "POST, OPTIONS";
    h["Access-Control-Allow-Headers"] = "Content-Type";
    h["Access-Control-Max-Age"] = "86400";
  }
  return h;
}
const json = (status, body, origin) => new Response(JSON.stringify(body), { status, headers: cors(origin) });

function limited(ip) {
  const now = Date.now();
  const list = (hits.get(ip) || []).filter((t) => now - t < RATE.windowMs);
  if (list.length >= RATE.max) { hits.set(ip, list); return true; }
  list.push(now); hits.set(ip, list);
  if (hits.size > 5000) hits.clear();
  return false;
}

export function OPTIONS(request) {
  return new Response(null, { status: 204, headers: cors(request.headers.get("origin")) });
}

export async function GET(request) {
  return json(405, { error: "POST an image as multipart field 'file'" }, request.headers.get("origin"));
}

export async function POST(request) {
  const origin = request.headers.get("origin");
  if (!ALLOWED_ORIGINS.has(origin)) return json(403, { error: "origin not allowed" }, origin);
  const jwt = process.env.PINATA_JWT;
  if (!jwt) return json(500, { error: "pinning not configured" }, origin);
  const ip = (request.headers.get("x-forwarded-for") || "").split(",")[0].trim() || "unknown";
  if (limited(ip)) return json(429, { error: "too many uploads, try again later" }, origin);

  const len = Number(request.headers.get("content-length") || 0);
  if (len > MAX_BYTES + 64 * 1024) return json(413, { error: "max 2 MB" }, origin);

  let file;
  try {
    const form = await request.formData();
    file = form.get("file");
  } catch {
    return json(400, { error: "expected multipart/form-data with field 'file'" }, origin);
  }
  if (!file || typeof file.arrayBuffer !== "function") return json(400, { error: "missing file" }, origin);
  if (file.size > MAX_BYTES) return json(413, { error: "max 2 MB" }, origin);

  const bytes = new Uint8Array(await file.arrayBuffer());
  const img = sniff(bytes);
  if (!img) return json(415, { error: "a complete png, jpg, webp or gif only" }, origin);
  if (!img.w || !img.h || img.w > MAX_DIM || img.h > MAX_DIM) return json(422, { error: "bad image dimensions" }, origin);
  if (img.w !== img.h) return json(422, { error: `image must be square (got ${img.w}x${img.h})` }, origin);

  const out = new FormData();
  out.append("file", new Blob([bytes], { type: img.type }), `logo.${img.ext}`);
  out.append("pinataMetadata", JSON.stringify({ name: `circ-logo-${Date.now()}.${img.ext}` }));
  out.append("pinataOptions", JSON.stringify({ cidVersion: 1 }));
  let r;
  try {
    r = await fetch("https://api.pinata.cloud/pinning/pinFileToIPFS", {
      method: "POST", headers: { Authorization: `Bearer ${jwt}` }, body: out,
    });
  } catch {
    return json(502, { error: "pinning service unreachable" }, origin);
  }
  if (!r.ok) return json(502, { error: `pinning failed (${r.status})` }, origin);
  const { IpfsHash } = await r.json().catch(() => ({}));
  if (!/^b[a-z2-7]{50,}$/.test(IpfsHash || "")) return json(502, { error: "unexpected CID from pinning service" }, origin);
  return json(200, { uri: `ipfs://${IpfsHash}`, cid: IpfsHash, width: img.w, type: img.type }, origin);
}
