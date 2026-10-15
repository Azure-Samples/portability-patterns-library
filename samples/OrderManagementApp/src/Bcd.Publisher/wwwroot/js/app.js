// Standard MSAL.js setup, written as for any Entra app. Only the runtime values in /config.json
// differ between Entra ID (protocolMode AAD) and Keycloak on Azure Local (protocolMode OIDC).
const { PublicClientApplication, InteractionRequiredAuthError } = window.msal;

const $ = (id) => document.getElementById(id);
const views = ["loading-view", "signin-view", "orders-view"];
const showView = (name) => views.forEach((view) => { $(view).hidden = view !== name; });

const cfg = await (await fetch("/config.json")).json();
const money = new Intl.NumberFormat(undefined, { style: "currency", currency: "USD" });
const dateTime = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });
const relative = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

$("idp-name").textContent = cfg.identityProvider;
$("footer-text").textContent = `Contoso Field Supply \u00b7 secured by ${cfg.identityProvider}`;
if (cfg.environment) {
  $("env-badge").textContent = `${cfg.environment} \u00b7 ${cfg.identityProvider}`;
  $("env-badge").hidden = false;
  $("signin-env").textContent = cfg.environment;
  $("signin-env").hidden = false;
}

const msalApp = cfg.clientId ? new PublicClientApplication({
  auth: {
    clientId: cfg.clientId,
    authority: cfg.authority,
    knownAuthorities: cfg.knownAuthorities,
    protocolMode: cfg.protocolMode,
    redirectUri: `${window.location.origin}/`,
    postLogoutRedirectUri: `${window.location.origin}/`
  },
  cache: { cacheLocation: "sessionStorage" }
}) : null;

let account = null;
if (msalApp) {
  await msalApp.initialize();
  try {
    const result = await msalApp.handleRedirectPromise();
    account = result?.account ?? msalApp.getAllAccounts()[0] ?? null;
  } catch (error) {
    showSignInError(error);
  }
  if (account) {
    msalApp.setActiveAccount(account);
  }
}

const tokenRequest = () => ({ scopes: [cfg.apiScope], account });

async function getAccessToken() {
  try {
    return (await msalApp.acquireTokenSilent(tokenRequest())).accessToken;
  } catch (error) {
    if (error instanceof InteractionRequiredAuthError) {
      await msalApp.acquireTokenRedirect(tokenRequest());
    }
    throw error;
  }
}

class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function api(method, path, body) {
  const headers = { Authorization: `Bearer ${await getAccessToken()}` };
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
  }
  const response = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  if (response.status === 404) {
    return null;
  }
  if (!response.ok) {
    let detail = response.statusText;
    try {
      const problem = await response.json();
      detail = problem.errors ? Object.values(problem.errors).flat().join(" ") : (problem.detail ?? problem.title ?? detail);
    } catch {
      // Not a problem-details body.
    }
    throw new ApiError(response.status, detail);
  }
  return response.status === 204 ? null : response.json();
}

function showSignInError(error) {
  $("signin-error").textContent = `Sign-in failed: ${error.errorCode ?? ""} ${error.message}`;
  $("signin-error").hidden = false;
}

// ---- Small DOM helpers ------------------------------------------------------------------------

const svgNs = "http://www.w3.org/2000/svg";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) {
    node.className = className;
  }
  if (text !== undefined) {
    node.textContent = text;
  }
  return node;
}

