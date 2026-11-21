import assert from 'node:assert/strict';
import {dirname,join} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {connectBrowser} from './BrowserSession.mjs';
const root=join(dirname(fileURLToPath(import.meta.url)),'../output/report-layout');
const browser=await connectBrowser(Number(process.argv[2]));
const {send,evaluate,waitFor,navigate}=browser;
async function clipboard(mode,fallback=true){
  await evaluate(`(()=>{window.copies=[];window.fallbacks=0;Object.defineProperty(navigator,'clipboard',{configurable:true,value:${mode==='absent'?'undefined':`{writeText:text=>${mode==='modern'?'(window.copies.push(text),Promise.resolve())':'Promise.reject(Error("fixture denied"))'}}`}});document.execCommand=command=>{window.fallbacks++;if(!${fallback})return false;window.copies.push(document.querySelector('textarea').value);return true;};})()`);
}
try{
  for(const client of ['SaaS','Subway'])for(const mode of ['Audit','Apply-Fix']){
    await navigate(pathToFileURL(join(root,`${client}-${mode}-preview.html`)).href);
    await waitFor("!!document.querySelector('button.command-copy')");
    const commands=await evaluate("Array.from(document.querySelectorAll('button.command-copy'),b=>({value:b.dataset.command,label:b.querySelector('code').textContent}))");
    assert.ok(commands.every(command=>command.value===command.label));
    const account=commands.findIndex(command=>command.value==='net user "SELISE-KIOSK"');
    const special=commands.findIndex(command=>command.value.includes('Sample & Support'));
    assert.ok(account>=0&&special>=0);
    for(const api of ['modern','absent','reject']){
      await clipboard(api);
      await evaluate(`document.querySelectorAll('button.command-copy')[${special}].click()`);
      await waitFor('window.copies.length===1');
      assert.equal(await evaluate('window.copies[0]'),commands[special].value);
      assert.equal(await evaluate('window.fallbacks'),api==='modern'?0:1);
      assert.equal(await evaluate('document.querySelectorAll("textarea").length'),0);
    }
    await clipboard('modern');
    await evaluate(`document.querySelectorAll('button.command-copy')[${account}].focus()`);
    await send('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13,text:'\r'});
    await send('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});
    await waitFor('window.copies.length===1');
    assert.equal(await evaluate('window.copies[0]'),commands[account].value);
    await clipboard('reject',false);
    await evaluate("document.querySelector('button.command-copy').click()");
    await waitFor("document.querySelector('.copy-feedback').textContent==='Copy failed. Please try again.'");
    assert.equal(await evaluate('window.copies.length'),0);
    await navigate(pathToFileURL(join(root,`${client}-${mode}-missing-account-preview.html`)).href);
    await waitFor("!!document.querySelector('button.command-copy')");
    assert.equal(await evaluate("Array.from(document.querySelectorAll('button.command-copy')).some(b=>b.dataset.command.includes('net user \"SELISE'))"),false);
    console.log(`PASS: ${client}/${mode} exact escaped command copying, keyboard activation, modern/fallback clipboard, truthful errors and missing-account commands; OS clipboard untouched`);
  }
  assert.equal(browser.requests.length,0);
  assert.equal(browser.errors.length,0);
}finally{browser.close();}
