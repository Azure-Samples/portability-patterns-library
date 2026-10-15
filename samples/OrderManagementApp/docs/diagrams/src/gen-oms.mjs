import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

// Diagram 1 of 2 — the BUSINESS story.
// Owns: what the app does, the continuity journey as a timeline, why failover is safe.
// Deliberately does NOT own: resource types, recipes, policy gates, protocol detail.
// Those live in the architecture diagram so the two never repeat each other.

const OUT_EXC = process.argv[2];
const OUT_SVG = process.argv[3];
const ICON_ROOT = process.argv[4];

function findFile(root, name) {
  if (!existsSync(root)) return null;
  const stack = [root];
  while (stack.length) {
    const d = stack.pop();
    for (const e of readdirSync(d)) {
      const p = path.join(d, e);
      let st; try { st = statSync(p); } catch { continue; }
      if (st.isDirectory()) stack.push(p);
      else if (e === name) return p;
    }
  }
  return null;
}
let uid = 0;
const iconCache = new Map();
function loadIcon(file) {
  if (iconCache.has(file)) return iconCache.get(file);
  const full = findFile(ICON_ROOT, file);
  if (!full) { console.warn(`  !! missing icon ${file}`); iconCache.set(file, null); return null; }
  let raw = readFileSync(full, "utf8").replace(/<\?xml[\s\S]*?\?>/g, "").replace(/<!--[\s\S]*?-->/g, "").replace(/<!DOCTYPE[\s\S]*?>/g, "");
  const attrs = (raw.match(/<svg([^>]*)>/i) || [, ""])[1];
  let vb = (attrs.match(/viewBox\s*=\s*"([^"]+)"/i) || [])[1];
  if (!vb) {
    const w = (attrs.match(/\bwidth\s*=\s*"([\d.]+)/i) || [])[1] || "24";
    const h = (attrs.match(/\bheight\s*=\s*"([\d.]+)/i) || [])[1] || "24";
    vb = `0 0 ${w} ${h}`;
  }
  let inner = raw.replace(/^[\s\S]*?<svg[^>]*>/i, "").replace(/<\/svg>\s*$/i, "");
  const pfx = `o${uid++}_`;
  inner = inner
    .replace(/id\s*=\s*"([^"]+)"/g, (_, v) => `id="${pfx}${v}"`)
    .replace(/url\(\s*#([^)\s]+)\s*\)/g, (_, v) => `url(#${pfx}${v})`)
    .replace(/(xlink:href|href)\s*=\s*"#([^"]+)"/g, (_, a, v) => `${a}="#${pfx}${v}"`)
    .replace(/<style[\s\S]*?<\/style>/gi, (b) => b.replace(/\.([A-Za-z_][\w-]*)/g, (_, n) => `.${pfx}${n}`))
    .replace(/class\s*=\s*"([^"]*)"/g, (_, v) => `class="${v.split(/\s+/).filter(Boolean).map((n) => pfx + n).join(" ")}"`);
  const rec = { vb, inner };
  iconCache.set(file, rec);
  return rec;
}

const GLYPHS = {
  user: `<circle cx="12" cy="8" r="3.6"/><path d="M4.8 20.5 a7.2 7.2 0 0 1 14.4 0"/>`,
  cube: `<path d="M12 2.5 l8.5 4.8 v9.4 L12 21.5 L3.5 16.7 V7.3 z"/><path d="M12 2.5 V12 M12 12 l8.5-4.7 M12 12 L3.5 7.3"/>`,
  queue: `<rect x="2.5" y="8" width="5.4" height="8" rx="1"/><rect x="9.3" y="8" width="5.4" height="8" rx="1"/><rect x="16.1" y="8" width="5.4" height="8" rx="1"/>`,
  bucket: `<path d="M3.5 6.5 h17 l-2 14 h-13 z"/><ellipse cx="12" cy="6.5" rx="8.5" ry="2.6"/>`,
  database: `<ellipse cx="12" cy="5.5" rx="8" ry="3"/><path d="M4 5.5 v13 a8 3 0 0 0 16 0 V5.5"/><path d="M4 12 a8 3 0 0 0 16 0"/>`,
  bolt: `<path d="M13.5 2 L4 13.5 h6 L10.5 22 L20 10.5 h-6 z"/>`,
  check: `<circle cx="12" cy="12" r="9.2"/><path d="M7.5 12.4 l3.1 3.1 L16.6 9.3"/>`,
};

const els = [];
let sc = 1;
const rnd = () => Math.floor(Math.random() * 2 ** 31) + sc++;
const BASE = () => ({ angle: 0, strokeStyle: "solid", opacity: 100, groupIds: [], frameId: null, seed: rnd(), version: 1, versionNonce: rnd(), isDeleted: false, updated: 1, link: null, locked: false });

function rect(id, x, y, w, h, stroke, bg, sw = 1) {
  const el = { ...BASE(), type: "rectangle", id, x, y, width: w, height: h, strokeColor: stroke, backgroundColor: bg, fillStyle: "solid", strokeWidth: sw, roundness: { type: 3 }, boundElements: null };
  els.push(el); return el;
}
function text(id, x, y, w, h, str, fs, align = "left") {
  els.push({ ...BASE(), type: "text", id, x, y, width: w, height: h, strokeColor: "#000000", backgroundColor: "transparent", fillStyle: "solid", strokeWidth: 1, roundness: null, boundElements: null, fontSize: fs, fontFamily: 1, text: str, originalText: str, textAlign: align, verticalAlign: "top", containerId: null, lineHeight: 1.25 });
}
function box(id, x, y, w, h, stroke, bg, str, fs = 13) {
  const r = rect(id, x, y, w, h, stroke, bg);
  const tid = `${id}_t`;
  r.boundElements = [{ type: "text", id: tid }];
  const th = Math.round(fs * 1.25 * str.split("\n").length);
  els.push({ ...BASE(), type: "text", id: tid, x: x + 8, y: y + Math.round((h - th) / 2), width: w - 16, height: th, strokeColor: "#000000", backgroundColor: "transparent", fillStyle: "solid", strokeWidth: 1, roundness: null, boundElements: null, fontSize: fs, fontFamily: 1, text: str, originalText: str, textAlign: "center", verticalAlign: "middle", containerId: id, lineHeight: 1.25 });
}
function arrow(id, x1, y1, x2, y2, stroke, sw = 2) {
  els.push({ ...BASE(), type: "arrow", id, x: x1, y: y1, width: Math.abs(x2 - x1), height: Math.abs(y2 - y1), strokeColor: stroke, backgroundColor: "transparent", fillStyle: "solid", strokeWidth: sw, roundness: { type: 2 }, boundElements: null, points: [[0, 0], [x2 - x1, y2 - y1]], lastCommittedPoint: null, startBinding: null, endBinding: null, startArrowhead: null, endArrowhead: "arrow", elbowed: false });
}

const AZ = { s: "#0078D4", b: "#CFE4FA" };
const AL = { s: "#5C2D91", b: "#E8DAEF" };
const OK = { s: "#107C10", b: "#DFF6DD" };
const WARN = { s: "#F7630C", b: "#FFF4CE" };
const NEU = { s: "#1e1e1e", b: "#F3F2F1" };
const RED = { s: "#D13438", b: "#FDE7E9" };

const ICONS = {};
const TOP_ICON = new Set();
const LEFT_ICON = new Set();

text("title", 60, 30, 1800, 75, "Order Management System — How Business Continuity Works", 30);
text("sub", 60, 112, 2000, 42, "Orders are accepted, fulfilled and recorded. When Azure public is disrupted, the same application keeps taking orders on Azure Local.", 15);

// ─────────── 1 · what the application does ───────────
rect("s1", 60, 175, 2280, 300, NEU.s, "transparent", 2);
text("s1l", 85, 190, 1400, 30, "1  ·  WHAT THE APPLICATION DOES", 14);

box("p1", 100, 250, 330, 130, NEU.s, NEU.b, "Storefront / channel\n\nCustomer places\nan order", 13);
box("p2", 490, 250, 330, 130, OK.s, OK.b, "Order Intake\n\nValidates and emits\nthe order", 13);
box("p3", 880, 250, 330, 130, OK.s, OK.b, "Order Queue\n\nDurable hand-off,\nnothing is dropped", 13);
box("p4", 1270, 250, 330, 130, OK.s, OK.b, "Order Processor\n\nFulfils the order\nand records it", 13);
box("p5a", 1700, 212, 600, 90, OK.s, OK.b, "Order Document Archive — the immutable record\nof what the customer actually ordered", 12);
box("p5b", 1700, 332, 600, 90, OK.s, OK.b, "Order Ledger — the queryable list of orders,\nby order id and status", 12);
["p1", "p2", "p3", "p4"].forEach((k) => TOP_ICON.add(k));
ICONS.p1 = { glyph: "user" }; ICONS.p2 = { glyph: "cube" };
ICONS.p3 = { glyph: "queue" }; ICONS.p4 = { glyph: "cube" };
LEFT_ICON.add("p5a"); LEFT_ICON.add("p5b");
ICONS.p5a = { glyph: "bucket" }; ICONS.p5b = { glyph: "database" };

arrow("a1", 434, 315, 486, 315, NEU.s);
arrow("a2", 824, 315, 876, 315, NEU.s);
arrow("a3", 1214, 315, 1266, 315, NEU.s);
arrow("a4", 1604, 310, 1696, 262, NEU.s);
arrow("a5", 1604, 320, 1696, 372, NEU.s);
text("s1n", 100, 432, 2150, 28, "Three dependencies, nothing exotic: somewhere to queue the order, somewhere to archive the document, somewhere to record the ledger entry.", 12);

// ─────────── 2 · the continuity journey (timeline) ───────────
rect("s2", 60, 515, 2280, 520, NEU.s, "transparent", 2);
text("s2l", 85, 530, 1400, 30, "2  ·  THE CONTINUITY JOURNEY", 14);

const PW = 500, PX = [90, 663, 1236, 1809];
const HY = 580, HH = 104, BY = 700;

box("t1h", PX[0], HY, PW, HH, AZ.s, AZ.b, "NORMAL OPERATIONS\nOrders running on Azure\n(Sovereign Public)", 14);
box("t2h", PX[1], HY, PW, HH, RED.s, RED.b, "DISRUPTION\nAzure public unavailable", 14);
box("t3h", PX[2], HY, PW, HH, OK.s, OK.b, "FAILOVER\nRedeploy from Sovereign Public Cloud\nto Sovereign Private Cloud", 12);
box("t4h", PX[3], HY, PW, HH, AL.s, AL.b, "OPERATIONS CONTINUE\nOrders running on Azure Local\n(Sovereign Private)", 14);
LEFT_ICON.add("t1h"); LEFT_ICON.add("t4h");

const capY = [BY, BY + 62, BY + 124, BY + 186];
const CW = PW - 50, CH = 54;
const capA = [
  ["Order Queue", "Azure Service Bus"],
  ["Order Archive", "Azure Blob Storage"],
  ["Order Ledger", "Azure SQL Database"],
  ["Identity", "Entra Workload Identity"],
];
const capB = [
  ["Order Queue", "RabbitMQ"],
  ["Order Archive", "Azurite"],
  ["Order Ledger", "SQL Server 2022"],
  ["Identity", "Keycloak + AD DS"],
];
const iconA = [
  { file: "10836-icon-service-Azure-Service-Bus.svg" },
  { file: "10086-icon-service-Storage-Accounts.svg" },
  { file: "10130-icon-service-SQL-Database.svg" },
  { file: "Microsoft Entra Workload ID color icon.svg" },
];
const iconB = [
  { file: "rabbitmq.svg", tint: "#FF6600" },
  { file: "10086-icon-service-Storage-Accounts.svg" },
  { file: "10132-icon-service-SQL-Server.svg" },
  { file: "keycloak-color.svg" },
];
capA.forEach((c, i) => {
  const id = `ca${i}`;
  box(id, PX[0] + 25, capY[i], CW, CH, AZ.s, AZ.b, `${c[0]}  ·  ${c[1]}`, 12);
  ICONS[id] = iconA[i]; LEFT_ICON.add(id);
});
capB.forEach((c, i) => {
  const id = `cb${i}`;
  box(id, PX[3] + 25, capY[i], CW, CH, AL.s, AL.b, `${c[0]}  ·  ${c[1]}`, 12);
  ICONS[id] = iconB[i]; LEFT_ICON.add(id);
});

box("t2b", PX[1] + 25, BY, CW, 240, RED.s, RED.b, "Managed services unreachable.\nTwo real-world triggers:\n\n1 · ACCESS DENIED — sanctions or\nconflict block the region, or the\nprovider entirely.\n\n2 · DISASTER RECOVERY — power grid\nor fibre outage, extreme weather or\nconflict. DORA-class resilience.", 12);
box("t3b", PX[2] + 25, BY, CW, 240, OK.s, OK.b, "Following Fundamental Patterns\nguidance for Sovereign Private Cloud\nwith Azure Local, customers build\nadaptive apps and redeploy when\ndisruption hits.\n\nSame container images.\nSame application definition.\nOnly the infrastructure changes —\nwith some degradation.", 12);
TOP_ICON.add("t2b"); ICONS.t2b = { glyph: "bolt" };

arrow("ta1", 595, 820, 658, 820, NEU.s, 3);
arrow("ta2", 1168, 820, 1231, 820, NEU.s, 3);
arrow("ta3", 1741, 820, 1804, 820, NEU.s, 3);
box("s2n", 90, 945, 2220, 60, WARN.s, WARN.b, "NOT COVERED HERE: DATA MIGRATION\nThis shows application and infrastructure redeployment for business continuity. Moving the order data is separate work — guidelines to follow.", 14);

// ─────────── 3 · why the failover is safe ───────────
rect("s3", 60, 1075, 2280, 310, OK.s, "transparent", 2);
text("s3l", 85, 1090, 1600, 30, "3  ·  WHY THE FAILOVER IS SAFE FOR ORDERS", 14);
const cw = 530;
box("g1", 90, 1135, cw, 225, OK.s, OK.b, "ORDERS KEEP FLOWING\n\nIntake and fulfilment continue on\nthe same container images. No code\nchange, no schema change, no\nre-release. The platform re-binds\nthe dependencies, not the app.", 12);
box("g2", 650, 1135, cw, 225, OK.s, OK.b, "NO DUPLICATE ORDERS\n\nThe ledger write is a MERGE on\norder id, so a message redelivered\nduring the cutover can never create\na second order — exactly when\nredelivery is most likely.", 12);
box("g3", 1210, 1135, cw, 225, OK.s, OK.b, "NO ORPHAN RECORDS\n\nThe order document is archived\nbefore the ledger row is written,\nso every ledger row always points\nat an archive that exists.", 12);
box("g4", 1770, 1135, cw, 225, WARN.s, WARN.b, "THERE ARE TRADE-OFFS\n\nDurability, scale and the identity\nmodel all change underneath.\n\nOrder data replication between\nenvironments — guidance to follow.\n\nSee the architecture diagram for\nwhat degrades and why.", 12);
TOP_ICON.add("g1"); TOP_ICON.add("g2"); TOP_ICON.add("g3");
ICONS.g1 = { glyph: "check" }; ICONS.g2 = { glyph: "check" }; ICONS.g3 = { glyph: "check" };

// ─────────── write ───────────
writeFileSync(OUT_EXC, JSON.stringify({ type: "excalidraw", version: 2, source: "claude", elements: els, appState: { viewBackgroundColor: "#ffffff", gridSize: null }, files: {} }, null, 2));

const PAD = 40;
const maxX = Math.max(...els.filter((e) => e.type !== "text").map((e) => e.x + e.width));
const maxY = Math.max(...els.filter((e) => e.type !== "text").map((e) => e.y + e.height));
const W = maxX + PAD, H = maxY + PAD;
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function renderIcon(spec, cx, cy, size, fallback) {
  const sz = size * (spec.scale || 1);
  if (spec.glyph) {
    const s = sz / 24;
    return `<g transform="translate(${(cx - sz / 2).toFixed(1)} ${(cy - sz / 2).toFixed(1)}) scale(${s.toFixed(3)})" fill="none" stroke="${fallback}" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${GLYPHS[spec.glyph]}</g>`;
  }
  const ic = loadIcon(spec.file);
  if (!ic) return "";
  const tint = spec.tint ? ` fill="${spec.tint}"` : "";
  return `<svg x="${(cx - sz / 2).toFixed(1)}" y="${(cy - sz / 2).toFixed(1)}" width="${sz.toFixed(1)}" height="${sz.toFixed(1)}" viewBox="${ic.vb}" preserveAspectRatio="xMidYMid meet" overflow="visible"${tint}>${ic.inner}</svg>`;
}

const out = [];
out.push(`<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" font-family="Segoe UI, Helvetica, Arial, sans-serif">`);
out.push(`<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="context-stroke"/></marker></defs>`);
out.push(`<rect width="${W}" height="${H}" fill="#ffffff"/>`);

const HEADER_LOGO = { t1h: { file: "azure-brand.svg" }, t4h: { file: "033745116-icon-service-Azure-Local.svg" } };

for (const e of els.filter((x) => x.type === "rectangle")) {
  const fill = e.backgroundColor === "transparent" ? "none" : e.backgroundColor;
  out.push(`<rect x="${e.x}" y="${e.y}" width="${e.width}" height="${e.height}" rx="10" ry="10" fill="${fill}" stroke="${e.strokeColor}" stroke-width="${e.strokeWidth}"/>`);
  const spec = HEADER_LOGO[e.id] || ICONS[e.id];
  if (spec) {
    if (TOP_ICON.has(e.id)) out.push(renderIcon(spec, e.x + e.width / 2, e.y + 28, 28, e.strokeColor));
    else out.push(renderIcon(spec, e.x + 32, e.y + e.height / 2, HEADER_LOGO[e.id] ? 30 : 24, e.strokeColor));
  }
}
for (const e of els.filter((x) => x.type === "arrow")) {
  const [p0, p1] = e.points;
  out.push(`<line x1="${e.x + p0[0]}" y1="${e.y + p0[1]}" x2="${e.x + p1[0]}" y2="${e.y + p1[1]}" stroke="${e.strokeColor}" stroke-width="${e.strokeWidth}" marker-end="url(#ah)"/>`);
}

for (const e of els.filter((x) => x.type === "text")) {
  const lines = e.text.split("\n");
  const lh = e.fontSize * 1.25;
  const bold = e.fontSize >= 18 ? ' font-weight="600"' : "";
  if (e.containerId) {
    const c = els.find((x) => x.id === e.containerId);
    const shift = TOP_ICON.has(c.id) ? 16 : 0;
    const cx = LEFT_ICON.has(c.id) ? c.x + c.width / 2 + 24 : c.x + c.width / 2;
    let y = c.y + c.height / 2 - (lines.length * lh) / 2 + e.fontSize * 0.95 + shift;
    for (const ln of lines) { out.push(`<text x="${cx}" y="${y.toFixed(1)}" font-size="${e.fontSize}" fill="#000000" text-anchor="middle"${bold}>${esc(ln)}</text>`); y += lh; }
  } else {
    let y = e.y + e.fontSize * 0.95;
    for (const ln of lines) { out.push(`<text x="${e.x}" y="${y.toFixed(1)}" font-size="${e.fontSize}" fill="#000000" text-anchor="start"${bold}>${esc(ln)}</text>`); y += lh; }
  }
}
out.push("</svg>");
writeFileSync(OUT_SVG, out.join("\n"));
console.log(`wrote ${OUT_EXC} (${els.length} elements)`);
console.log(`wrote ${OUT_SVG} (${W}x${H}) — ${iconCache.size} icons`);
