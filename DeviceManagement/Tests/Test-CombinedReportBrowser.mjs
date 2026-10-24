import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir,readdir} from 'node:fs/promises';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../output/single-file-reports');
const exportsRoot=join(root,'exports',String(Date.now()));await mkdir(exportsRoot,{recursive:true});
const html=await readFile(join(root,'Combined-Report-Preview.html'),'utf8');
const state=JSON.parse(Buffer.from(html.match(/<script id="thorough-report-state" type="application\/octet-stream">([^<]+)<\/script>/)[1],'base64').toString('utf8'));
const delay=ms=>new Promise(r=>setTimeout(r,ms));let target;
for(let n=0;n<80;n++){try{target=await(await fetch('http://127.0.0.1:'+Number(process.argv[2])+'/json/new?about:blank',{method:'PUT'})).json();break;}catch{await delay(100);}}
assert.ok(target?.webSocketDebuggerUrl,'Test browser did not start');
const socket=new WebSocket(target.webSocketDebuggerUrl);await new Promise((r,j)=>{socket.addEventListener('open',r,{once:true});socket.addEventListener('error',j,{once:true});});
let sequence=0;const pending=new Map(),errors=[],externalRequests=[];
socket.addEventListener('message',({data})=>{const message=JSON.parse(data);if(message.method==='Runtime.exceptionThrown')errors.push(message.params.exceptionDetails.text);if(message.method==='Network.requestWillBeSent'&&/^https?:/i.test(message.params.request.url))externalRequests.push(message.params.request.url);const request=pending.get(message.id);if(!request)return;pending.delete(message.id);clearTimeout(request.timer);message.error?request.reject(Error(message.error.message)):request.resolve(message.result);});
function send(method,params={}){return new Promise((resolve,reject)=>{const id=++sequence,timer=setTimeout(()=>{pending.delete(id);reject(Error('Timed out: '+method));},12000);pending.set(id,{resolve,reject,timer});socket.send(JSON.stringify({id,method,params}));});}
async function evaluate(expression){const result=await send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(result.exceptionDetails)throw Error(result.exceptionDetails.exception?.description||result.exceptionDetails.text);return result.result.value;}
async function waitFor(expression){for(let n=0;n<150;n++){if(await evaluate(expression))return;await delay(30);}throw Error('Browser condition failed: '+expression);}
async function navigate(file){const url=pathToFileURL(join(root,file)).href;await send('Page.navigate',{url});await waitFor('location.href==='+JSON.stringify(url)+'&&document.readyState==="complete"');}
async function screenshot(file){const shot=await send('Page.captureScreenshot',{format:'png'});await writeFile(join(root,file),Buffer.from(shot.data,'base64'));}
const frameDoc='document.getElementById("report-frame").contentDocument';
const alignedRecords='(()=>{const d='+frameDoc+';const row=Array.from(d.querySelectorAll("table.checks tr")).find(r=>r.querySelector(".device-title")?.textContent==="Legacy Payment Services");return [row.cells[2],row.cells[3]].map(cell=>Array.from(cell.querySelectorAll(".aligned-record"),record=>{const heading=record.querySelector(".config-item-title"),r=record.getBoundingClientRect(),h=heading.getBoundingClientRect(),divider=record.nextElementSibling;return {top:r.top,height:r.height,headingTop:h.top,headingHeight:h.height,divider:divider?.tagName==="HR"?divider.getBoundingClientRect().top:null};}));})()';
async function verifyRecordAlignment(){
  const condition='(()=>{const columns='+alignedRecords+';return columns.every(column=>column.length===2)&&columns[0].every((record,index)=>{const other=columns[1][index];return Math.abs(record.top-other.top)<=1&&Math.abs(record.height-other.height)<=1&&Math.abs(record.headingTop-other.headingTop)<=1&&Math.abs(record.headingHeight-other.headingHeight)<=1&&(record.divider===null?other.divider===null:Math.abs(record.divider-other.divider)<=1);});})()';
  await waitFor(condition);
  return evaluate(alignedRecords);
}
const results=[];
try{
  await send('Page.enable');await send('Runtime.enable');await send('Network.enable');
  await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1050,deviceScaleFactor:1,mobile:false});
  await navigate('Combined-Report-Preview.html');
  assert.equal(await evaluate('document.getElementById("tab-Final").textContent.trim()'),'Final');
  assert.equal(await evaluate('document.getElementById("export-final")'),null);
  assert.deepEqual(await evaluate('Array.from(document.querySelectorAll("#final-actions button"),b=>b.textContent.trim())'),['Print']);
  for(let c=0;c<state.Catalog.length;c++){
    const client=state.Catalog[c];
    await evaluate('document.getElementById("bundle-client").value='+JSON.stringify(String(c))+';document.getElementById("bundle-client").dispatchEvent(new Event("change"));');
    for(const mode of ['Audit','Fix','Final']){
      await evaluate('document.getElementById("tab-'+mode+'").click()');
      await waitFor(frameDoc+'?.querySelector(".metadata td")?.textContent==='+JSON.stringify(client.Reports[mode].ReportId));
      await waitFor(frameDoc+'?.documentElement?.getAttribute("data-block-alignment")==="ready"');
      const snapshot=await evaluate('(()=>{const d='+frameDoc+';return {headers:Array.from(d.querySelectorAll("table.checks"),t=>Array.from(t.tHead.rows[1].cells,c=>c.textContent)),printHidden:document.getElementById("final-actions").hidden,src:document.getElementById("report-frame").getAttribute("src"),overflow:document.documentElement.scrollWidth>innerWidth,commands:d.querySelectorAll(".command-copy").length,statuses:Array.from(d.querySelectorAll(".badge"),e=>({text:e.textContent,color:d.defaultView.getComputedStyle(e).color})),id:d.querySelector(".metadata td").textContent};})()');
      assert.equal(snapshot.printHidden,mode!=='Final');assert.equal(snapshot.src,null,'A tab depends on another report file');assert.ok(!snapshot.overflow);assert.equal(snapshot.headers.length,mode==='Fix'?4:5);
      for(let section=0;section<snapshot.headers.length;section++)assert.deepEqual(snapshot.headers[section],mode==='Audit'?['Component','Shortcut / Command','Required Configuration','Findings']:mode==='Fix'?['Component','Shortcut / Command','Findings','Applied']:['Component','Final Configuration',...(section===4?[]:['Status'])]);
      if(mode!=='Fix'){
      const taskView=await evaluate('(()=>{const d='+frameDoc+';const row=Array.from(d.querySelectorAll("table.checks tr")).find(r=>r.querySelector(".device-title")?.textContent==="Payment Service Restart Task");const cell=row.cells['+(mode==='Final'?1:mode==='Fix'?2:3)+'];return {labels:Array.from(cell.querySelectorAll(".kv-label"),e=>e.textContent),text:cell.textContent};})()');
      if(mode==='Fix'){
        assert.deepEqual(taskView.labels,[],'Healthy task values are repeated in Fix Findings');
        assert.ok(taskView.text.includes('No further fix needed.'));
      }else{
        assert.deepEqual(taskView.labels,['Task Name:','Task Status:','Target:','Trigger Time:','Last Run:','Next Run:']);
        assert.ok(taskView.text.includes('Task Status: Active'),'The actual enabled state was not presented correctly');
        assert.ok(taskView.text.includes('Target: '+(client.ClientType==='Subway'?'SubwayLocal':'AspPaymentSaaSProd')),'The actual target service was lost');
      }
      if(mode==='Audit'){
        const requirements=await evaluate('(()=>{const d='+frameDoc+';const row=Array.from(d.querySelectorAll("table.checks tr")).find(r=>r.querySelector(".device-title")?.textContent==="Payment Service Restart Task");return Array.from(row.cells[2].querySelectorAll(".kv-block > div"),e=>e.textContent);})()');
        assert.deepEqual(requirements,['Task Name: e.g. Restart PS','Task Status: Active','Target: Payment Service','Trigger Time: time','Last Run: date & time','Next Run: date & time']);
        if(c===0){
          await evaluate('Array.from('+frameDoc+'.querySelectorAll(".device-title")).find(e=>e.textContent==="Payment Service Restart Task").closest("tr").scrollIntoView({block:"start"})');
          await screenshot('Task-Requirements-And-Findings.png');
          await evaluate('scrollTo(0,0)');
        }
      }
      if(mode!=='Fix'){
        assert.ok(taskView.text.includes('Trigger Time: Everyday at 4:15 AM')&&!taskView.text.includes('Starts'),'Trigger Time is not compact');
        assert.ok(taskView.text.includes('Last Run: 21 Oct 2026, 4:15 AM')&&taskView.text.includes('Next Run: 22 Oct 2026, 4:15 AM'),'Run times are not compact device-local times');
      }
      const collectedFields=await evaluate('(()=>{const d='+frameDoc+';const specs=[["Kiosk Launch Script","Launcher Path:"],["Startup Folder","Location:"],["Payment Gateway","Version:"],["Payment Service Restart Task","Task Name:"],["Payment Service Restart Task","Trigger Time:"],["Payment Service Restart Task","Last Run:"],["Payment Service Restart Task","Next Run:"]];return specs.map(([component,label])=>{const row=Array.from(d.querySelectorAll("table.checks tr")).find(r=>r.querySelector(".device-title")?.textContent===component);const cell=row.cells['+(mode==='Final'?1:mode==='Fix'?2:3)+'];const field=Array.from(cell.querySelectorAll(".kv-label")).find(e=>e.textContent===label)?.parentElement;return {component,label,found:!!field,green:field?.classList.contains("finding-match"),highlight:field?.classList.contains("finding-value"),title:field?.getAttribute("title"),background:field?d.defaultView.getComputedStyle(field).backgroundColor:null};});})()');
      assert.equal(collectedFields.length,7);
      for(const field of collectedFields){
        if(mode==='Fix'){assert.equal(field.found,false,'Healthy informational fields are repeated in Fix');continue;}
        assert.ok(field.found,'A requested collected field was lost: '+field.component+'/'+field.label);
        if(mode==='Final')assert.equal(field.highlight,false,'A collected field restored color in Final');
        else{
          assert.equal(field.green,true,'A collected field lacks green styling: '+field.component+'/'+field.label);
          assert.equal(field.background,'rgb(232, 245, 233)');
          assert.equal(field.title,'Value collected','A collected value claims an exact requirement match');
        }
      }
      if(c===0&&mode==='Audit'){
        await evaluate('Array.from('+frameDoc+'.querySelectorAll(".device-title")).find(e=>e.textContent==="Kiosk Launch Script").closest("tr").scrollIntoView({block:"start"})');
        await screenshot('Collected-Paths-Preview.png');
        await evaluate('scrollTo(0,0)');
      }
      const generated=await evaluate(frameDoc+'.querySelector(".metadata tr").cells[3].textContent');
      assert.match(generated,/^\d{2} [A-Za-z]{3} \d{4}, \d{1,2}:\d{2} (AM|PM) BST$/);
      assert.ok(!/\.\d+/.test(generated),'Generated time exposed unnecessary subsecond precision');
      assert.ok((await evaluate('document.getElementById("bundle-description").textContent')).includes(generated),'The saved-time label disagrees with the report');
      const counter=await evaluate('(()=>{const d='+frameDoc+';const row=Array.from(d.querySelectorAll("table.checks tr")).find(r=>r.querySelector(".device-title")?.textContent==="Performance Counter");const cell=row.cells['+(mode==='Final'?1:mode==='Fix'?2:3)+'];const amber=cell.querySelector(".finding-unverified");return {text:cell.textContent,amber:!!amber,background:amber?d.defaultView.getComputedStyle(amber).backgroundColor:null};})()');
      assert.equal(counter.amber,mode==='Audit','Counter amber coloring escaped Audit or was omitted');
      if(mode==='Audit'){
        assert.equal(counter.text,'Audit: Not executed');
        assert.equal(counter.background,'rgb(255, 248, 225)','Audit counter does not use the approved amber');
        if(c===0){
          await evaluate('Array.from('+frameDoc+'.querySelectorAll(".device-title")).find(e=>e.textContent==="Performance Counter").closest("tr").scrollIntoView({block:"center"})');
          await screenshot('Audit-Counter-Amber.png');
          await evaluate('scrollTo(0,0)');
        }
      }
      const blocks=await evaluate('(()=>{const d='+frameDoc+';return {items:Array.from(d.querySelectorAll(".config-item-title"),e=>({text:e.textContent,background:d.defaultView.getComputedStyle(e).backgroundColor,border:d.defaultView.getComputedStyle(e).borderLeftWidth})),groups:Array.from(d.querySelectorAll(".config-group-title"),e=>e.textContent)};})()');
      for(const title of ['Printer 01','Printer 02','Account 01','Account 02','Terminal 01','Terminal 02'])assert.ok(blocks.items.some(item=>item.text===title),'Missing formatted block: '+title);
      assert.ok(blocks.items.every(item=>!/^\[/.test(item.text)&&item.background==='rgb(243, 245, 247)'&&item.border==='3px'),'Block headers differ from the approved neutral style');
      const dividers=await evaluate('(()=>{const d='+frameDoc+';return Array.from(d.querySelectorAll("td")).flatMap(cell=>{let count=0;return Array.from(cell.querySelectorAll(".config-group-title,.config-item-title")).flatMap(e=>{if(e.classList.contains("config-group-title")){count=0;return [];}const record=e.closest(".aligned-record")||e;return [{expected:count++>0,actual:record.previousElementSibling?.classList.contains("block-divider")===true}];});});})()');
      assert.ok(dividers.some(item=>item.expected),'The preview does not cover repeated records');
      assert.ok(dividers.every(item=>item.actual===item.expected),'Record dividers are missing or precede the first record');
      assert.ok(await evaluate('Array.from('+frameDoc+'.querySelectorAll("hr")).every(e=>{const s=e.ownerDocument.defaultView.getComputedStyle(e),next=e.nextElementSibling;const followsRecord=next?.classList.contains("config-item-title")||(next?.classList.contains("aligned-record")&&next.firstElementChild?.classList.contains("config-item-title"));return e.classList.contains("block-divider")&&followsRecord&&s.display!=="none"&&s.borderTopWidth==="1px"&&s.borderTopColor==="rgb(185, 191, 197)";})'),'A divider is hidden, duplicated, trailing or has the wrong style');
      const legacy=await evaluate('(()=>{const d='+frameDoc+';const rows=Array.from(d.querySelectorAll("table.checks tr")).filter(r=>r.querySelector(".device-title")?.textContent==="Legacy Payment Services");return {count:rows.length,names:Array.from(rows[0].cells['+(mode==='Final'?1:mode==='Fix'?2:3)+'].querySelectorAll(".config-item-title"),e=>e.textContent)};})()');
      assert.equal(legacy.count,1,'Legacy services are split into separate components');
      assert.deepEqual(legacy.names,client.ClientType==='Subway'?['AspPaymentSubwayProd','AspPaymentSaaSProd']:['SubwayLocal','AspPaymentSubwayProd']);
      assert.ok(blocks.groups.includes('NETS Terminals'),'Terminal collection heading was not formatted');
      const hostname=await evaluate('(()=>{const d='+frameDoc+';const row=Array.from(d.querySelectorAll("table.checks tr")).find(r=>r.querySelector(".device-title")?.textContent==="Zabbix Agent");const cell=row.cells['+(mode==='Final'?1:mode==='Fix'?2:3)+'];return {text:cell.textContent,amber:!!cell.querySelector(".finding-unverified"),status:'+(mode==='Final'?'row.cells[2].textContent.trim()':'null')+'};})()');
      assert.ok(hostname.text.includes('Host Name: Not verified. The service configuration could not be read. Please check manually.'),'Hostname limitation is not understandable');
      assert.equal(hostname.amber,mode!=='Final');
      if(mode==='Final')assert.equal(hostname.status,'Fail');
      const serviceRecovery=await evaluate('(()=>{const d='+frameDoc+';return Array.from(d.querySelectorAll("table.checks tr")).filter(r=>["Payment Gateway","Zabbix Agent","Windows Update","Legacy Payment Services"].includes(r.querySelector(".device-title")?.textContent)).map(r=>{const cell=r.cells['+(mode==='Final'?1:mode==='Fix'?2:3)+'];return {name:r.querySelector(".device-title").textContent,text:cell.textContent,summaries:Array.from(cell.querySelectorAll(".service-recovery-summary"),e=>e.textContent)};});})()');
      assert.equal(serviceRecovery.length,4,'A service component was omitted');
      for(const service of serviceRecovery){
        if(mode==='Final'){
          assert.deepEqual(service.summaries,Array(service.name==='Legacy Payment Services'?2:1).fill('Recovery: Configured'),'Service recovery summary is missing or inaccurate');
          assert.ok(!/First failure:|Second failure:|Subsequent failures:/.test(service.text),'Final retains detailed failure actions');
        }else{
          assert.equal(service.summaries.length,0,'Recovery summary leaked into Audit/Fix');
          if(mode==='Audit')assert.ok(['First failure:','Second failure:','Subsequent failures:'].every(label=>service.text.includes(label)),'Audit lost detailed service recovery actions');
          else assert.ok(!/First failure:|Second failure:|Subsequent failures:/.test(service.text),'Healthy recovery fields are repeated in Fix');
        }
      }
      const appValues=await evaluate('(()=>{const d='+frameDoc+';const table=d.querySelectorAll("table.checks")[4];return Array.from(table.tBodies[0].rows).flatMap(r=>Array.from(r.cells['+(mode==='Final'?1:mode==='Fix'?2:3)+'].querySelectorAll(".kv-label"),label=>{const field=label.parentElement;return {text:field.textContent,green:field.classList.contains("finding-match"),highlight:field.classList.contains("finding-value"),title:field.getAttribute("title"),background:d.defaultView.getComputedStyle(field).backgroundColor};}));})()');
      assert.equal(appValues.length,27,'AppSettings field count changed');
      assert.ok(appValues.some(value=>value.text.endsWith(': False')),'The preview lacks a false-valued AppSettings field');
      for(const value of appValues){
        if(mode==='Final')assert.equal(value.highlight,false,'AppSettings restored colors in Final');
        else{
          assert.equal(value.green,true,'A collected AppSettings value lacks green styling: '+value.text);
          assert.equal(value.background,'rgb(232, 245, 233)');
          assert.equal(value.title,'Value collected','An AppSettings value claims configuration verification');
        }
      }
      if(c===0&&mode==='Audit'){
        await evaluate(frameDoc+'.querySelectorAll("table.checks")[4].scrollIntoView({block:"start"})');
        await screenshot('AppSettings-Values-Preview.png');
        await evaluate('scrollTo(0,0)');
      }
      }
      if(mode==='Fix'){
        assert.deepEqual(await evaluate('Array.from('+frameDoc+'.querySelectorAll(".device-title"),e=>e.textContent)'),['Printer','System & Browser Policies','Payment Gateway','Zabbix Agent','Windows Update','Legacy Payment Services','Administrative Accounts','Nmap Diagnostic Tool','Performance Counter'],'Fix includes a healthy unchanged component or lost an action/issue');
        const accountFilter=await evaluate('(()=>{const d='+frameDoc+';const row=Array.from(d.querySelectorAll("table.checks tr")).find(r=>r.querySelector(".device-title")?.textContent==="Administrative Accounts");return {findings:row.cells[2].textContent,headings:Array.from(row.cells[2].querySelectorAll(".config-item-title"),e=>e.textContent),appliedHeadings:Array.from(row.cells[3].querySelectorAll(".config-item-title"),e=>e.textContent),commands:Array.from(row.cells[1].querySelectorAll(".command-copy"),e=>e.dataset.command)};})()');
        assert.deepEqual(accountFilter.headings,['Account 02'],'Healthy unchanged account still appears in Fix');
        assert.deepEqual(accountFilter.appliedHeadings,accountFilter.headings,'Account Findings/Applied records do not correspond');
        assert.ok(accountFilter.findings.includes('SupportAdmin')&&!accountFilter.findings.includes('Account Name: Administrator'),'Fix account identity filter is incorrect');
        assert.deepEqual(accountFilter.commands,['lusrmgr.msc','net user "SupportAdmin"'],'Fix retained a command for an omitted healthy account');
        const baselineAlignment=await verifyRecordAlignment();
        const baselineWrappers=await evaluate(frameDoc+'.querySelectorAll(".aligned-record").length');
        assert.equal(await evaluate(frameDoc+'.querySelectorAll(".aligned-record .aligned-record").length'),0,'Record wrappers are nested');
        if(c===0){
          await evaluate('(()=>{const d='+frameDoc+';const row=Array.from(d.querySelectorAll("table.checks tr")).find(r=>r.querySelector(".device-title")?.textContent==="Legacy Payment Services");const extra=d.createElement("div");extra.id="alignment-stress-note";extra.textContent="Long recorded action details with different content lengths. ".repeat(75);row.cells[3].querySelector(".applied-result").appendChild(extra);})()');
          await waitFor('('+alignedRecords+')[1][0].height>'+baselineAlignment[1][0].height+'+100');
          await verifyRecordAlignment();
          for(const width of [1024,390,1440]){
            await send('Emulation.setDeviceMetricsOverride',{width,height:1050,deviceScaleFactor:1,mobile:width===390});
            await verifyRecordAlignment();
          }
          await evaluate(frameDoc+'.getElementById("alignment-stress-note").remove()');
          await waitFor('Math.abs(('+alignedRecords+')[0][0].height-'+baselineAlignment[0][0].height+')<=1');
          await verifyRecordAlignment();
          await evaluate('(()=>{const d='+frameDoc+';const row=Array.from(d.querySelectorAll("table.checks tr")).find(r=>r.querySelector(".device-title")?.textContent==="Legacy Payment Services");window.alignmentOriginalNames=[row.cells[2],row.cells[3]].map(cell=>cell.querySelector(".config-item-title").textContent);[row.cells[2],row.cells[3]].forEach(cell=>cell.querySelector(".config-item-title").textContent="A longer actual legacy service name that wraps differently in the two report columns");})()');
          await verifyRecordAlignment();
          await evaluate('(()=>{const d='+frameDoc+';const row=Array.from(d.querySelectorAll("table.checks tr")).find(r=>r.querySelector(".device-title")?.textContent==="Legacy Payment Services");[row.cells[2],row.cells[3]].forEach((cell,index)=>cell.querySelector(".config-item-title").textContent=window.alignmentOriginalNames[index]);})()');
          await waitFor('Math.abs(('+alignedRecords+')[0][0].height-'+baselineAlignment[0][0].height+')<=1');
          await verifyRecordAlignment();
          assert.equal(await evaluate(frameDoc+'.querySelectorAll(".aligned-record").length'),baselineWrappers,'Repeated alignment duplicated record wrappers');
          assert.equal(await evaluate(frameDoc+'.querySelectorAll(".aligned-record .aligned-record").length'),0,'Repeated alignment nested record wrappers');
          await evaluate('Array.from('+frameDoc+'.querySelectorAll(".device-title")).find(e=>e.textContent==="Legacy Payment Services").closest("tr").scrollIntoView({block:"start"})');
          await screenshot('Aligned-Service-Blocks.png');
          await evaluate('scrollTo(0,0)');
        }
        const applied=await evaluate('(()=>{const d='+frameDoc+';return {labels:Array.from(d.querySelectorAll(".applied-result strong"),e=>e.textContent),appSettings:Array.from(d.querySelectorAll("table.checks")).some(t=>t.getAttribute("aria-label")==="AppSettings Check")};})()');
        for(const label of ['Completed','No Change Needed','Manual Action Required'])assert.ok(applied.labels.includes(label),'Missing Applied outcome: '+label);
        assert.equal(applied.appSettings,false,'Healthy read-only data remains in Fix');
        if(c===0){
          await screenshot('Applied-Report-Preview.png');
          await evaluate(frameDoc+'.querySelectorAll("table.checks")[2].scrollIntoView({block:"start"})');
          await screenshot('Applied-Services-Preview.png');
          await evaluate(frameDoc+'.querySelectorAll("table.checks")[1].scrollIntoView({block:"start"})');
          await screenshot('Block-Header-Accounts.png');
          await evaluate('scrollTo(0,0)');
        }
        await evaluate('(()=>{const w=document.getElementById("report-frame").contentWindow;w.testCopied=[];Object.defineProperty(w.navigator,"clipboard",{configurable:true,value:{writeText(t){w.testCopied.push(t);return Promise.resolve();}}});w.document.execCommand=function(c){if(c==="copy"){w.testCopied.push(w.document.activeElement.value);return true;}return false;};w.document.querySelector(".command-copy").click();})()');
        await waitFor('document.getElementById("report-frame").contentWindow.testCopied.length===1');
        assert.equal(await evaluate('document.getElementById("report-frame").contentWindow.testCopied[0]'),'control printers');
      }
      if(mode==='Final'){
        assert.equal(snapshot.commands,0);assert.ok(snapshot.statuses.every(s=>s.color==='rgb(34, 34, 34)'));
        await evaluate('window.printCalls=0;window.print=function(){window.printCalls++;};document.getElementById("print-final").click();');
        assert.equal(await evaluate('window.printCalls'),1);
        if(c===0){
          await screenshot('Combined-Report-Desktop.png');
          await evaluate('Array.from('+frameDoc+'.querySelectorAll(".device-title")).find(e=>e.textContent==="Payment Gateway").closest("table").scrollIntoView({block:"start"})');
          await screenshot('Final-Services-Recovery.png');
          await evaluate('Array.from('+frameDoc+'.querySelectorAll(".device-title")).find(e=>e.textContent==="Legacy Payment Services").closest("tr").scrollIntoView({block:"start"})');
          await screenshot('Legacy-Payment-Services.png');
          await evaluate('scrollTo(0,0)');
        }
      }
      results.push({client:client.ClientType,mode,embedded:true,columnsPassed:true,printOnlyFinal:true,htmlExportRemoved:true,legacyServicesGrouped:true,actualServiceNamesPreserved:true,recordDividersVisible:true});
    }
  }
  // Header, tabs and frame share one responsive container at every viewport.
  await evaluate('document.getElementById("bundle-client").value="0";document.getElementById("bundle-client").dispatchEvent(new Event("change"));document.getElementById("tab-Audit").click();');
  await waitFor(frameDoc+'?.querySelector("h1")?.textContent==="THOROUGH CHECK AUDIT REPORT"');
  const responsiveWidths=[];
  for(const width of [1920,1440,1280,1024,768,390]){
    await send('Emulation.setDeviceMetricsOverride',{width,height:1050,deviceScaleFactor:1,mobile:width===390});
    const expected=Math.min(1200,width-(width<=700?24:48));
    await waitFor('Math.abs(document.getElementById("report-frame").getBoundingClientRect().width-'+expected+')<1');
    const layout=await evaluate('(()=>{const f=document.getElementById("report-frame"),r=f.getBoundingClientRect(),d=f.contentDocument,main=d.querySelector(".report").getBoundingClientRect(),padding=parseFloat(d.defaultView.getComputedStyle(d.body).paddingLeft);return {viewport:innerWidth,frame:{left:r.left,right:r.right,width:r.width},aligned:[".bundle-intro",".bundle-toolbar",".bundle-description"].map(s=>{const b=document.querySelector(s).getBoundingClientRect();return {selector:s,left:b.left,right:b.right};}),outerOverflow:document.documentElement.scrollWidth>innerWidth,innerOverflow:d.documentElement.scrollWidth>d.documentElement.clientWidth,contentWidth:main.width,availableContentWidth:d.documentElement.clientWidth-padding*2};})()');
    assert.ok(layout.aligned.every(r=>Math.abs(r.left-layout.frame.left)<1&&Math.abs(r.right-layout.frame.right)<1),'Header/tabs/report alignment differs');
    assert.equal(layout.outerOverflow,false,'Page has horizontal overflow');
    assert.equal(layout.innerOverflow,false,'Report content overflows its frame');
    assert.ok(Math.abs(layout.contentWidth-Math.min(1000,layout.availableContentWidth))<1,'Inner report does not respect its 1000px responsive cap');
    responsiveWidths.push(layout);
    if(width===1440||width===390)await screenshot('Responsive-Width-'+width+'.png');
  }
  await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1050,deviceScaleFactor:1,mobile:false});
  // Native browser printing must always use only Final, even while Audit is selected.
  await evaluate('document.getElementById("bundle-client").value="0";document.getElementById("bundle-client").dispatchEvent(new Event("change"));document.getElementById("tab-Audit").click();');
  await waitFor(frameDoc+'?.querySelector("h1")?.textContent==="THOROUGH CHECK AUDIT REPORT"');
  await send('Emulation.setEmulatedMedia',{media:'print'});
  const printed=await evaluate('(()=>{const root=document.getElementById("print-report"),styles=e=>getComputedStyle(e);return {text:root.textContent,heading:root.querySelector("h1").textContent,visible:styles(root).display,frame:styles(document.getElementById("report-frame")).display,toolbar:styles(document.querySelector(".bundle-header")).display,sections:root.querySelectorAll("table.checks").length};})()');
  assert.equal(printed.heading,'THOROUGH CHECK REPORT');assert.equal(printed.visible,'block');assert.equal(printed.frame,'none');assert.equal(printed.toolbar,'none');assert.equal(printed.sections,5);assert.ok(!/Required Configuration|THOROUGH CHECK AUDIT REPORT|No change needed/.test(printed.text));
  assert.equal(await evaluate('getComputedStyle(document.querySelector("#print-report .report")).maxWidth'),'1280px','Screen width cap leaked into Print');
  const printGeometry='(()=>Array.from(document.querySelectorAll("#print-report .report,#print-report table,#print-report tr"),e=>{const r=e.getBoundingClientRect();return {tag:e.tagName,left:r.left,top:r.top,width:r.width,height:r.height};}))()';
  const printWithScreenRule=await evaluate(printGeometry);
  const screenRuleRemoved=await evaluate('(()=>{const style=document.getElementById("final-print-style");window.printWidthOriginalStyles=style.textContent;const rule="@media screen { .report { max-width: 1000px; } }";if(!style.textContent.includes(rule))return false;style.textContent=style.textContent.replace(rule,"");return true;})()');
  assert.equal(screenRuleRemoved,true,'Expected a screen-only report width rule');
  assert.deepEqual(await evaluate(printGeometry),printWithScreenRule,'Screen-only width changed print row/table geometry');
  await evaluate('document.getElementById("final-print-style").textContent=window.printWidthOriginalStyles;delete window.printWidthOriginalStyles;');
  await screenshot('Final-Print-Preview.png');
  const pdf=await send('Page.printToPDF',{printBackground:false,displayHeaderFooter:false,preferCSSPageSize:true});
  const bytes=Buffer.from(pdf.data,'base64');assert.equal(bytes.subarray(0,5).toString(),'%PDF-');assert.ok(bytes.length>10000);await writeFile(join(exportsRoot,'Thorough Check Report - SaaS - Sample.pdf'),bytes);
  await send('Emulation.setEmulatedMedia',{media:''});
  // Original reports hide Client and expose Audit-derived views without a Fix run.
  for(const client of ['SaaS','Subway']){
    await navigate('../audit-based-reports/'+client+'-Audit-Based-Report.html');
    assert.equal(await evaluate('document.getElementById("bundle-client")'),null,'Original report contains a Client selector');
    for(const mode of ['Audit','Fix','Final']){
      await evaluate('document.getElementById("tab-'+mode+'").click()');
      await waitFor(frameDoc+'?.querySelector("table.checks")');
      const view=await evaluate('(()=>{const d='+frameDoc+';return {text:d.body.textContent,title:d.querySelector("h1").textContent,columns:Array.from(d.querySelector("table.checks").tHead.rows[1].cells,c=>c.textContent),completed:!!Array.from(d.querySelectorAll(".applied-result strong")).find(e=>e.textContent==="Completed"),colored:!!d.querySelector(".finding-value"),printHidden:document.getElementById("final-actions").hidden};})()');
      assert.ok(!view.text.includes('has not been run'));
      if(mode==='Fix'){
        assert.ok(view.text.includes('Visual Search: Enabled')&&view.text.includes('Required: Disabled')&&view.text.includes('Not Applied'));
        assert.ok(!view.text.includes('Translation: Disabled'));assert.equal(view.completed,false);
        assert.deepEqual(view.columns,['Component','Shortcut / Command','Findings','Applied']);
        if(client==='SaaS')await screenshot('Audit-Based-Fix-Preview.png');
      }
      if(mode==='Final'){
        assert.ok(view.text.includes('Translation: Disabled')&&view.text.includes('Visual Search: Enabled'));
        assert.equal(view.colored,false);assert.equal(view.printHidden,false);
        assert.deepEqual(view.columns,['Component','Final Configuration','Status']);
        const printState=await evaluate('(()=>{const root=document.getElementById("print-report");return {title:root.querySelector("h1").textContent,text:root.textContent};})()');
        assert.equal(printState.title,'THOROUGH CHECK REPORT');assert.ok(printState.text.includes('Visual Search: Enabled'));
        if(client==='SaaS')await screenshot('Audit-Based-Final-Preview.png');
      }
    }
    await navigate('../audit-based-reports/'+client+'-After-Fix-Report.html');
    await evaluate('document.getElementById("tab-Fix").click()');
    await waitFor(frameDoc+'?.querySelector(".fix-no-change")');
    assert.ok(await evaluate(frameDoc+'.body.textContent.includes("No further fix needed.")'));
    await evaluate('document.getElementById("tab-Final").click()');
    await waitFor(frameDoc+'?.body?.textContent?.includes("POST-FIX")');
    assert.ok(await evaluate(frameDoc+'.body.textContent.includes("Visual Search: Disabled")'));
    await navigate('../fix-component-filter/'+client+'-No-Fixes-Preview.html');
    await waitFor(frameDoc+'?.querySelector(".fix-empty")?.textContent==="No fixes required."');
    assert.equal(await evaluate(frameDoc+'.querySelectorAll("table.checks").length'),0,'Empty Fix has section/table scaffolding');
    if(client==='SaaS')await screenshot('No-Fixes-Required-Preview.png');
    await evaluate('document.getElementById("tab-Final").click()');
    await waitFor(frameDoc+'?.querySelector("table.checks")');
    assert.equal(await evaluate('document.getElementById("final-actions").hidden'),false);
  }
  // Per-account Audit fallback filters healthy siblings while Audit/Final remain complete.
  for(const client of ['SaaS','Subway']){
    await navigate('../fix-account-records/'+client+'-Fix-Account-Preview.html');
    assert.equal(await evaluate('document.getElementById("bundle-client")'),null);
    for(const mode of ['Fix','Audit','Final']){
      await evaluate('document.getElementById("tab-'+mode+'").click()');
      await waitFor(frameDoc+'?.documentElement?.getAttribute("data-block-alignment")==="ready"');
      const accounts=await evaluate('(()=>{const d='+frameDoc+';const row=Array.from(d.querySelectorAll("table.checks tr")).find(r=>r.querySelector(".device-title")?.textContent==="Administrative Accounts");return {headings:Array.from(row.querySelectorAll("td")['+(mode==='Audit'?3:mode==='Fix'?2:1)+'].querySelectorAll(".config-item-title"),e=>e.textContent),commands:Array.from(row.querySelectorAll(".command-copy"),e=>e.dataset.command),text:row.textContent};})()');
      assert.deepEqual(accounts.headings,mode==='Fix'?['Account 02']:['Account 01','Account 02']);
      if(mode==='Fix'){
        assert.deepEqual(accounts.commands,['lusrmgr.msc','net user "Admin"']);
        assert.ok(!accounts.text.includes('Administrator')&&accounts.text.includes('Not Applied'));
        if(client==='SaaS')await screenshot('Fix-Account-Filter-Preview.png');
      }
    }
  }
  // Approved hostname/account/history changes use actual rendered before/after fixtures.
  for(const client of ['SaaS','Subway']){
    await navigate('../approved-report-fixes-20261024/'+client+'-Approved-Fixes-Preview.html');
    for(const mode of ['Audit','Fix','Final']){
      await evaluate('document.getElementById("tab-'+mode+'").click()');
      await waitFor(frameDoc+'?.documentElement?.getAttribute("data-block-alignment")==="ready"');
      const check=await evaluate('(()=>{const d='+frameDoc+';const rows=Array.from(d.querySelectorAll("table.checks tr"));const row=name=>rows.find(r=>r.querySelector(".device-title")?.textContent===name);const field=(r,label)=>Array.from(r.cells['+(mode==='Audit'?3:mode==='Fix'?2:1)+'].querySelectorAll(".kv-label")).find(e=>e.textContent===label)?.parentElement;const launcher=row("Kiosk Launch Script"),agent=row("Zabbix Agent"),windows=row("Windows Update"),admin=row("Administrative Accounts"),app=row("WebApp/Shop Print");return {launcherText:launcher.textContent,launcherColor:field(launcher,"Host name:")?.className,agentText:agent.textContent,agentColor:field(agent,"Host Name:")?.className,windowsFinding:windows.cells['+(mode==='Audit'?3:mode==='Fix'?2:1)+'].textContent,windowsApplied:'+ (mode==='Fix'?'windows.cells[3].textContent':'null')+',adminFinding:admin.cells['+(mode==='Audit'?3:mode==='Fix'?2:1)+'].textContent,adminApplied:'+(mode==='Fix'?'admin.cells[3].textContent':'null')+',appColor:field(app,"IsKioskPrintingEnabled:")?.className,falseColor:field(app,"IsEnabled:")?.className,appApplied:'+(mode==='Fix'?'app.cells[3].textContent':'null')+',printText:document.getElementById("print-report").textContent,printHidden:document.getElementById("final-actions").hidden};})()');
      if(mode==='Final'){
        assert.ok(check.windowsFinding.includes('Startup type: Disabled'));
        assert.ok(check.adminFinding.includes('User Cannot Change Password: Enabled'));
        assert.ok(check.launcherText.includes('DEVICE-01')&&!check.launcherText.includes('OLD-DEVICE'));
        assert.ok(!check.launcherColor.includes('finding-')&&!check.appColor.includes('finding-'),'Final retained comparison colors');
        assert.equal(check.printHidden,false);
      }else{
        assert.ok(check.launcherColor.includes('finding-unverified')&&check.agentColor.includes('finding-unverified'),'A mismatched hostname lacks amber styling');
        assert.ok(check.launcherText.includes('OLD-DEVICE')&&check.agentText.includes('OLD-DEVICE'),'Original hostnames were replaced in Findings');
        assert.ok(check.appColor.includes('finding-unverified')&&check.falseColor.includes('finding-match'),'AppSettings missing/False styling is incorrect');
        assert.ok(check.windowsFinding.includes('Startup type: Manual'),'Original Windows Update finding was replaced');
        assert.ok(check.adminFinding.includes('User Cannot Change Password: Disabled'),'Original account finding was replaced');
      }
      if(mode==='Fix'){
        assert.ok(check.windowsApplied.includes('Completed')&&check.windowsApplied.includes('Startup set to Disabled'));
        assert.ok(check.adminFinding.includes('Account 02')&&!check.adminFinding.includes('Account 01'));
        assert.ok(check.adminApplied.includes('Completed')&&check.adminApplied.includes('Enabled User Cannot Change Password'));
        assert.ok(check.appApplied.includes('Expected values are not configured. Please check manually.'));
        assert.ok(check.printText.includes('Startup type: Disabled')&&!check.printText.includes('Startup type: Manual'),'Print uses pre-fix Findings instead of Final');
        if(client==='SaaS'){
          await screenshot('Approved-Original-Findings-Preview.png');
          await evaluate('Array.from('+frameDoc+'.querySelectorAll(".device-title")).find(e=>e.textContent==="Administrative Accounts").closest("tr").scrollIntoView({block:"start"})');
          await screenshot('Approved-Account-AppSettings-Preview.png');
        }
      }
    }
  }
  // Missing modes remain visibly unavailable and cannot expose another mode's controls.
  const partial=structuredClone(state.Catalog[0]);partial.Reports.Audit=null;partial.LatestMode='Audit';
  const missing=html.replace(/(<script id="thorough-report-state" type="application\/octet-stream">)[^<]+/,(_,prefix)=>prefix+Buffer.from(JSON.stringify(partial)).toString('base64'));
  await writeFile(join(root,'Missing-Audit-Combined.html'),missing);await navigate('Missing-Audit-Combined.html');
  await waitFor(frameDoc+'?.querySelector("h2")?.textContent==="Audit has not been run"');
  assert.equal(await evaluate('document.getElementById("final-actions").hidden'),true);
  await evaluate('document.getElementById("tab-Audit").dispatchEvent(new KeyboardEvent("keydown",{key:"End",bubbles:true}));');
  await waitFor(frameDoc+'?.querySelector(".metadata td")?.textContent==='+JSON.stringify(partial.Reports.Final.ReportId));
  assert.equal(await evaluate('document.activeElement.id'),'tab-Final');
  await send('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});
  assert.equal(await evaluate('document.documentElement.scrollWidth>innerWidth'),false);await screenshot('Combined-Report-Mobile.png');
  assert.deepEqual(errors,[],'Page raised JavaScript errors');assert.deepEqual(externalRequests,[],'Report requested external content');
  await writeFile(join(root,'browser-verification.json'),JSON.stringify({passed:true,results,responsiveWidths,screenWidthCapExcludedFromPrint:true,printGeometryUnchanged:true,externalRequests:0,finalOnlyNativePdf:true,pdfBytes:bytes.length,htmlExportRemoved:true,printLabel:'Print',missingModesTruthful:true,keyboardAndMobilePassed:true,artifactFiles:await readdir(exportsRoot)},null,2));
  console.log('PASS: Six embedded tabs; Print is the only Final action; HTML export removed; only Final prints via native PDF; clipboard, missing modes, keyboard and mobile checks passed.');
}catch(error){console.log(error.stack);process.exitCode=1;}
finally{socket.close();}
