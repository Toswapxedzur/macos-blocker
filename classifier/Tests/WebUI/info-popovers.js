async function runInfoPopoverTests() {
  const scope=VaultScenes.scope('classifier'),q=s=>scope.querySelector(s),results=[];
  const check=(ok,label)=>{if(!ok)throw Error(label);results.push('PASS '+label)};
  const tick=()=>new Promise(r=>setTimeout(r,60));
  q('[data-action="selectType"]').click();await tick();
  const help=q('[data-info-key="bridge.localModelHouseRules"] .vui-info-button');
  check(!!help,'tagging instructions have contextual Info');
  const before=commands.length;help.click();await tick();
  check(!!document.querySelector('.vui-info-popover'),'Info opens its explanation');
  check(commands.length===before,'opening Info does not change group settings');
  const draft=q('[data-field="houseRules"]');draft.focus();draft.value='Keep terminology';draft.dispatchEvent(new InputEvent('input',{bubbles:true}));
  pushSnapshot();await tick();check(q('[data-field="houseRules"]').value==='Keep terminology','Info and snapshots preserve the rule draft');
  VaultInfo.close();q('[data-action="newType"]').click();await tick();
  const create=q('[data-create-type-dialog]');
  check(!!create.querySelector('[data-info-key="createType.nameLabel"] .vui-info-button'),'creation retains field help');
  q('[data-action="cancelCreateType"]').click();await tick();
  check(!q('[data-workspace="knowledge"], .utility-dictionary-section'),'no help controls reactivate dormant features');
  check(uiErrors.length===0,'contextual Info produces no renderer errors');
  return results;
}
