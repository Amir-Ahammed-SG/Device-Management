import assert from 'node:assert/strict';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { connectBrowser } from './BrowserSession.mjs';
const root=join(dirname(fileURLToPath(import.meta.url)),'../output/single-file-reports');
const browser=await connectBrowser(Number(process.argv[2]));
const {send,evaluate,waitFor,navigate}=browser;
const frame='document.getElementById("report-frame").contentDocument';
try{
  for(const client of ['SaaS','Subway']){
    await navigate(pathToFileURL(join(root,client+'-Combined.html')).href);
    for(const width of [1440,390]){
      await send('Emulation.setDeviceMetricsOverride',{width,height:1000,deviceScaleFactor:1,mobile:width<500});
      for(const mode of ['Audit','Fix','Final']){
        await evaluate(`document.getElementById('tab-${mode}').click()`);
        await waitFor(`${frame}?.querySelector('.metadata')?.textContent.includes(${JSON.stringify(client)})&&document.getElementById('tab-${mode}').getAttribute('aria-selected')==='true'`);
        assert.equal(await evaluate('document.getElementById("report-frame").getAttribute("src")'),null);
        assert.equal(await evaluate(`${frame}.querySelectorAll('.command-copy').length>0`),mode!=='Final');
        assert.equal(await evaluate('document.getElementById("final-actions").hidden'),mode!=='Final');
        const labels=await evaluate(`${frame}.body.textContent`);
        assert.ok(labels.includes('Fixture & <Branch>')&&labels.includes('DEVICE-01'));
        assert.equal(await evaluate(`${frame}.querySelector('h1').textContent.includes('FIX')`),mode==='Fix');
        assert.ok(await evaluate('document.documentElement.scrollWidth<=innerWidth+1'),'Combined report overflows its viewport');
      }
    }
    await evaluate("document.getElementById('tab-Audit').dispatchEvent(new KeyboardEvent('keydown',{key:'End',bubbles:true}))");
    assert.equal(await evaluate("document.getElementById('tab-Final').getAttribute('aria-selected')"),'true');
    await evaluate("window.testPrints=0;window.print=()=>window.testPrints++;document.getElementById('print-final').click()");
    assert.equal(await evaluate('window.testPrints'),1);
    assert.ok(await evaluate("document.getElementById('print-report').textContent.includes('THOROUGH CHECK REPORT')"));
    assert.equal(await evaluate("document.getElementById('print-report').querySelectorAll('script,.command-copy').length"),0);
    const pdf=await send('Page.printToPDF',{printBackground:true,preferCSSPageSize:true});
    assert.ok(Buffer.from(pdf.data,'base64').subarray(0,5).equals(Buffer.from('%PDF-')));
    await navigate(pathToFileURL(join(root,client+'-Missing-Audit.html')).href);
    await waitFor(`${frame}?.body.textContent.includes('has not been run')`);
    assert.equal(await evaluate(`${frame}.querySelectorAll('.checks').length`),0,'Missing mode invented observations');
    console.log(`PASS: ${client} combined mode switching, keyboard navigation, mobile layout, local snapshots, final-only print/PDF and truthful missing-mode state`);
  }
  assert.equal(browser.requests.length,0,'Report loaded external resources');
  assert.equal(browser.errors.length,0,'Report threw a browser exception');
}finally{browser.close();}
