import { readFileSync, writeFileSync } from "node:fs";

// Renders the .excalidraw model to SVG, optionally with generic vector glyphs.
// Glyphs are plain geometry authored here — no third-party brand logos — so there
// is no trademark/licensing exposure and the size cost stays in the low KB.

const doc = JSON.parse(readFileSync(process.argv[2], "utf8"));
const out = process.argv[3];
const WITH_ICONS = process.argv[4] === "--icons";
const els = doc.elements;

const PAD = 40;
const maxX = Math.max(...els.filter((e) => e.type !== "text").map((e) => e.x + e.width));
const maxY = Math.max(...els.filter((e) => e.type !== "text").map((e) => e.y + e.height));
const W = maxX + PAD;
const H = maxY + PAD;

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// ---- glyphs, authored on a 24x24 grid ----
const GLYPHS = {
  cube: `<path d="M12 2.5 l8.5 4.8 v9.4 L12 21.5 L3.5 16.7 V7.3 z"/><path d="M12 2.5 V12 M12 12 l8.5-4.7 M12 12 L3.5 7.3"/>`,
  gear:
    `<circle cx="12" cy="12" r="3.6"/>` +
    Array.from({ length: 8 }, (_, i) => {
      const a = (i * Math.PI) / 4;
      const x1 = 12 + Math.cos(a) * 6.2, y1 = 12 + Math.sin(a) * 6.2;
      const x2 = 12 + Math.cos(a) * 9.2, y2 = 12 + Math.sin(a) * 9.2;
      return `<line x1="${x1.toFixed(1)}" y1="${y1.toFixed(1)}" x2="${x2.toFixed(1)}" y2="${y2.toFixed(1)}"/>`;
    }).join(""),
  database: `<ellipse cx="12" cy="5.5" rx="8" ry="3"/><path d="M4 5.5 v13 a8 3 0 0 0 16 0 V5.5"/><path d="M4 12 a8 3 0 0 0 16 0"/>`,
  bucket: `<path d="M3.5 6.5 h17 l-2 14 h-13 z"/><ellipse cx="12" cy="6.5" rx="8.5" ry="2.6"/>`,
  queue: `<rect x="2.5" y="8" width="5.4" height="8" rx="1"/><rect x="9.3" y="8" width="5.4" height="8" rx="1"/><rect x="16.1" y="8" width="5.4" height="8" rx="1"/>`,
  user: `<circle cx="12" cy="8" r="3.6"/><path d="M4.8 20.5 a7.2 7.2 0 0 1 14.4 0"/>`,
  key: `<circle cx="7.5" cy="12" r="3.6"/><path d="M11.1 12 H21 M17.5 12 v3.4 M20.5 12 v3.4"/>`,
  cert: `<rect x="2.5" y="3.5" width="18" height="11.5" rx="1.2"/><line x1="5.5" y1="7.5" x2="14" y2="7.5"/><line x1="5.5" y1="11" x2="11.5" y2="11"/><circle cx="17" cy="17" r="3.4"/><path d="M14.9 19.4 L14.4 23 L17 21.4 L19.6 23 L19.1 19.4"/>`,
  tree: `<rect x="8.8" y="2.5" width="6.4" height="4.2" rx="1"/><rect x="1.5" y="16" width="6.4" height="4.2" rx="1"/><rect x="8.8" y="16" width="6.4" height="4.2" rx="1"/><rect x="16.1" y="16" width="6.4" height="4.2" rx="1"/><path d="M12 6.7 v4.1 M4.7 16 v-2.7 h14.6 v2.7 M12 13.3 v2.7"/>`,
  registry: `<rect x="2.5" y="13" width="7.2" height="7.2" rx="0.8"/><rect x="11.3" y="13" width="7.2" height="7.2" rx="0.8"/><rect x="6.9" y="4.6" width="7.2" height="7.2" rx="0.8"/>`,
  cloud: `<path d="M7 19 h9.6 a4.3 4.3 0 0 0 0-8.6 a5.8 5.8 0 0 0-11-1.6 A4.4 4.4 0 0 0 7 19 z"/>`,
  rack: `<rect x="4.5" y="2.8" width="15" height="18.4" rx="1.2"/><line x1="4.5" y1="8.9" x2="19.5" y2="8.9"/><line x1="4.5" y1="15.1" x2="19.5" y2="15.1"/><circle cx="7.8" cy="5.9" r="1"/><circle cx="7.8" cy="12" r="1"/><circle cx="7.8" cy="18.1" r="1"/>`,
};

