const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const path=require('node:path');
const script=fs.readFileSync(path.join(__dirname,'../Sources/MacBlockerWebUI/WebAssets/chrome-shim.js'),'utf8');
const storage=new Map([['__cb_chrome_storage__',JSON.stringify({blockedGroups:[{id:'a'},{id:'b'}],ruleLog:[{group:'Old mixed log',message:'stale'}]})]]);
const create=()=>{
  const context=vm.createContext({console,URL,Date,Set,Math,Promise,setTimeout,clearTimeout,
    navigator:{language:'en'},localStorage:{getItem:key=>storage.get(key)||null,setItem:(key,value)=>storage.set(key,value)},
    location:{href:'http://localhost/popup.html',origin:'http://localhost'},addEventListener(){}});
  context.window=context;vm.runInContext(script,context);return context;
};
(async()=>{
  let context=create();
  const get=groupId=>context.chrome.runtime.sendMessage({type:'get-log-feed',groupId});
  assert.equal((await get('a')).entries.length,0,'mixed legacy buffer is discarded');
  const log=(groupId,message)=>({source:'v.log',groupId,group:'Same name',message});
  context.__cbApplyNativeRuleLog([log('b','B kept')]);
  context.__cbApplyNativeRuleLog(Array.from({length:240},(_,i)=>log('a',`A ${i}`)));
  context.__cbApplyNativeRuleLog([{groupId:'a',message:'engine error'},{source:'v.log',message:'no ID'}]);
  assert.equal((await get('a')).entries.length,200);
  assert.equal((await get('b')).entries[0].message,'B kept');
  const id=(await get('b')).entries[0].id;
  context.__cbApplyNativeStore({blockedGroups:[{id:'a'},{id:'b'}]});
  context=create();
  assert.equal((await get('b')).entries[0].id,id,'snapshot and reload preserve independent log store and stable IDs');
  await context.chrome.runtime.sendMessage({type:'clear-log-feed',groupId:'a'});
  assert.equal((await get('a')).entries.length,0);
  assert.equal((await get('b')).entries.length,1);
  assert.equal((await get()).entries.length,0);
  context.__cbApplyNativeStore({blockedGroups:[{id:'a'}]});
  assert.equal((await get('b')).entries.length,0,'deleted group drops its log');
  console.log('PASS native log IDs, per-rule retention, Clear, reload, snapshots and retired buffer guard');
})().catch(error=>{console.error(error);process.exitCode=1});