// Static icon geometry only; never built from data.
function icon(paths) {
  const svg = document.createElementNS(svgNs, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  for (const d of paths) {
    const path = document.createElementNS(svgNs, "path");
    path.setAttribute("d", d);
    svg.append(path);
  }
  return svg;
}

function toast(text, kind = "") {
  const item = el("div", `toast ${kind}`, text);
  item.setAttribute("role", kind === "error" ? "alert" : "status");
  $("toasts").append(item);
  setTimeout(() => item.remove(), 5000);
}

function setMessage(text, kind) {
  const message = $("order-message");
  message.textContent = text;
  message.className = `inline-status ${kind}`;
  message.hidden = !text;
}

function cell(content, className) {
  const td = el("td", className);
  if (content instanceof Node) {
    td.append(content);
  } else {
    td.textContent = content;
  }
  return td;
}

function initials(name) {
  const parts = name.split("@")[0].split(/[\s._-]+/).filter(Boolean);
  return ((parts[0]?.[0] ?? "") + (parts[1]?.[0] ?? parts[0]?.[1] ?? "")).toUpperCase();
}

function timeAgo(value) {
  const seconds = Math.round((new Date(value) - Date.now()) / 1000);
  const steps = [[60, "second"], [60, "minute"], [24, "hour"], [7, "day"]];
  let amount = seconds;
  for (const [size, unit] of steps) {
    if (Math.abs(amount) < size) {
      return relative.format(amount, unit);
    }
    amount = Math.round(amount / size);
  }
  return dateTime.format(new Date(value));
}

// ---- Catalog and new order --------------------------------------------------------------------

const productLook = {
  GEN: { category: "Power", tone: "power", paths: ["M13 2 4 14h7l-1 8 9-12h-7l1-8Z"] },
  UPS: { category: "Power", tone: "power", paths: ["M3 7h16a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2Z", "M23 11v2", "M6 10v4M10 10v4"] },
  SAT: { category: "Communications", tone: "comms", paths: ["M4 10a8 8 0 0 0 10 10L4 10Z", "M9 15l4-4", "M14 4a6 6 0 0 1 6 6", "M14 8a2 2 0 0 1 2 2"] },
  RAD: { category: "Communications", tone: "comms", paths: ["M5 8h14a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2Z", "M7 8 17 3", "M8 12.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5Z", "M14 13h4M14 16h4"] },
  WAT: { category: "Water", tone: "water", paths: ["M12 3C8 9 6 12 6 15a6 6 0 0 0 12 0c0-3-2-6-6-12Z"] }
};
const lookFor = (sku) => productLook[sku.split("-")[0]] ?? { category: "Supplies", tone: "", paths: ["M3.5 7.5 12 3l8.5 4.5v9L12 21l-8.5-4.5z"] };

let products = [];
let canCreate = false;

function renderCatalog() {
  const grid = $("catalog");
  grid.replaceChildren();
  for (const product of products) {
    const look = lookFor(product.sku);
    const card = el("article", "product");
    card.dataset.sku = product.sku;

    const top = el("div", "product-top");
    const badge = el("span", `product-icon ${look.tone}`);
    badge.append(icon(look.paths));
    top.append(badge, el("span", "category", look.category));

    const input = el("input", "qty");
    input.type = "number";
    input.min = "0";
    input.max = "100";
    input.value = "0";
    input.inputMode = "numeric";
    input.dataset.sku = product.sku;
    input.setAttribute("aria-label", `Quantity of ${product.name}`);
    input.disabled = !canCreate;
    input.addEventListener("input", updateSummary);

    const step = (delta, label, text) => {
      const button = el("button", "", text);
      button.type = "button";
      button.disabled = !canCreate;
      button.setAttribute("aria-label", `${label} ${product.name}`);
      button.addEventListener("click", () => {
        input.value = String(Math.min(100, Math.max(0, (Number.parseInt(input.value, 10) || 0) + delta)));
        updateSummary();
      });
      return button;
    };
    const stepper = el("div", "stepper");
    stepper.append(step(-1, "Remove one", "\u2212"), input, step(1, "Add one", "+"));

    const bottom = el("div", "product-bottom");
    bottom.append(el("span", "price", money.format(product.unitPrice)), stepper);

    card.append(top, el("div", "product-name", product.name), el("div", "product-sku", product.sku), bottom);
    grid.append(card);
  }
  updateSummary();
}

function selectedItems() {
  return [...document.querySelectorAll("#catalog input.qty")]
    .map((input) => ({ sku: input.dataset.sku, quantity: Number.parseInt(input.value, 10) || 0 }))
    .filter((item) => item.quantity > 0);
}

function updateSummary() {
  const items = selectedItems();
  const lines = $("summary-lines");
  lines.replaceChildren();
  let total = 0;
  for (const item of items) {
    const product = products.find((candidate) => candidate.sku === item.sku);
    const lineTotal = item.quantity * (product?.unitPrice ?? 0);
    total += lineTotal;
    const name = el("span");
    name.append(el("span", "line-qty", `${item.quantity}\u00d7`), document.createTextNode(product?.name ?? item.sku));
    const line = el("li");
    line.append(name, el("span", "", money.format(lineTotal)));
    lines.append(line);
  }
  document.querySelectorAll("#catalog .product").forEach((card) => {
    card.classList.toggle("selected", items.some((item) => item.sku === card.dataset.sku));
  });
  $("summary-empty").hidden = items.length > 0;
  $("order-total").textContent = money.format(total);
  $("place-order").disabled = !canCreate || total === 0;
}

async function placeOrder() {
  const items = selectedItems();
  $("place-order").disabled = true;
  setMessage("Placing order\u2026", "");
  try {
    const accepted = await api("POST", "/api/orders", { items });
    pending.set(accepted.orderId, { ...accepted, status: "Submitted" });
    document.querySelectorAll("#catalog input.qty").forEach((input) => { input.value = "0"; });
    updateSummary();
    const text = `Order ${accepted.orderId.slice(0, 8)} submitted for ${money.format(accepted.total)}.`;
    setMessage(text, "ok");
    toast(`${text} We'll update its status here.`, "ok");
    renderOrders(accepted.orderId);
    trackOrder(accepted.orderId);
  } catch (error) {
    const text = error.status === 403
      ? "You are not allowed to place orders (requires the Orders.Create role)."
      : `Could not place the order: ${error.message}`;
    setMessage(text, "error");
    toast(text, "error");
    updateSummary();
  }
}

// ---- Orders list ------------------------------------------------------------------------------

const pending = new Map();
let processed = [];

function renderSkeleton() {
  const body = $("orders");
  body.replaceChildren();
  for (let i = 0; i < 3; i++) {
    const row = el("tr", "skeleton");
    for (let j = 0; j < 5; j++) {
      const td = el("td");
      td.append(el("span"));
      row.append(td);
    }
    body.append(row);
  }
}

function renderOrders(freshId) {
  const known = new Set(processed.map((order) => order.orderId));
  const inFlight = [...pending.values()].filter((order) => !known.has(order.orderId));
  const rows = [...inFlight, ...processed].sort((a, b) => new Date(b.placedAt) - new Date(a.placedAt));

  const body = $("orders");
  body.replaceChildren();
  for (const order of rows) {
    const row = el("tr", order.orderId === freshId ? "fresh" : "");
    row.dataset.orderId = order.orderId;

    const shown = order.lines.slice(0, 2).map((line) => `${line.quantity} \u00d7 ${line.productName}`).join(", ");
    const items = el("span", "order-items", shown);
    if (order.lines.length > 2) {
      items.append(el("span", "more", ` +${order.lines.length - 2} more`));
    }

    const status = el("span", `status ${order.status.toLowerCase()}`, order.status);
    const placed = cell(timeAgo(order.placedAt));
    placed.title = dateTime.format(new Date(order.placedAt));

    row.append(cell(`#${order.orderId.slice(0, 8)}`, "mono"), cell(items), cell(money.format(order.total), "num"), cell(status), placed);
    body.append(row);
  }

  $("orders-empty").hidden = rows.length > 0;
  $("history-count").textContent = rows.length === 1 ? "1 order" : `${rows.length} orders`;
  $("kpi-orders").textContent = String(rows.length);
  $("kpi-processed").textContent = String(processed.length);
  $("kpi-progress").textContent = String(inFlight.length);
  $("kpi-value").textContent = money.format(rows.reduce((sum, order) => sum + order.total, 0));
}

async function loadOrders() {
  processed = await api("GET", "/api/orders") ?? [];
  renderOrders();
}

// The order is accepted onto the queue at once and recorded by the consumer moments later.
async function trackOrder(orderId) {
  for (let attempt = 0; attempt < 60; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 2000));
    const order = await api("GET", `/api/orders/${orderId}`).catch(() => null);
    if (order) {
      pending.delete(orderId);
      processed = [order, ...processed.filter((existing) => existing.orderId !== orderId)];
      renderOrders(orderId);
      toast(`Order ${orderId.slice(0, 8)} has been processed.`, "ok");
      return;
    }
  }
}