// box id -> glyph
const ICONS = {
  A_b1: "cube", A_b2: "cube", A_b3: "gear",
  A_s1: "database", A_s2: "bucket", A_s3: "queue",
  A_i1: "user", A_i2: "key", A_i3: "registry",
  B_b1: "cube", B_b2: "cube", B_b3: "gear",
  B_s1: "database", B_s2: "bucket", B_s3: "queue",
  B_i1: "user", B_i2: "tree", B_i3: "cert",
};

function glyph(name, cx, cy, size, color) {
  const s = size / 24;
  return (
    `<g transform="translate(${(cx - size / 2).toFixed(1)} ${(cy - size / 2).toFixed(1)}) scale(${s.toFixed(3)})" ` +
    `fill="none" stroke="${color}" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${GLYPHS[name]}</g>`
  );
}

const ICON_SIZE = 26;
const TEXT_SHIFT = 15;

const parts = [];
parts.push(
  `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" font-family="Segoe UI, Helvetica, Arial, sans-serif">`
);
parts.push(
  `<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="context-stroke"/></marker></defs>`
);
parts.push(`<rect width="${W}" height="${H}" fill="#ffffff"/>`);

for (const e of els.filter((x) => x.type === "rectangle")) {
  const fill = e.backgroundColor === "transparent" ? "none" : e.backgroundColor;
  parts.push(
    `<rect x="${e.x}" y="${e.y}" width="${e.width}" height="${e.height}" rx="10" ry="10" fill="${fill}" stroke="${e.strokeColor}" stroke-width="${e.strokeWidth}"/>`
  );
  if (WITH_ICONS && ICONS[e.id]) {
    parts.push(glyph(ICONS[e.id], e.x + e.width / 2, e.y + 26, ICON_SIZE, e.strokeColor));
  }
}

for (const e of els.filter((x) => x.type === "arrow")) {
  const [p0, p1] = e.points;
  parts.push(
    `<line x1="${e.x + p0[0]}" y1="${e.y + p0[1]}" x2="${e.x + p1[0]}" y2="${e.y + p1[1]}" stroke="${e.strokeColor}" stroke-width="${e.strokeWidth}" marker-end="url(#ah)"/>`
  );
}

// column header glyphs
if (WITH_ICONS) {
  const ah = els.find((x) => x.id === "A_h");
  const bh = els.find((x) => x.id === "B_h");
  if (ah) parts.push(glyph("cloud", ah.x - 26, ah.y + 17, 28, "#0078D4"));
  if (bh) parts.push(glyph("rack", bh.x - 26, bh.y + 17, 28, "#5C2D91"));
}

for (const e of els.filter((x) => x.type === "text")) {
  const lines = e.text.split("\n");
  const lh = e.fontSize * 1.25;
  const bold = e.fontSize >= 20 ? ' font-weight="600"' : "";
  if (e.containerId) {
    const c = els.find((x) => x.id === e.containerId);
    const shift = WITH_ICONS && ICONS[c.id] ? TEXT_SHIFT : 0;
    const cx = c.x + c.width / 2;
    const total = lines.length * lh;
    let y = c.y + c.height / 2 - total / 2 + e.fontSize * 0.95 + shift;
    for (const ln of lines) {
      parts.push(`<text x="${cx}" y="${y.toFixed(1)}" font-size="${e.fontSize}" fill="#000000" text-anchor="middle"${bold}>${esc(ln)}</text>`);
      y += lh;
    }
  } else {
    let y = e.y + e.fontSize * 0.95;
    for (const ln of lines) {
      parts.push(`<text x="${e.x}" y="${y.toFixed(1)}" font-size="${e.fontSize}" fill="#000000" text-anchor="start"${bold}>${esc(ln)}</text>`);
      y += lh;
    }
  }
}

parts.push("</svg>");
writeFileSync(out, parts.join("\n"));
console.log(`wrote ${out} (${W}x${H}) icons=${WITH_ICONS}`);
