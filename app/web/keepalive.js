// The server remains alive while this tab can run timers, including in background.
(() => {
  let pending = false;
  async function heartbeat() {
    if (pending) return;
    pending = true;
    try {
      await fetch('/api/keepalive', {
        method: 'POST', credentials: 'same-origin', cache: 'no-store',
        headers: {'Content-Type': 'application/json'}, body: '{}',
        signal: AbortSignal.timeout(15000),
      });
    } catch (_) {
      // Offline/suspended tabs need not produce repeated errors or bank requests.
    } finally {
      pending = false;
    }
  }
  heartbeat();
  setInterval(heartbeat, 5 * 60 * 1000);
  window.addEventListener('pageshow', heartbeat);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') heartbeat();
  });
})();
