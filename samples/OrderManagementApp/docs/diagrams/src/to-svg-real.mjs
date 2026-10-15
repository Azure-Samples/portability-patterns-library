import { readFileSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";

// Renders the .excalidraw model to SVG using official product icons.
//   Azure Architecture Icons (V24) and Microsoft Entra architecture icons are used
//   under Microsoft's stated terms: permitted in architectural diagrams and
//   documentation. Icons are scaled uniformly inside a nested <svg> viewBox so they
//   are never cropped, flipped, rotated or distorted, and every box carries the
//   product name next to the icon as Microsoft recommends.
//   RabbitMQ and Keycloak marks come from the Simple Icons collection (CC0).
//   Components with no official mark (our own workers, Radius, on-prem AD DS,
//   AD CS) keep neutral geometry rather than borrowing an unrelated product icon.

const doc = JSON.parse(readFileSync(process.argv[2], "utf8"));
const out = process.argv[3];
const ICON_ROOT = process.argv[4];
const els = doc.elements;

const AZ_DIR = path.join(ICON_ROOT, "x", "Azure_Public_Service_Icons", "Icons");
const ENTRA_DIR = path.join(ICON_ROOT, "e");
const TP_DIR = path.join(ICON_ROOT, "tp");

// ---- locate a file by name anywhere under a root ----
import { readdirSync, statSync } from "node:fs";
function findFile(root, name) {
  if (!existsSync(root)) return null;
  const stack = [root];
  while (stack.length) {
    const d = stack.pop();
    for (const entry of readdirSync(d)) {
      const p = path.join(d, entry);
      let st;
      try { st = statSync(p); } catch { continue; }
      if (st.isDirectory()) stack.push(p);
      else if (entry === name) return p;
    }
  }
  return null;
}

let uid = 0;
const cache = new Map();
function loadIcon(file) {
  if (cache.has(file)) return cache.get(file);
  const full =
    findFile(ICON_ROOT, file);
  if (!full) { console.warn(`  !! icon not found: ${file}`); cache.set(file, null); return null; }

  let raw = readFileSync(full, "utf8")
    .replace(/<\?xml[\s\S]*?\?>/g, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<!DOCTYPE[\s\S]*?>/g, "");

  const open = raw.match(/<svg([^>]*)>/i);
  const attrs = open ? open[1] : "";
  let vb = (attrs.match(/viewBox\s*=\s*"([^"]+)"/i) || [])[1];
  if (!vb) {
    const w = (attrs.match(/\bwidth\s*=\s*"([\d.]+)/i) || [])[1] || "24";
    const h = (attrs.match(/\bheight\s*=\s*"([\d.]+)/i) || [])[1] || "24";
    vb = `0 0 ${w} ${h}`;
  }
  let inner = raw.replace(/^[\s\S]*?<svg[^>]*>/i, "").replace(/<\/svg>\s*$/i, "");

  // namespace internal ids so gradients/clip-paths from different icons never collide
  const pfx = `i${uid++}_`;
  inner = inner
    .replace(/id\s*=\s*"([^"]+)"/g, (_, v) => `id="${pfx}${v}"`)
    .replace(/url\(\s*#([^)\s]+)\s*\)/g, (_, v) => `url(#${pfx}${v})`)
    .replace(/(xlink:href|href)\s*=\s*"#([^"]+)"/g, (_, a, v) => `${a}="#${pfx}${v}"`);

  // namespace CSS classes too — SVG <style> is document-global, so icons that ship
  // a stylesheet (CNCF artwork uses .cls-1, .cls-2 …) would otherwise restyle others
  inner = inner
    .replace(/<style[\s\S]*?<\/style>/gi, (block) =>
      block.replace(/\.([A-Za-z_][\w-]*)/g, (_, n) => `.${pfx}${n}`)
    )
    .replace(/class\s*=\s*"([^"]*)"/g, (_, v) =>
      `class="${v.split(/\s+/).filter(Boolean).map((n) => pfx + n).join(" ")}"`
    );

  const rec = { vb, inner };
  cache.set(file, rec);
  return rec;
}

// ---- neutral geometry for components with no official mark ----
const GLYPHS = {
  cube: `<path d="M12 2.5 l8.5 4.8 v9.4 L12 21.5 L3.5 16.7 V7.3 z"/><path d="M12 2.5 V12 M12 12 l8.5-4.7 M12 12 L3.5 7.3"/>`,
  gear:
    `<circle cx="12" cy="12" r="3.6"/>` +
    Array.from({ length: 8 }, (_, i) => {
      const a = (i * Math.PI) / 4;
      return `<line x1="${(12 + Math.cos(a) * 6.2).toFixed(1)}" y1="${(12 + Math.sin(a) * 6.2).toFixed(1)}" x2="${(12 + Math.cos(a) * 9.2).toFixed(1)}" y2="${(12 + Math.sin(a) * 9.2).toFixed(1)}"/>`;
    }).join(""),
  tree: `<rect x="8.8" y="2.5" width="6.4" height="4.2" rx="1"/><rect x="1.5" y="16" width="6.4" height="4.2" rx="1"/><rect x="8.8" y="16" width="6.4" height="4.2" rx="1"/><rect x="16.1" y="16" width="6.4" height="4.2" rx="1"/><path d="M12 6.7 v4.1 M4.7 16 v-2.7 h14.6 v2.7 M12 13.3 v2.7"/>`,
  cert: `<rect x="2.5" y="3.5" width="18" height="11.5" rx="1.2"/><line x1="5.5" y1="7.5" x2="14" y2="7.5"/><line x1="5.5" y1="11" x2="11.5" y2="11"/><circle cx="17" cy="17" r="3.4"/><path d="M14.9 19.4 L14.4 23 L17 21.4 L19.6 23 L19.1 19.4"/>`,
};

const AZURE_SQL = "10130-icon-service-SQL-Database.svg";
const STORAGE = "10086-icon-service-Storage-Accounts.svg";
const SBUS = "10836-icon-service-Azure-Service-Bus.svg";
const ACR = "10105-icon-service-Container-Registries.svg";
const SQLSRV = "10132-icon-service-SQL-Server.svg";
const AKS = "10023-icon-service-Kubernetes-Services.svg";
const ARCK8S = "01088-icon-service-Arc-Kubernetes.svg";
const AZLOCAL = "033745116-icon-service-Azure-Local.svg";
const POLICY = "10316-icon-service-Policy.svg";
const ARC = "00756-icon-service-Azure-Arc.svg";
const ENTRA_ID = "Microsoft Entra ID color icon.svg";
const ENTRA_WI = "Microsoft Entra Workload ID color icon.svg";
const RADIUS = "radius.svg";
// the CNCF Radius mark is inset inside its 903-unit canvas, so it needs a
// larger box to read at the same optical size as the Azure icons
const RADIUS_SPEC = { file: RADIUS, scale: 1.6 };

// box id -> { file } official icon, or { glyph, color } neutral geometry
const MAP = {
  A_b1: { glyph: "cube" }, A_b2: { glyph: "cube" }, A_b3: RADIUS_SPEC,
  A_s1: { file: AZURE_SQL }, A_s2: { file: STORAGE }, A_s3: { file: SBUS },
  A_i1: { file: ENTRA_ID }, A_i2: { file: ENTRA_WI }, A_i3: { file: ACR },
  B_b1: { glyph: "cube" }, B_b2: { glyph: "cube" }, B_b3: RADIUS_SPEC,
  B_s1: { file: SQLSRV }, B_s2: { file: STORAGE },
  B_s3: { file: "rabbitmq.svg", tint: "#FF6600" },
  B_i1: { file: "keycloak-color.svg" },
  B_i2: { glyph: "tree" }, B_i3: { glyph: "cert" },
};
// wide boxes: icon sits left of the centered label
const MAP_LEFT = { A_gov: { file: POLICY }, B_gov: { file: ARC } };
// sub-container labels
const MAP_LABEL = { A_aksl: { file: AKS }, B_aksl: { file: ARCK8S } };

const PAD = 40;
const maxX = Math.max(...els.filter((e) => e.type !== "text").map((e) => e.x + e.width));
const maxY = Math.max(...els.filter((e) => e.type !== "text").map((e) => e.y + e.height));
const W = maxX + PAD, H = maxY + PAD;
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function renderIcon(spec, cx, cy, size, fallbackColor) {
  const sz = size * (spec.scale || 1);
  if (spec.glyph) {
    const s = sz / 24;
    return `<g transform="translate(${(cx - sz / 2).toFixed(1)} ${(cy - sz / 2).toFixed(1)}) scale(${s.toFixed(3)})" fill="none" stroke="${fallbackColor}" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${GLYPHS[spec.glyph]}</g>`;
  }
  const ic = loadIcon(spec.file);
  if (!ic) return "";
  const tint = spec.tint ? ` fill="${spec.tint}"` : "";
  // nested <svg> + preserveAspectRatio keeps the original aspect ratio: no distortion
  return `<svg x="${(cx - sz / 2).toFixed(1)}" y="${(cy - sz / 2).toFixed(1)}" width="${sz.toFixed(1)}" height="${sz.toFixed(1)}" viewBox="${ic.vb}" preserveAspectRatio="xMidYMid meet" overflow="visible"${tint}>${ic.inner}</svg>`;
}

const ICON_SIZE = 28, TEXT_SHIFT = 16;
const parts = [];
parts.push(`<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" font-family="Segoe UI, Helvetica, Arial, sans-serif">`);
parts.push(`<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="context-stroke"/></marker></defs>`);
parts.push(`<rect width="${W}" height="${H}" fill="#ffffff"/>`);

for (const e of els.filter((x) => x.type === "rectangle")) {
  const fill = e.backgroundColor === "transparent" ? "none" : e.backgroundColor;
  parts.push(`<rect x="${e.x}" y="${e.y}" width="${e.width}" height="${e.height}" rx="10" ry="10" fill="${fill}" stroke="${e.strokeColor}" stroke-width="${e.strokeWidth}"/>`);
  if (MAP[e.id]) parts.push(renderIcon(MAP[e.id], e.x + e.width / 2, e.y + 27, ICON_SIZE, e.strokeColor));
  if (MAP_LEFT[e.id]) parts.push(renderIcon(MAP_LEFT[e.id], e.x + 34, e.y + e.height / 2, 26, e.strokeColor));
}

for (const e of els.filter((x) => x.type === "arrow")) {
  const [p0, p1] = e.points;
  parts.push(`<line x1="${e.x + p0[0]}" y1="${e.y + p0[1]}" x2="${e.x + p1[0]}" y2="${e.y + p1[1]}" stroke="${e.strokeColor}" stroke-width="${e.strokeWidth}" marker-end="url(#ah)"/>`);
}

// header + sub-container label icons
const ah = els.find((x) => x.id === "A_h"), bh = els.find((x) => x.id === "B_h");
if (ah) parts.push(renderIcon({ file: "azure-brand.svg" }, ah.x - 26, ah.y + 17, 30, "#0078D4"));
if (bh) parts.push(renderIcon({ file: AZLOCAL }, bh.x - 22, bh.y + 17, 28, "#5C2D91"));
for (const [id, spec] of Object.entries(MAP_LABEL)) {
  const t = els.find((x) => x.id === id);
  if (t) parts.push(renderIcon(spec, t.x - 24, t.y + 11, 20, "#555"));
}

for (const e of els.filter((x) => x.type === "text")) {
  const lines = e.text.split("\n");
  const lh = e.fontSize * 1.25;
  const bold = e.fontSize >= 20 ? ' font-weight="600"' : "";
  if (e.containerId) {
    const c = els.find((x) => x.id === e.containerId);
    const shift = MAP[c.id] ? TEXT_SHIFT : 0;
    const cx = c.x + c.width / 2;
    let y = c.y + c.height / 2 - (lines.length * lh) / 2 + e.fontSize * 0.95 + shift;
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
console.log(`wrote ${out} (${W}x${H}) — ${cache.size} icon files embedded`);
