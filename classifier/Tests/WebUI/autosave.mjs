import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import os from 'node:os';

const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const desktopAssets=process.env.UI_ASSET_ROOT ? path.resolve(process.env.UI_ASSET_ROOT) : null;
const types={'.html':'text/html','.js':'text/javascript','.css':'text/css'};
const server=http.createServer(async(req,res)=>{
  try{
    let requestPath=new URL(req.url,'http://localhost').pathname;
    const classifierAsset=requestPath.match(/^\/Sources\/MacBlockerWebUI\/WebAssets\/classifier\/(app\.js|app\.css|strings\.js|notice-language\.js)$/);
    if(classifierAsset && !desktopAssets)requestPath='/classifier/Sources/VaultClassifierApp/WebAssets/'+classifierAsset[1];
    if(desktopAssets && requestPath.startsWith('/classifier/Sources/VaultClassifierApp/WebAssets/'))requestPath='/Sources/MacBlockerWebUI/WebAssets/classifier/'+requestPath.split('/').pop();
    const desktopPath=desktopAssets && requestPath.startsWith('/Sources/MacBlockerWebUI/WebAssets/');
    const base=desktopPath ? desktopAssets : repo;
    const file=path.resolve(base,desktopPath ? requestPath.slice('/Sources/MacBlockerWebUI/WebAssets/'.length) : '.'+requestPath);
    if(!file.startsWith(base+path.sep))throw Error('Outside fixture root');
    res.setHeader('Content-Type',types[path.extname(file)]||'text/plain');
    res.end(await fs.readFile(file));
  }catch{res.writeHead(404);res.end();}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const url=`http://127.0.0.1:${server.address().port}${process.env.UI_TEST_PAGE || '/classifier/Tests/WebUI/autosave.html'}`;
let browser,context;
try{
  const playwrightPath=process.env.UI_PLAYWRIGHT_MODULE || path.join(os.homedir(),'agentic-tooling-test-env/lib/python3.14/site-packages/playwright/driver/package/index.mjs');
  const {chromium}=await import(pathToFileURL(playwrightPath).href);
  browser=await chromium.launch({headless:true,executablePath:process.env.UI_BROWSER_EXECUTABLE || path.join(os.homedir(),'chrome-testing/chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing')});
  context=await browser.newContext({viewport:{width:Number(process.env.UI_WIDTH)||1280,height:Number(process.env.UI_HEIGHT)||1000}});
  if(process.env.UI_INITIAL_STORAGE){
    await context.addInitScript(({storage,language,program})=>{
      localStorage.clear();
      for(const [key,value] of Object.entries(storage)) localStorage.setItem(key,value);
      window.__INTEGRATION_INITIAL_STORAGE=storage;
      window.__INTEGRATION_EXPECTED_LANGUAGE=language;
      window.__INTEGRATION_EXPECTED_PROGRAM=program;
    },{storage:JSON.parse(process.env.UI_INITIAL_STORAGE),language:process.env.UI_EXPECTED_LANGUAGE || 'en',program:process.env.UI_EXPECTED_PROGRAM || 'macapp'});
  }
  const page=await context.newPage();
  const evaluate=expression=>page.evaluate(expression);
  await page.goto(url);
  const until=Date.now()+10000;
  while(!await evaluate(process.env.UI_READY_EXPRESSION || 'typeof runAutosaveTests === "function"')){
    if(Date.now()>until)throw Error('Fixture did not load');
    await new Promise(r=>setTimeout(r,50));
  }
  if(process.env.UI_TEST_SCRIPT) await page.addScriptTag({content:await fs.readFile(process.env.UI_TEST_SCRIPT,'utf8')});
  for(const result of await evaluate(process.env.UI_TEST_EXPRESSION || (process.env.UI_TEST_SCRIPT ? 'runBoundedListTests()' : 'runAutosaveTests()')))console.log(result);
  if(process.argv[2]){
    if(!process.env.UI_TEST_SCRIPT) await evaluate('document.getElementById("host").shadowRoot.querySelectorAll(".editor-panel").forEach(node => node.scrollTop = 0)');
    await page.screenshot({path:process.argv[2]});
  }
  await page.setViewportSize({width:720,height:1000});
  await page.goto(`http://127.0.0.1:${server.address().port}/classifier/Tests/WebUI/activity.html`);
  const activityUntil=Date.now()+10000;
  while(!await evaluate('typeof runActivityTests === "function"')){
    if(Date.now()>activityUntil)throw Error('Activity fixture did not load');
    await new Promise(r=>setTimeout(r,50));
  }
  for(const result of await evaluate('runActivityTests()'))console.log(result);
  if(process.argv[2]){
    await page.screenshot({path:process.argv[2].replace(/\.png$/, '-activity-720.png')});
  }
  console.log('RESULT PASS');
}catch(error){console.error(error);process.exitCode=1}
finally{
  try { await context?.close(); } finally {
    try { await browser?.close(); } finally {
      await new Promise(resolve=>server.close(resolve));
    }
  }
}
