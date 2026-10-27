async function runRuleAISettingsTests() {
  const results=[],check=(ok,label)=>{if(!ok)throw Error(label);results.push('PASS '+label);};
  const until=async fn=>{const end=performance.now()+5000;while(!fn()){if(performance.now()>end)throw Error('Timed out');await new Promise(resolve=>setTimeout(resolve,20));}};
  const send=chrome.runtime.sendMessage;
  const choices=[{value:'chatgpt:gpt-5',accountID:'fixture-account',label:'ChatGPT subscription · GPT-5',efforts:['default','low','medium','high']},
    {value:'api:key:gemini-3-flash-preview',accountID:'',label:'Gemini API · Flash',efforts:['default','low','medium','high']}];
  chrome.runtime.sendMessage=async message=>{
    if(message.type==='rule-ai-models')return {ok:true,models:choices};
    if(message.type==='editor-definition-edit') {
      const stored=(await chrome.storage.local.get({blockedGroups:[]})).blockedGroups;
      const {groups}=CBGroupScopes.applyEditorRequest(stored,message,LOCAL_OWNER);
      await chrome.storage.local.set({blockedGroups:groups});
      return {ok:true,groups};
    }
    return send(message);
  };
  const originalGroups=state.groups,originalSelection=state.selectedGroupId,originalDrafts=state.drafts;
  try {
    const group=createDefaultGroup('custom');group.name='AI rule fixture';
    await chrome.storage.local.set({blockedGroups:[group]});
    state.groups=[group];state.selectedGroupId=group.id;state.drafts={};render();
    document.getElementById('ruleAISettings').open=true;
    await until(()=>document.getElementById('ruleAIModel').options.length===3);
    const model=document.getElementById('ruleAIModel'),effort=document.getElementById('ruleAIEffort'),cap=document.getElementById('ruleAICap');
    check(model.value===''&&cap.value==='','new group has no inferred provider or daily cap');
    model.value=JSON.stringify([choices[0].value,choices[0].accountID]);model.dispatchEvent(new Event('change',{bubbles:true}));
    check(effort.options.length===4,'supported reasoning choices follow the selected model');
    effort.value='low';effort.dispatchEvent(new Event('change',{bubbles:true}));
    cap.value='7';cap.dispatchEvent(new Event('change',{bubbles:true}));
    const value=CBRuleAIUI.read();
    check(value.providerModel==='chatgpt:gpt-5'&&value.accountID==='fixture-account'&&value.reasoningEffort==='low'&&value.dailyRequestLimit===7,'one complete credential-free selection is captured');
    check(state.drafts[group.id].ruleAI.dailyRequestLimit===7,'AI fields enter the existing autosave draft');
    await flushAutosave();
    const saved=(await chrome.storage.local.get({blockedGroups:[]})).blockedGroups.find(item=>item.id===group.id);
    check(saved?.ruleAI?.dailyRequestLimit===7,'AI settings persist through the existing save path');
    renderEditorFields(Date.now());check(cap.value==='7'&&effort.value==='low','snapshot rendering retains the current AI draft');
    cap.value='';cap.dispatchEvent(new Event('change',{bubbles:true}));check(CBRuleAIUI.read().dailyRequestLimit===null,'blank cap remains optional');
    const invalid={...groupToDraft(group),ruleAI:{...value,dailyRequestLimit:1.5}};
    check(!!buildUpdatedGroupFromDraft(group,invalid).validationError,'fractional cap is refused by the editor');
    CBRuleAIUI.render(group,false,value,()=>{});check(model.disabled&&effort.disabled&&cap.disabled,'frozen group controls cannot change AI settings');
    CBRuleAIUI.render(group,true,{...value,providerModel:'api:removed:old-model'},()=>{});
    check(model.selectedOptions[0].textContent.includes('Unavailable'),'removed model stays visible without selecting a fallback');
    check(!document.getElementById('ruleAISettings').innerHTML.includes('credential'),'rule controls contain no credential field');
    const box=document.getElementById('ruleAISettings');check(box.scrollWidth<=box.clientWidth+1,'AI controls fit the current viewport');
    CBRuleAIUI.render(group,true,value,()=>{});
    return results;
  } finally {
    await flushAutosave().catch(()=>{});
    chrome.runtime.sendMessage=send;
    // Restore only the fixture's in-memory editor; browser context is disposable.
    state.groups=originalGroups;state.selectedGroupId=originalSelection;state.drafts=originalDrafts;
  }
}
