// Exercise generated local HTML in an isolated headless browser. Clipboard APIs
// are replaced with test doubles, so the user's system clipboard is untouched.
import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const port = Number(process.argv[2]);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
let target;
for (let attempt = 0; attempt < 80; attempt++) {
  try {
    const response = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' });
    target = await response.json();
    break;
  } catch { await delay(100); }
}
assert.ok(target?.webSocketDebuggerUrl, 'Test browser did not start');
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }); });
let requestId = 0;
const pending = new Map();
socket.addEventListener('message', ({ data }) => {
  const response = JSON.parse(data);
  const request = pending.get(response.id);
  if (!request) return;
  clearTimeout(request.timer);
  pending.delete(response.id);
  if (response.error) request.reject(new Error(response.error.message));
  else request.resolve(response.result);
});
function send(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++requestId;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Timed out: ${method}`)); }, 10000);
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
  for (let index = 0; index < 100; index++) { if (await evaluate(expression)) return; await delay(25); }
  throw new Error(`Browser condition was not met: ${expression}`);
}
async function click(index, keyboard = false) {
  const position = await evaluate(`(() => {
    const button = document.querySelectorAll('button.command-copy')[${index}];
    button.scrollIntoView({block:'center'}); button.focus();
    const rect = button.querySelector('code').getBoundingClientRect();
    return {x:rect.x+Math.min(12,rect.width/2),y:rect.y+rect.height/2};
  })()`);
  if (keyboard) {
    await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13, text: '\r', unmodifiedText: '\r' });
    await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 });
  } else {
    await send('Input.dispatchMouseEvent', { type: 'mousePressed', ...position, button: 'left', clickCount: 1 });
    await send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...position, button: 'left', clickCount: 1 });
  }
}
async function setClipboard(mode, fallbackSucceeds = true) {
  await evaluate(`(() => {
    window.testCopied=[]; window.testModernCalls=0; window.testFallbackCalls=0;
    Object.defineProperty(navigator,'clipboard',{configurable:true,value:${mode === 'absent' ? 'undefined' : `{
      writeText(text) { window.testModernCalls++; ${mode === 'reject' ? "return Promise.reject(new Error('Clipboard denied'));" : 'window.testCopied.push(text); return Promise.resolve();'} }
    }`}});
    document.execCommand=function(command) {
      window.testFallbackCalls++;
      const field=document.activeElement;
      if(command!=='copy' || field.tagName!=='TEXTAREA' || field.selectionStart!==0 || field.selectionEnd!==field.value.length) throw new Error('Invalid copy selection');
      ${fallbackSucceeds ? 'window.testCopied.push(field.value); return true;' : 'return false;'}
    };
  })()`);
}

try {
  await send('Page.enable');
  await send('Runtime.enable');
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1050, deviceScaleFactor: 1, mobile: false });
  for (const client of ['SaaS', 'Subway']) {
    for (const mode of ['Audit', 'Apply-Fix']) {
      const filename = `${client}-${mode}-preview.html`;
      const uri = pathToFileURL(join(root, 'output', 'report-layout', filename)).href;
      await send('Page.navigate', { url: uri });
      await waitFor(`location.href === ${JSON.stringify(uri)} && document.readyState === 'complete' && !!document.querySelector('button.command-copy')`);
      assert.equal(await evaluate('window.isSecureContext'), true, 'Local file is not a secure context');
      const commands = await evaluate(`Array.from(document.querySelectorAll('button.command-copy'),b=>({value:b.dataset.command,label:b.querySelector('code').textContent}))`);
      assert.ok(commands.length > 5);
      assert.ok(commands.every(command => command.value === command.label), 'Button display and copied text differ');
      assert.equal(commands[0].value, 'lusrmgr.msc');
      assert.equal(commands[1].value, 'net user "SELISE-KIOSK"');
      const specialIndex = commands.findIndex(command => command.value.includes('Sample & Support'));
      assert.ok(specialIndex >= 0, 'Quoted ampersand/path fixture is missing');
      assert.equal(commands[specialIndex].value, 'notepad.exe "C:\\Sample & Support\\appsettings.json"');

      await setClipboard('modern');
      assert.equal(await evaluate('window.testCopied.length'), 0, 'Clipboard changed without a click');
      await click(0);
      await waitFor('window.testCopied.length === 1');
      assert.equal(await evaluate('window.testCopied[0]'), commands[0].value);
      assert.equal(await evaluate("document.querySelector('.copy-feedback').textContent"), 'Copied');
      assert.equal(await evaluate('window.testFallbackCalls'), 0);
      await click(1, true);
      await waitFor('window.testCopied.length === 2');
      assert.equal(await evaluate('window.testCopied[1]'), commands[1].value);
      await click(specialIndex);
      await waitFor('window.testCopied.length === 3');
      assert.equal(await evaluate('window.testCopied[2]'), commands[specialIndex].value);
      const administratorIndex = commands.findIndex(command => command.value === 'net user "Administrator"');
      assert.ok(administratorIndex >= 0, 'Detected administrative-account command is missing');
      await click(administratorIndex);
      await waitFor('window.testCopied.length === 4');
      assert.equal(await evaluate('window.testCopied[3]'), 'net user "Administrator"');

      for (const fallbackMode of ['absent', 'reject']) {
        await setClipboard(fallbackMode);
        await click(1);
        await waitFor('window.testCopied.length === 1');
        assert.equal(await evaluate('window.testCopied[0]'), commands[1].value);
        assert.equal(await evaluate('window.testFallbackCalls'), 1);
        assert.equal(await evaluate('document.querySelectorAll("textarea").length'), 0, 'Fallback left a temporary field');
        assert.equal(await evaluate('document.activeElement.dataset.command'), commands[1].value, 'Fallback lost keyboard focus');
      }
      await setClipboard('reject', false);
      await click(0);
      await waitFor(`document.querySelector('.copy-feedback').textContent === 'Copy failed. Please try again.'`);
      assert.equal(await evaluate('window.testCopied.length'), 0, 'Failed copy claimed success');
      assert.equal(await evaluate("document.querySelector('button.command-copy').dataset.copied"), 'false');

      await setClipboard('modern');
      await click(0);
      await waitFor('window.testCopied.length === 1');
      await evaluate('window.scrollTo(0,0)');
      const screenshot = await send('Page.captureScreenshot', { format: 'png' });
      await writeFile(join(root, 'output', 'report-layout', `${client}-${mode}-command-copy.png`), Buffer.from(screenshot.data, 'base64'));
      const missingUri = pathToFileURL(join(root, 'output', 'report-layout', `${client}-${mode}-missing-account-preview.html`)).href;
      await send('Page.navigate', { url: missingUri });
      await waitFor(`location.href === ${JSON.stringify(missingUri)} && document.readyState === 'complete' && !!document.querySelector('button.command-copy')`);
      const missingCommands = await evaluate(`(() => {
        const title=Array.from(document.querySelectorAll('.device-title')).find(node=>node.textContent==='KIOSK Account');
        return Array.from(title.closest('tr').querySelectorAll('button.command-copy'),button=>button.dataset.command);
      })()`);
      assert.deepEqual(missingCommands, ['lusrmgr.msc'], 'Missing account produced a specific-user command');
      assert.equal(await evaluate(`Array.from(document.querySelectorAll('button.command-copy')).some(button=>button.dataset.command.includes('SELISE or SELISE-KIOSK'))`), false);
      await setClipboard('modern');
      await click(0);
      await waitFor('window.testCopied.length === 1');
      assert.equal(await evaluate('window.testCopied[0]'), 'lusrmgr.msc');
      console.log(`PASS: ${client} / ${mode}: exact account/path copying, missing-account shortcut, mouse/keyboard input, modern/fallback paths, failure feedback and focus restoration`);
    }
  }
} finally {
  await send('Browser.close').catch(() => {});
  socket.close();
}
