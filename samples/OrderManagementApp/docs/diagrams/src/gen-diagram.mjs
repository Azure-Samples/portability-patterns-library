import { writeFileSync } from "node:fs";

const els = [];
let seedCounter = 1;
const rnd = () => Math.floor(Math.random() * 2 ** 31) + seedCounter++;

const BASE = () => ({
  angle: 0,
  strokeStyle: "solid",
  opacity: 100,
  groupIds: [],
  frameId: null,
  seed: rnd(),
  version: 1,
  versionNonce: rnd(),
  isDeleted: false,
  updated: 1,
  link: null,
  locked: false,
});

function rect(id, x, y, w, h, stroke, bg, strokeWidth = 1, fillStyle = "solid") {
  const el = {
    ...BASE(),
    type: "rectangle",
    id,
    x,
    y,
    width: w,
    height: h,
    strokeColor: stroke,
    backgroundColor: bg,
    fillStyle,
    strokeWidth,
    roundness: { type: 3 },
    boundElements: null,
  };
  els.push(el);
  return el;
}

function text(id, x, y, w, h, str, fontSize, align = "left") {
  els.push({
    ...BASE(),
    type: "text",
    id,
    x,
    y,
    width: w,
    height: h,
    strokeColor: "#000000",
    backgroundColor: "transparent",
    fillStyle: "solid",
    strokeWidth: 1,
    roundness: null,
    boundElements: null,
    fontSize,
    fontFamily: 1,
    text: str,
    originalText: str,
    textAlign: align,
    verticalAlign: "top",
    containerId: null,
    lineHeight: 1.25,
  });
}

// Leaf box with bound (centered) label
function box(id, x, y, w, h, stroke, bg, str, fontSize = 13) {
  const r = rect(id, x, y, w, h, stroke, bg, 1, "solid");
  const tid = `${id}_t`;
  r.boundElements = [{ type: "text", id: tid }];
  const lines = str.split("\n").length;
  const th = Math.round(fontSize * 1.25 * lines);
  els.push({
    ...BASE(),
    type: "text",
    id: tid,
    x: x + 8,
    y: y + Math.round((h - th) / 2),
    width: w - 16,
    height: th,
    strokeColor: "#000000",
    backgroundColor: "transparent",
    fillStyle: "solid",
    strokeWidth: 1,
    roundness: null,
    boundElements: null,
    fontSize,
    fontFamily: 1,
    text: str,
    originalText: str,
    textAlign: "center",
    verticalAlign: "middle",
    containerId: id,
    lineHeight: 1.25,
  });
}

function arrow(id, x1, y1, x2, y2, stroke) {
  els.push({
    ...BASE(),
    type: "arrow",
    id,
    x: x1,
    y: y1,
    width: Math.abs(x2 - x1),
    height: Math.abs(y2 - y1),
    strokeColor: stroke,
    backgroundColor: "transparent",
    fillStyle: "solid",
    strokeWidth: 2,
    roundness: { type: 2 },
    boundElements: null,
    points: [
      [0, 0],
      [x2 - x1, y2 - y1],
    ],
    lastCommittedPoint: null,
    startBinding: null,
    endBinding: null,
    startArrowhead: null,
    endArrowhead: "arrow",
    elbowed: false,
  });
}

// ---- palette ----
const AZ = { s: "#0078D4", b: "#CFE4FA" };   // Azure
const AL = { s: "#5C2D91", b: "#E8DAEF" };   // Azure Local
const OK = { s: "#107C10", b: "#DFF6DD" };   // portable / pass
const WARN = { s: "#F7630C", b: "#FFF4CE" }; // compromise
const NEU = { s: "#1e1e1e", b: "#F3F2F1" };
const RED = { s: "#D13438", b: "#FDE7E9" };

// ---- title ----
text("title", 60, 30, 1800, 75, "Order Management System — Architecture Detail: Azure vs Azure Local", 30);
text(
  "subtitle",
  60,
  112,
  1900,
  42,
  "How the order queue, document archive and ledger are re-bound when the workload moves. Companion to the business-continuity story diagram.",
  15
);

