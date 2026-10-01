window.runGroupDialTests = async () => {
  const results = [], q = s => scope.querySelector(s);
  const expect = (ok, label) => { if (!ok) throw Error(label); results.push('PASS ' + label); };
  const tick = () => new Promise(resolve => setTimeout(resolve, 25));
  testState.settings.localModels = { systemRAMGB: 16, modelLibrary: [
    {id:'fast-file', tier:'fast', displayName:'Qwen2.5 3B', ggufFileName:'fast.gguf', minimumRAMGB:8, downloadSizeBytes:2e9, state:{kind:'downloaded'}},
    {id:'balanced-file', tier:'balanced', displayName:'Qwen2.5 7B', ggufFileName:'balanced.gguf', minimumRAMGB:16, downloadSizeBytes:5e9, recommended:true, state:{kind:'downloaded'}},
    {id:'best-file', tier:'best', displayName:'Qwen2.5 14B', ggufFileName:'best.gguf', minimumRAMGB:24, downloadSizeBytes:9e9, state:{kind:'available'}}
  ]};
  testState.assets.classifierTypes.push({id:'group-2',name:'Other group',treeID:'tree-1',applicablePlatformIDs:['reddit'],localModel:{speedQuality:'fast',strictness:1,houseRules:''},researchEnabled:null,order:1});
  pushSnapshot(); await tick();
  q('[data-action="selectType"][data-type-id="group-1"]').click();
  q('[data-expand="type-more:group-1"] summary').click(); await tick();
  const form = q('[data-form-id="classifier-local-model-form-group-1"]');
  const radios = [...form.querySelectorAll('[data-field="speedQuality"]')];
  expect(radios.length===3 && radios.filter(r=>r.checked).map(r=>r.value).join()==='balanced', 'group starts with its own selected tier');
  expect(form.querySelectorAll('[data-field="strictness"]').length===5, 'all five strictness positions live inside the group');
  const best = form.querySelector('[data-action="downloadModel"][data-id="best-file"]');
  best.click(); await tick();
  expect(commands.at(-1).action==='downloadModel' && commands.at(-1).data.id==='best-file', 'group tier card downloads the shared catalog model');
  expect(testState.assets.classifierTypes[0].localModel.speedQuality==='balanced', 'download action does not change the selected tier');
  expect(form.querySelectorAll('[data-action="deleteModelFile"]').length===2 && form.querySelector('.dial-card-warning'), 'downloaded files and RAM warning appear on group cards');
  const grid = form.querySelector('.dial-card-grid'), box = grid.getBoundingClientRect();
  expect([...grid.children].every(c=>{const r=c.getBoundingClientRect();return r.left>=box.left-1 && r.right<=box.right+1;}), 'tier cards stay inside their group at this viewport width');
  const textarea = form.querySelector('[data-field="houseRules"]');
  textarea.focus();textarea.value='Keep my group vocabulary';textarea.dispatchEvent(new InputEvent('input',{bubbles:true}));
  pushSnapshot();
  expect(q('[data-form-id="classifier-local-model-form-group-1"] [data-field="houseRules"]').value==='Keep my group vocabulary', 'group rules draft survives an incoming model snapshot');
  await new Promise(resolve=>setTimeout(resolve,350));
  q('[data-action="selectType"][data-type-id="group-2"]').click();
  q('[data-expand="type-more:group-2"] summary').click();await tick();
  expect(q('[data-form-id="classifier-local-model-form-group-2"] [data-field="speedQuality"]:checked').value==='fast' && q('[data-form-id="classifier-local-model-form-group-2"] [data-field="houseRules"]').value==='', 'another group keeps its own tier and empty rules');
  q('[data-action="openUtilityPanel"]').click();
  expect(!q('.utility-settings-modal .dial-card-grid') && !q('.utility-settings-modal [data-field="houseRules"]'), 'Settings has no global dial or house-rule UI');
  q('[data-action="closeUtilityPanel"]').click();
  q('[data-action="selectType"][data-type-id="group-1"]').click();await tick();
  expect(uiErrors.length===0, 'no browser errors');
  return results;
};
