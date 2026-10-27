async function runIntegratedSettingsTests() {
  const results=[],check=(ok,label)=>{if(!ok)throw Error(label);results.push('PASS '+label)};
  const until=async fn=>{const end=performance.now()+5000;while(!fn()){if(performance.now()>end)throw Error('Timed out');await new Promise(r=>setTimeout(r,20))}};
  const scene=VaultScenes.scope('classifier'),settings=VaultSettings.scope;
  const snapshot={presentationRevision:8000,workspace:'knowledge',settings:{classificationEnabled:true,research:{enabled:true},dictionaries:{contributionEnabled:true}},assets:{classifierTypes:[],trees:[],datasets:[],bindings:[],collectionPlatforms:[],knowledge:{creators:[],terms:[]},providerProfiles:[],providerProtocols:{},providerModelCatalogs:{}},notices:{}};
  const commands=[];window.webkit ||= {messageHandlers:{}};window.webkit.messageHandlers.vaultClassifier ||= {postMessage(){}};
  const send=webkit.messageHandlers.vaultClassifier.postMessage;
  webkit.messageHandlers.vaultClassifier.postMessage=message=>{commands.push(structuredClone(message));if(message.action==='saveClassificationSettings')snapshot.settings.classificationEnabled=message.data.classificationEnabled;snapshot.presentationRevision++;VaultClassifier.receive(structuredClone(snapshot))};
  try {
    VaultClassifier.receive(structuredClone(snapshot));
    check(!scene.querySelector('[data-workspace="knowledge"]'),'stale Knowledge snapshots fall back to groups');
    const originalSettings=JSON.stringify(snapshot.settings);
    for(const locale of Object.keys(getAvailableLanguages())){
      await setLanguage(locale);await until(()=>scene.getElementById('app').lang===locale);
      const catalog=await VaultLoadMessages(locale);
      await until(()=>scene.querySelector('[data-editor-panel] h2')?.textContent.includes(catalog['classifier.bridge.title']));
      check(scene.getElementById('app').dir===(locale==='ar'?'rtl':'ltr'),locale+': shared language and direction');
      check(JSON.stringify(snapshot.settings)===originalSettings,locale+': language preserves native settings');
    }
    await setLanguage('en');await until(()=>scene.getElementById('app').lang==='en');
    const modal=document.getElementById('settingsModal');
    for(const name of ['vault','classifier','activity']){
      document.querySelector(`[data-scene="${name}"]`).click();
      const opener=name==='vault'?document.getElementById('settingsButton'):name==='classifier'?scene.querySelector('[data-action="openUtilityPanel"]'):VaultScenes.scope('activity').getElementById('activitySettingsButton');
      opener.focus();opener.click();await until(()=>!!settings.querySelector('[data-field="classificationEnabled"]'));
      check(!modal.classList.contains('hidden')&&document.body.dataset.scene===name,name+': opens shared Settings without switching scenes');
      check(settings.querySelector('[data-field="connectionType"]').options.length===4,name+': four connection choices');
      check(!settings.querySelector('.utility-dictionary-section, .utility-research-section')&&!!document.getElementById('settingsQuitRetryMinutes'),name+': current classifier and app preferences coexist');
      const body=modal.querySelector('.settings-body');check(body.scrollWidth<=body.clientWidth+1,name+': Settings fits viewport');
      VaultSettings.close();await until(()=>!settings.querySelector('[data-field="classificationEnabled"]'));
      const focusRoot=name==='vault'?document:VaultScenes.scope(name);check(focusRoot.activeElement?.matches(name==='classifier'?'[data-action="openUtilityPanel"]':name==='activity'?'#activitySettingsButton':'#settingsButton'),name+': closing restores its current opener');
    }
    check(!commands.some(x=>/Dictionary|Knowledge|Research/.test(x.action)),'stale fields never dispatch dormant actions');
    return results;
  } finally {webkit.messageHandlers.vaultClassifier.postMessage=send;await setLanguage('en');}
}