// ---- portable band ----
rect("pband", 60, 175, 2280, 140, OK.s, "transparent", 2);
text("pband_l", 85, 190, 1200, 30, "PORTABLE LAYER — IDENTICAL IN BOTH ENVIRONMENTS", 14);
box("p1", 100, 228, 700, 72, OK.s, OK.b, "app.bicep — unchanged\nRadius resource contracts (sqlServerDatabases, objectStorage, messageQueues)", 12);
box("p2", 830, 228, 700, 72, OK.s, OK.b, "Container images — byte-identical\nmcr.microsoft.com/dotnet/runtime:9.0", 12);
box("p3", 1560, 228, 740, 72, OK.s, OK.b, "Only the Recipe Pack changes\nazure.bicep   ⇄   azurelocal.bicep", 12);

// ---- column shells ----
rect("colA", 60, 350, 1100, 1000, AZ.s, "transparent", 2);
rect("colB", 1240, 350, 1100, 1000, AL.s, "transparent", 2);

// geometry helper: left inner xs, right = +1180
const C1 = 115, C2 = 445, C3 = 775;
const W1 = 310, W3 = 340;
const OFF = 1180;

function column(p, lx, c, header, aksLabel, pods, svcLabel, svcs, idLabel, ids, gov, verdict, arrowLabels, verdictColor) {
  text(`${p}_h`, lx + 68, 370, 900, 40, header, 20);

  rect(`${p}_aks`, lx + 30, 425, 1040, 245, c.s, "transparent", 2);
  text(`${p}_aksl`, lx + 74, 440, 900, 28, aksLabel, 13);
  box(`${p}_b1`, lx + C1 - 60, 485, W1, 105, c.s, c.b, pods[0]);
  box(`${p}_b2`, lx + C2 - 60, 485, W1, 105, c.s, c.b, pods[1]);
  box(`${p}_b3`, lx + C3 - 60, 485, W3, 105, c.s, c.b, pods[2]);

  arrow(`${p}_a1`, lx + 560, 676, lx + 560, 756, c.s);
  text(`${p}_a1l`, lx + 580, 690, 600, 28, arrowLabels[0], 12);

  text(`${p}_svcl`, lx + 30, 730, 900, 28, svcLabel, 13);
  box(`${p}_s1`, lx + C1 - 60, 765, W1, 105, c.s, c.b, svcs[0]);
  box(`${p}_s2`, lx + C2 - 60, 765, W1, 105, c.s, c.b, svcs[1]);
  box(`${p}_s3`, lx + C3 - 60, 765, W3, 105, c.s, c.b, svcs[2]);

  arrow(`${p}_a2`, lx + 560, 876, lx + 560, 956, c.s);
  text(`${p}_a2l`, lx + 580, 890, 600, 28, arrowLabels[1], 12);

  text(`${p}_idl`, lx + 30, 930, 900, 28, idLabel, 13);
  box(`${p}_i1`, lx + C1 - 60, 965, W1, 105, c.s, c.b, ids[0]);
  box(`${p}_i2`, lx + C2 - 60, 965, W1, 105, c.s, c.b, ids[1]);
  box(`${p}_i3`, lx + C3 - 60, 965, W3, 105, c.s, c.b, ids[2]);

  box(`${p}_gov`, lx + 55, 1100, 1000, 80, NEU.s, NEU.b, gov, 12);
  box(`${p}_v`, lx + 55, 1200, 1000, 130, verdictColor.s, verdictColor.b, verdict, 12);
}

column(
  "A",
  60,
  AZ,
  "Azure — public cloud",
  "AKS cluster  ·  Microsoft.ContainerService/managedClusters",
  ["Order Intake\n(worker pod)", "Order Processor\n(worker pod)", "Radius control plane\nrecipe pack: azure.bicep"],
  "Azure PaaS backing services",
  [
    "Azure SQL Database\nMicrosoft.Sql/servers",
    "Azure Blob Storage\nMicrosoft.Storage/storageAccounts",
    "Azure Service Bus\nMicrosoft.ServiceBus/namespaces",
  ],
  "Identity  ·  registry  ·  governance",
  [
    "Microsoft Entra ID\ntenant-wide IdP",
    "User-assigned MI + FIC\nMicrosoft.ManagedIdentity/*",
    "Azure Container Registry\nMicrosoft.ContainerRegistry/registries",
  ],
  "Azure Policy  ·  Azure Monitor  ·  Defender — native cloud control plane",
  "POLICY GATE — Azure Local\n✔  Sql/servers — passes\n✖  Storage/storageAccounts — fails\n✖  ServiceBus/namespaces — fails\n✖  ManagedIdentity + FIC — fails",
  ["SQL (TDS) · AMQP 1.0 · Blob REST", "Entra workload identity (OIDC federation)"],
  RED
);

