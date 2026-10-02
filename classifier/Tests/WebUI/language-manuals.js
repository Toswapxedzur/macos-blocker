async function runLanguageManualTests() {
  const results=[];
  const check=(ok,label)=>{if(!ok)throw Error(label);results.push(label);};
  const delay=()=>new Promise(resolve=>setTimeout(resolve,150));
  await setLanguage('en');
  const classifierState = {presentationRevision:1,workspace:'browserBridge',settings:{research:{enabled:false},localModels:{modelLibrary:[]}},assets:{classifierTypes:[],trees:[],datasets:[],bindings:[],providerProfiles:[],collectionPlatforms:[],knowledge:{creators:[],terms:[]}},notices:{}};
  window.VaultClassifier.receive(classifierState);
  const classifier=VaultScenes.scope('classifier'), activity=VaultScenes.scope('activity');
  for(const [scene,scope,selector,heading] of [['classifier',classifier,'[data-action="openManual"]','Classifier'],['activity',activity,'#activityManualButton','Activity']]) {
    document.querySelector(`[data-scene="${scene}"]`).click(); await delay();
    let opener=scope.querySelector(selector); opener.focus();opener.click(); await delay();
    if (scene === 'classifier') {
      window.VaultClassifier.receive({...classifierState, workspace:"knowledge", presentationRevision:2}); await delay();
      check(!opener.isConnected, 'Classifier snapshot replaces the original opener');
      opener=scope.querySelector(selector);
    }
    const modal=document.getElementById('manualModal'),body=document.getElementById('manualContent');
    check(modal.getClientRects().length && !modal.classList.contains('hidden'),scene+' opens the shared manual');
    check([...body.querySelectorAll('h2')].some(node=>node.textContent===heading),scene+' manual contains its task guide');
    check(!body.querySelector('pre') && !body.textContent.includes('v.log'),scene+' user manual contains no code tutorial');
    body.querySelector('a[href="../code-manual/en.md"]').click();await delay();
    check(body.textContent.includes('Mac Vault code manual') && body.textContent.includes('v.block(appId') && !body.textContent.includes('v.item(tabId'),scene+' opens the Mac-specific code API');
    body.querySelector('a[href="../manual/en.md"]').click();await delay();
    document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));await delay();
    check(modal.classList.contains('hidden') && scope.activeElement===opener,scene+' returns focus to its manual button');
  }
  document.querySelector('[data-scene="vault"]').click();await delay();
  const group=createDefaultGroup('custom');group.id='manual-test';group.name='Manual test';
  state.groups=[group];state.selectedGroupId=group.id;render();
  let copied;Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async text=>{copied=text;}}});
  document.getElementById('copyCodeDocsButton').click();await delay();
  check(copied?.startsWith('# Mac Vault code manual') && copied.includes('v.block(appId'), 'Mac Copy code docs uses the native app API');
  return results;
}
