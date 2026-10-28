window.runConfidenceLevelTests=async()=>{
  const results=[],q=s=>scope.querySelector(s);
  const expect=(ok,label)=>{if(!ok)throw Error(label);results.push('PASS '+label)};
  const poll=async(fn)=>{const until=performance.now()+5000;while(!fn()){if(performance.now()>until)throw Error('Timed out');await new Promise(r=>setTimeout(r,20))}};
  await poll(()=>q('[data-action="selectType"]'));q('[data-action="selectType"]').click();
  const form='[data-form-id="classifier-tagging-form-group-1"]';
  const select=q(form+' [data-field="minimumConfidence"]');
  expect(select.value==='4' && select.options.length===5,'new groups default to confidence 4');
  expect(!q(form+' [data-field="strictness"]')&&!q(form+' [data-field="minimumTagsOverride"]')&&!q(form+' [data-field="maximumTagsOverride"]'),'retired controls are absent');
  const model=()=>testState.assets.classifierTypes[0].tagging;
  for(const level of ['1','2','3','4','5']){
    const current=q(form+' [data-field="minimumConfidence"]');
    current.value=level;current.dispatchEvent(new Event('change',{bubbles:true}));
    try { await poll(()=>model().minimumConfidence===Number(level)); }
    catch { throw Error('confidence '+level+' did not save: '+JSON.stringify({model:model(),commands:commands.slice(-2)})); }
    await new Promise(r=>setTimeout(r,90));
    expect(q(form+' [data-field="minimumConfidence"]').value===level,'confidence '+level+' autosaves');
  }
  const rules=q(form+' [data-field="houseRules"]');
  rules.value='Keep my words';rules.dispatchEvent(new InputEvent('input',{bubbles:true}));
  pushSnapshot();
  expect(q(form+' [data-field="houseRules"]').value==='Keep my words','draft instructions survive snapshots');
  testState.assets.classifierTypes.push({id:'group-2',name:'Other group',treeID:'tree-1',applicablePlatformIDs:['reddit'],tagging:{minimumConfidence:4,houseRules:''},order:1});pushSnapshot();
  q('[data-action="selectType"][data-type-id="group-2"]').click();
  expect(q('[data-form-id="classifier-tagging-form-group-2"] [data-field="minimumConfidence"]').value==='4' && model().minimumConfidence===5,'groups retain independent confidence');
  expect(uiErrors.length===0,'no renderer errors');
  return results;
};