column(
  "B",
  1240,
  AL,
  "Azure Local — connected",
  "AKS enabled by Azure Arc  ·  Microsoft.Kubernetes/connectedClusters",
  [
    "Order Intake\n(same image)",
    "Order Processor\n(same image)",
    "Radius control plane\nrecipe pack: azurelocal.bicep",
  ],
  "Self-hosted backing services — in-cluster containers",
  ["SQL Server 2022\ncontainer + PVC", "Azurite\nBlob API emulator", "RabbitMQ\nAMQP 0-9-1 broker"],
  "Identity  ·  PKI  ·  registry",
  [
    "Keycloak\nOIDC provider",
    "Active Directory (AD DS)\nusers + service accounts",
    "AD CS\nenterprise PKI / TLS chain",
  ],
  "Arc control plane — Azure Policy, Monitor and Defender still reach back (connected)",
  "POLICY GATE\n✔  Kubernetes/connectedClusters — passes both\n✔  ContainerRegistry/registries — passes both\n→  No Azure data-plane PaaS types emitted at all\n→  Identity moves off Entra onto Keycloak + AD DS",
  ["SQL (TDS) · AMQP 0-9-1 · Blob REST", "OIDC · Kerberos / LDAP · PKI trust chain"],
  OK
);

// ---- bottom band ----
rect("bband", 60, 1390, 2280, 300, WARN.s, "transparent", 2);
text("bband_l", 85, 1405, 1600, 30, "TECHNICAL IMPACT — WHAT DEGRADES, AND WHY", 14);

const bw = 530;
box(
  "c1",
  90,
  1448,
  bw,
  222,
  OK.s,
  OK.b,
  "APPLICATION CODE\nunchanged\n\nSame images, same app.bicep.\nIMessageBroker / IArchiveStore /\nIEventRecordStore select an impl\nfrom CONNECTION_* env vars\ninjected by the Radius recipe.\n\nBoth broker impls ship in the image.",
  12
);
box(
  "c2",
  650,
  1448,
  bw,
  222,
  WARN.s,
  WARN.b,
  "DATA SERVICES\ncompromised\n\nSQL and Blob keep the same wire\nprotocol. The queue does not —\nAMQP 1.0 → AMQP 0-9-1 forces a\nsecond broker implementation.\n\nLose PITR, HA, geo-backup, lifecycle,\nimmutability, sessions and dedupe.\n\nData replication between\nenvironments — guidance to follow.",
  12
);
box(
  "c3",
  1210,
  1448,
  bw,
  222,
  RED.s,
  RED.b,
  "IDENTITY\nre-architected\n\nFederation remains, but the trust\nroot moves off Entra: Keycloak\nfederates to AD DS, AD CS issues\nthe TLS chain.\n\nWorkload-to-service auth loses the\nEntra FIC and reverts to\nrecipe-issued secrets.",
  12
);
box(
  "c4",
  1770,
  1448,
  bw,
  222,
  NEU.s,
  NEU.b,
  "OPERATIONS\nyou own it\n\nBackup, patching, HA and capacity\nfor every backing service become\nthe app team's job.\n\nMore guidance on this to follow.",
  12
);

const doc = {
  type: "excalidraw",
  version: 2,
  source: "claude",
  elements: els,
  appState: { viewBackgroundColor: "#ffffff", gridSize: null },
  files: {},
};

const out = process.argv[2];
writeFileSync(out, JSON.stringify(doc, null, 2));
console.log(`wrote ${out} — ${els.length} elements`);
