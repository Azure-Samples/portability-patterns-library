// Standard MSAL.js setup, written as for any Entra app. Only the runtime values in /config.json
// differ between Entra ID (protocolMode AAD) and Keycloak on Azure Local (protocolMode OIDC).
const { PublicClientApplication, InteractionRequiredAuthError } = window.msal;

const $ = (id) => document.getElementById(id);
const showView = (name) => ["loading-view", "signin-view", "orders-view"].forEach((view) => { $(view).hidden = view !== name; });

const cfg = await (await fetch("/config.json")).json();
// Each product and order carries its currency.
const moneyFormats = new Map();
const money = (amount, currency) => {
  if (!moneyFormats.has(currency)) {
    moneyFormats.set(currency, new Intl.NumberFormat(undefined, { style: "currency", currency }));
  }
  return moneyFormats.get(currency).format(amount);
};
const dateTime = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });

$("platform").textContent = [cfg.environment, cfg.identityProvider].filter(Boolean).join(" \u00b7 ");

const msalApp = cfg.clientId ? new PublicClientApplication({
  auth: {
    clientId: cfg.clientId,
    authority: cfg.authority,
    knownAuthorities: cfg.knownAuthorities,
    protocolMode: cfg.protocolMode,
    // Keycloak issues offline tokens only to clients allowed them, which this one isn't; MSAL asks
    // for one by default.
    ...(cfg.protocolMode === "OIDC" ? { OIDCOptions: { defaultScopes: ["openid", "profile"] } } : {}),
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
  const response = await send(method, path, body);
  return response === null || response.status === 204 ? null : response.json();
}

async function send(method, path, body) {
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
  return response;
}

function showSignInError(error) {
  $("signin-error").textContent = `Sign-in failed: ${error.errorCode ?? ""} ${error.message}`;
  $("signin-error").hidden = false;
}

function setMessage(text, kind = "") {
  const message = $("message");
  message.textContent = text;
  message.className = kind;
  message.hidden = !text;
}

function el(tag, text) {
  const node = document.createElement(tag);
  if (text !== undefined) {
    node.textContent = text;
  }
  return node;
}

function row(cells) {
  const tr = el("tr");
  for (const content of cells) {
    const td = el("td");
    if (content instanceof Node) {
      td.append(content);
    } else {
      td.textContent = content;
    }
    tr.append(td);
  }
  return tr;
}

// ---- Products and new order -------------------------------------------------------------------

let products = [];
let canCreate = false;
let canManageInventory = false;

const stockText = (product) => product.available <= 0 ? "Sold out"
  : product.available <= product.reorderLevel ? `${product.available} (low)` : String(product.available);

function renderCatalog() {
  // Keep what the user has picked when stock is refreshed underneath them.
  const picked = new Map(selectedItems().map((item) => [item.sku, item.quantity]));
  const body = $("catalog");
  body.replaceChildren();
  for (const product of products) {
    const max = Math.min(100, Math.max(0, product.available));
    const input = el("input");
    input.type = "number";
    input.min = "0";
    input.max = String(max);
    input.value = String(Math.min(max, picked.get(product.sku) ?? 0));
    input.dataset.sku = product.sku;
    input.setAttribute("aria-label", `Quantity of ${product.name}`);
    input.disabled = !canCreate || max === 0;
    input.addEventListener("input", updateSummary);

    const tr = row([product.name, product.sku, money(product.unitPrice, product.currency), stockText(product), input]);
    tr.dataset.sku = product.sku;
    body.append(tr);
  }
  updateSummary();
  renderInventory();
}

function selectedItems() {
  return [...document.querySelectorAll("#catalog input")]
    .map((input) => ({ sku: input.dataset.sku, quantity: Number.parseInt(input.value, 10) || 0 }))
    .filter((item) => item.quantity > 0);
}

function updateSummary() {
  const items = selectedItems();
  const total = items.reduce((sum, item) =>
    sum + item.quantity * (products.find((product) => product.sku === item.sku)?.unitPrice ?? 0), 0);
  // An order is in one currency; the API refuses a mix.
  const currency = products.find((product) => product.sku === items[0]?.sku)?.currency ?? products[0]?.currency;
  $("order-total").textContent = currency ? money(total, currency) : "";
  $("place-order").disabled = !canCreate || total === 0;
}

// While the inventory service is down, the API answers with the last stock it fetched, and says when.
// The page then checks again every 30 seconds until it's back.
let stockRetry = null;
async function loadProducts() {
  const response = await send("GET", "/api/products");
  products = (response ? await response.json() : null) ?? [];
  const asOf = response?.headers.get("X-Products-As-Of");
  $("stock-banner").textContent = asOf
    ? `Stock as of ${dateTime.format(new Date(asOf))}: the inventory service is unavailable. You can still order; stock is confirmed when the order is processed.`
    : "";
  $("stock-banner").hidden = !asOf;
  clearTimeout(stockRetry);
  stockRetry = asOf ? setTimeout(() => loadProducts().catch(() => {}), 30000) : null;
  renderCatalog();
}

async function placeOrder() {
  $("place-order").disabled = true;
  try {
    const accepted = await api("POST", "/api/orders", { items: selectedItems() });
    pending.set(accepted.orderId, { ...accepted, status: "Submitted" });
    document.querySelectorAll("#catalog input").forEach((input) => { input.value = "0"; });
    updateSummary();
    setMessage(`Order ${accepted.orderId.slice(0, 8)} submitted for ${money(accepted.total, accepted.currency)}.`, "ok");
    renderOrders();
    trackOrder(accepted.orderId);
  } catch (error) {
    setMessage(error.status === 403
      ? "You are not allowed to place orders (requires the Orders.Create role)."
      : `Could not place the order: ${error.message}`, "error");
    updateSummary();
  }
}

// ---- Inventory (restock) ----------------------------------------------------------------------

function renderInventory() {
  $("inventory-panel").hidden = !canManageInventory;
  if (!canManageInventory) {
    return;
  }
  const body = $("inventory");
  body.replaceChildren();
  for (const product of products) {
    const input = el("input");
    input.type = "number";
    input.min = "1";
    input.max = "10000";
    input.value = "10";
    input.setAttribute("aria-label", `Units of ${product.name} to add`);

    const button = el("button", "Restock");
    button.type = "button";
    button.addEventListener("click", () => restock(product, Number.parseInt(input.value, 10) || 0, button));

    const form = el("span");
    form.append(input, button);
    body.append(row([product.name, product.sku, stockText(product), String(product.reorderLevel), form]));
  }
}

async function restock(product, quantity, button) {
  button.disabled = true;
  try {
    const updated = await api("POST", `/api/inventory/${encodeURIComponent(product.sku)}/restock`, { quantity });
    if (!updated) {
      throw new ApiError(404, `Unknown product ${product.sku}.`);
    }
    products = products.map((candidate) => candidate.sku === updated.sku ? updated : candidate);
    renderCatalog();
    setMessage(`Added ${quantity} \u00d7 ${updated.name}; ${updated.available} available.`, "ok");
  } catch (error) {
    setMessage(error.status === 403
      ? "You are not allowed to restock (requires the Inventory.Manage role)."
      : `Could not restock: ${error.message}`, "error");
    button.disabled = false;
  }
}

// ---- Orders -----------------------------------------------------------------------------------

const pending = new Map();
let processed = [];

function renderOrders() {
  const known = new Set(processed.map((order) => order.orderId));
  const inFlight = [...pending.values()].filter((order) => !known.has(order.orderId));
  const orders = [...inFlight, ...processed].sort((a, b) => new Date(b.placedAt) - new Date(a.placedAt));

  const body = $("orders");
  body.replaceChildren();
  for (const order of orders) {
    const items = order.lines.map((line) => `${line.quantity} \u00d7 ${line.productName}`).join(", ");
    const status = order.status === "Rejected" && order.statusReason ? `Rejected: ${order.statusReason}` : order.status;
    const tr = row([order.orderId.slice(0, 8), items, money(order.total, order.currency), status, dateTime.format(new Date(order.placedAt))]);
    tr.dataset.orderId = order.orderId;
    body.append(tr);
  }
  $("orders-empty").hidden = orders.length > 0;
}

async function loadOrders() {
  processed = await api("GET", "/api/orders") ?? [];
  renderOrders();
}

// The order is accepted onto the queue at once and recorded by the processor once it has reserved
// the stock. That takes moments, or up to about an hour while the inventory service is down, so the
// page checks less often as time goes on.
async function trackOrder(orderId) {
  const giveUpAt = Date.now() + 60 * 60 * 1000;
  for (let delay = 2000; Date.now() < giveUpAt; delay = Math.min(delay * 2, 30000)) {
    await new Promise((resolve) => setTimeout(resolve, delay));
    const order = await api("GET", `/api/orders/${orderId}`).catch(() => null);
    if (order) {
      pending.delete(orderId);
      processed = [order, ...processed.filter((existing) => existing.orderId !== orderId)];
      renderOrders();
      setMessage(order.status === "Rejected"
        ? `Order ${orderId.slice(0, 8)} was rejected: ${order.statusReason ?? "unknown reason"}.`
        : `Order ${orderId.slice(0, 8)} has been processed.`, order.status === "Rejected" ? "error" : "ok");
      // Stock changed with the order.
      await loadProducts().catch(() => {});
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
$("refresh").addEventListener("click", () => Promise.all([loadOrders(), loadProducts()])
  .then(() => setMessage(""))
  .catch((error) => setMessage(`Could not refresh: ${error.message}`, "error")));

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
    canManageInventory = me.canManageInventory === true;
    const access = canCreate ? "can place orders" : me.canRead ? "read-only" : "no order access";
    $("user").textContent = `${me.name} (${access}${canManageInventory ? ", inventory manager" : ""})`;
    $("user-area").hidden = false;

    if (!me.canRead) {
      $("role-banner").textContent = "Your account has no access to orders. Ask an administrator for the Orders.Read or Orders.Create role.";
      $("role-banner").hidden = false;
    } else if (!canCreate) {
      $("role-banner").textContent = "You have read-only access. Placing orders requires the Orders.Create role.";
      $("role-banner").hidden = false;
    }

    await loadProducts().catch((error) => {
      $("stock-banner").textContent = `Products are unavailable: ${error.message} Your orders are below; try Refresh shortly.`;
      $("stock-banner").hidden = false;
    });
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