// ---- Start-up ---------------------------------------------------------------------------------

$("sign-in").addEventListener("click", () => {
  $("signin-error").hidden = true;
  msalApp.loginRedirect({ scopes: [cfg.apiScope] }).catch(showSignInError);
});
// OIDC providers such as Keycloak require id_token_hint to honour the post-logout redirect.
$("sign-out").addEventListener("click", () => msalApp.logoutRedirect({ account, idTokenHint: account?.idToken }));
$("place-order").addEventListener("click", placeOrder);
$("refresh").addEventListener("click", () => loadOrders()
  .then(() => toast("Order history refreshed."))
  .catch((error) => toast(`Could not refresh: ${error.message}`, "error")));

if (!msalApp) {
  $("sign-in").disabled = true;
  $("signin-error").textContent = "Sign-in is not configured for this deployment yet.";
  $("signin-error").hidden = false;
  showView("signin-view");
} else if (!account) {
  showView("signin-view");
} else {
  try {
    const me = await api("GET", "/api/me");
    canCreate = me.canCreate;
    $("user-name").textContent = me.name;
    $("user-avatar").textContent = initials(me.name);
    $("user-role").textContent = canCreate ? "Can place orders" : me.canRead ? "Read-only access" : "No order access";
    $("user-area").hidden = false;

    if (!me.canRead) {
      $("role-banner").textContent = "Your account has no access to orders. Ask an administrator for the Orders.Read or Orders.Create role.";
      $("role-banner").hidden = false;
    } else if (!canCreate) {
      $("role-banner").textContent = "You have read-only access. Placing orders requires the Orders.Create role.";
      $("role-banner").hidden = false;
    }

    products = await api("GET", "/api/products");
    renderCatalog();
    renderSkeleton();
    showView("orders-view");
    if (me.canRead) {
      await loadOrders();
    } else {
      renderOrders();
    }
  } catch (error) {
    showView("signin-view");
    showSignInError(error);
  }
}
