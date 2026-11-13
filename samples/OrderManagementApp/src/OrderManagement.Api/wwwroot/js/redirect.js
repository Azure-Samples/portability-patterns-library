// Passes the sign-in response to the page that started sign-in: back to it for a redirect, or
// through a BroadcastChannel for MSAL's hidden iframe.
window.msalRedirectBridge.broadcastResponseToMainFrame().catch(() => {
  document.getElementById("redirect-error").hidden = false;
});
