import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const types={'.html':'text/html','.js':'text/javascript','.css':'text/css'};
const server=http.createServer(async(req,res)=>{
  try{
    const file=path.resolve(repo,'.'+new URL(req.url,'http://localhost').pathname);
    if(!file.startsWith(repo+path.sep))throw Error('Outside fixture root');
    res.setHeader('Content-Type',types[path.extname(file)]||'text/plain');
    res.end(await fs.readFile(file));
  }catch{res.writeHead(404);res.end();}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const url=`http://127.0.0.1:${server.address().port}/classifier/Tests/WebUI/autosave.html`;
let target,ws;
try{
  target=await (await fetch('http://127.0.0.1:9222/json/new?'+encodeURIComponent(url),{method:'PUT'})).json();
  ws=new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',reject,{once:true})});
  let id=0;const waiting=new Map();
  ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(waiting.has(m.id)){waiting.get(m.id)(m);waiting.delete(m.id)}});
  const call=(method,params={})=>new Promise(resolve=>{const key=++id;waiting.set(key,resolve);ws.send(JSON.stringify({id:key,method,params}))});
  const evaluate=async expression=>{
    const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});
    if(r.error||r.result.exceptionDetails)throw Error(JSON.stringify(r.error||r.result.exceptionDetails));
    return r.result.result.value;
  };
  await call('Page.enable');
  await call('Emulation.setDeviceMetricsOverride',{width:Number(process.env.UI_WIDTH)||1280,height:Number(process.env.UI_HEIGHT)||1000,deviceScaleFactor:1,mobile:false});
  const until=Date.now()+10000;
  while(!await evaluate('typeof runAutosaveTests === "function"')){
    if(Date.now()>until)throw Error('Fixture did not load');
    await new Promise(r=>setTimeout(r,50));
  }
  if(process.env.UI_TEST_SCRIPT) await evaluate(await fs.readFile(process.env.UI_TEST_SCRIPT,'utf8'));
  for(const result of await evaluate(process.env.UI_TEST_SCRIPT ? 'runBoundedListTests()' : 'runAutosaveTests()'))console.log(result);
  if(process.argv[2]){
    if(!process.env.UI_TEST_SCRIPT) await evaluate('document.getElementById("host").shadowRoot.querySelectorAll(".editor-panel").forEach(node => node.scrollTop = 0)');
    const shot=await call('Page.captureScreenshot',{format:'png'});
    await fs.writeFile(process.argv[2],Buffer.from(shot.result.data,'base64'));
  }
  console.log('RESULT PASS');
}catch(error){console.error(error);process.exitCode=1}
finally{
  ws?.close();
  if(target?.id)await fetch(`http://127.0.0.1:9222/json/close/${target.id}`).catch(()=>{});
  server.close();
}
