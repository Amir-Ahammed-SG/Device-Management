// Shared CDP transport for isolated, local report tests. No external dependency.
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
export async function connectBrowser(port) {
  let target;
  for (let i = 0; i < 150; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      target = list.find(item => item.type === 'page' && item.webSocketDebuggerUrl);
      if (target) break;
    } catch {}
    await delay(100);
  }
  if (!target) throw new Error('Isolated report browser did not start.');
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  const pending = new Map(), errors = [], requests = [];
  let sequence = 0;
  socket.addEventListener('message', event => {
    const message = JSON.parse(typeof event.data === 'string' ? event.data : Buffer.from(event.data).toString());
    if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails);
    if (message.method === 'Network.requestWillBeSent' && /^https?:/i.test(message.params.request.url)) requests.push(message.params.request.url);
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id); clearTimeout(request.timer);
    message.error ? request.reject(new Error(message.error.message)) : request.resolve(message.result);
  });
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  function send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 20000);
      pending.set(id, { resolve, reject, timer });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async function evaluate(expression) {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    return result.result.value;
  }
  async function waitFor(expression) {
    for (let i = 0; i < 200; i++) { if (await evaluate(expression)) return; await delay(30); }
    throw new Error(`Browser condition failed: ${expression}`);
  }
  async function navigate(url) {
    await send('Page.navigate', { url });
    await waitFor(`location.href===${JSON.stringify(url)}&&document.readyState==='complete'`);
  }
  await send('Page.enable'); await send('Runtime.enable'); await send('Network.enable');
  return { send, evaluate, waitFor, navigate, errors, requests, close() { for (const request of pending.values()) clearTimeout(request.timer); socket.close(); } };
}
