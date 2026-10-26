window.runGroupDialTests = async () => {
  const results=[],q=s=>scope.querySelector(s),tick=()=>new Promise(r=>setTimeout(r,40));
  const expect=(ok,label)=>{if(!ok)throw Error(label);results.push('PASS '+label);};
  q('[data-action="selectType"][data-type-id="group-1"]').click();await tick();
  expect(!q('[data-field="speedQuality"]')&&!q('[data-action="downloadModel"]')&&!q('[data-action="deleteModelFile"]'),'Local tiers and model downloads are absent');
  expect(!q('option[value="local"]'),'Local provider is absent');
  const form=q('[data-form-id="classifier-tagging-form-group-1"]');
  expect(form.querySelectorAll('[data-field="strictness"]').length===5,'cloud tagging retains five strictness choices');
  const rules=form.querySelector('[data-field="houseRules"]');rules.focus();rules.value='Keep my group vocabulary';rules.dispatchEvent(new InputEvent('input',{bubbles:true}));pushSnapshot();
  expect(q('[data-field="houseRules"]').value==='Keep my group vocabulary','snapshots preserve tagging rule drafts');
  expect(uiErrors.length===0,'no browser errors');return results;
};
