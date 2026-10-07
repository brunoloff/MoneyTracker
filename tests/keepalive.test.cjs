const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const events = {};
const requests = [];
let interval;
let resolve;
const context = {
  fetch: (url, options) => { requests.push({url, options}); return new Promise(r => resolve = r); },
  AbortSignal: {timeout: () => ({})},
  setInterval: (f, milliseconds) => { assert.equal(milliseconds, 300000); interval = f; },
  window: {addEventListener: (name, f) => events[name] = f},
  document: {visibilityState: 'hidden', addEventListener: (name, f) => events[name] = f},
};
(async () => {
  vm.runInNewContext(readFileSync('app/web/keepalive.js', 'utf8'), context);
  assert.equal(requests.length, 1);
  interval();
  assert.equal(requests.length, 1, 'No overlapping requests');
  resolve(); await new Promise(r => setImmediate(r));
  interval();
  assert.equal(requests.length, 2, 'Background tab still sends a heartbeat');
  resolve(); await new Promise(r => setImmediate(r));
  context.document.visibilityState = 'visible';
  events.visibilitychange();
  assert.equal(requests.length, 3, 'Resume sends an immediate heartbeat');
  assert.equal(requests[0].url, '/api/keepalive');
  assert.equal(requests[0].options.method, 'POST');
  assert.equal(requests[0].options.credentials, 'same-origin');
  console.log('Keepalive tests passed');
})().catch(e => { console.error(e); process.exitCode = 1; });
