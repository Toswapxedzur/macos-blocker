const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const path=require('node:path');
const script=fs.readFileSync(path.join(__dirname,'../Sources/MacBlockerWebUI/WebAssets/chrome-shim.js'),'utf8');
const storage=new Map([['__cb_chrome_storage__',JSON.stringify({blockedGroups:[{id:'a'},{id:'b'}],ruleLog:[{group:'Old mixed log',message:'stale'}]})]]);
const create=(programID="macapp")=>{
  const context=vm.createContext({console,URL,Date,Set,Math,Promise,setTimeout,clearTimeout,
    navigator:{language:'en'},localStorage:{getItem:key=>storage.get(key)||null,setItem:(key,value)=>storage.set(key,value)},
    location:{href:'http://localhost/popup.html',origin:'http://localhost'},addEventListener(){}});
  context.window=context;context.__CB_DESKTOP_PROGRAM_ID=programID;vm.runInContext(script,context);return context;
};
(async()=>{
  let context=create();
  assert.equal(typeof context.__cbSaveRuleLog,'function','Mac uses its native export');
  assert.equal(typeof create('windowsapp').__cbSaveRuleLog,'undefined','Windows retains its WebView Blob download instead of an unsupported Mac message');
  const get=groupId=>context.chrome.runtime.sendMessage({type:'get-log-feed',groupId});
  assert.equal((await get('a')).entries.length,0,'mixed legacy buffer is discarded');
  const log=(groupId,message)=>({source:'v.log',groupId,group:'Same name',message});
  context.__cbApplyNativeRuleLog([log('b','B kept')]);
  context.__cbApplyNativeRuleLog(Array.from({length:240},(_,i)=>log('a',`A ${i}`)));
  context.__cbApplyNativeRuleLog([{groupId:'a',message:'engine error'},{source:'v.log',message:'no ID'}]);
  assert.equal((await get('a')).entries.length,200);
  assert.equal((await get('b')).entries[0].message,'B kept');
  context.__cbApplyNativeRuleLog([{source:'page-error',level:'error',groupId:'b',eventType:'panel',message:'handler failed'},
    {source:'v.log',level:'error',groupId:'a',message:'save refused'}]);
  const error=(await get('b')).entries[1];
  assert.equal(error.source,'page-error');assert.equal(error.level,'error');
  assert.equal(error.eventType,'panel');assert.equal(error.message,'handler failed');
  assert.equal((await get('a')).entries.at(-1).level,'error');
  const id=(await get('b')).entries[0].id;
  context.__cbApplyNativeStore({blockedGroups:[{id:'a'},{id:'b'}]});
  context=create();
  assert.equal((await get('b')).entries[0].id,id,'snapshot and reload preserve independent log store and stable IDs');
  assert.equal((await get('b')).entries[1].id,error.id,'explicit errors survive snapshot and recreation');
  assert.equal((await get('b')).entries[1].level,'error');
  await context.chrome.runtime.sendMessage({type:'clear-log-feed',groupId:'a'});
  assert.equal((await get('a')).entries.length,0);
  assert.equal((await get('b')).entries.length,2);
  assert.equal((await get()).entries.length,0);
  context.__cbApplyNativeStore({blockedGroups:[{id:'a'}]});
  assert.equal((await get('b')).entries.length,0,'deleted group drops its log');
  console.log('PASS explicit error source/level/recreation, native log IDs, per-rule retention, Clear, reload, snapshots and retired buffer guard');
})().catch(error=>{console.error(error);process.exitCode=1});
