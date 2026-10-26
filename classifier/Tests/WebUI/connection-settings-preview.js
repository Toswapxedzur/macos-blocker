window.runConnectionSettingsPreview = async () => {
  const settings=VaultSettings.scope,scene=VaultScenes.scope('classifier');
  window.webkit ||= {messageHandlers:{}};window.webkit.messageHandlers.vaultClassifier ||= {postMessage(){}};
  const snapshot={presentationRevision:9000,workspace:'browserBridge',settings:{classificationEnabled:true,research:{enabled:false},dictionaries:{creatorMode:'cache',creatorCacheSize:10000,contributionEnabled:false,packs:[]}},backup:{},notices:{},assets:{
    classifierTypes:[],trees:[],datasets:[],bindings:[],collectionPlatforms:[],knowledge:{creators:[],terms:[]},
    chatGPT:{connected:false,models:[]},apiKeyClassification:{requestsToday:0,failedProfileIDs:[]},
    providerProfiles:[{id:'openai-preview',name:'OpenAI key',type:'openAI',defaultModelIdentifier:'gpt-4.1-mini',credential:'fixture-not-a-real-key',hasCredential:true}],
    providerProtocols:{openAI:{supportsGenerateText:true,supportsLLMConfiguration:true,supportsNativeWebSearch:true,credentialRequired:true,allowsEndpointOverride:false,configurationRequirements:[]}},
    providerModelCatalogs:{'openai-preview':[{id:'gpt-4.1-mini'}]}}};
  VaultClassifier.receive(snapshot);
  document.querySelector('[data-scene="classifier"]').click();
  scene.querySelector('[data-action="openUtilityPanel"]').click();
  await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
  settings.querySelector('[data-connection-type="openAI"]').click();
  await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
  if(settings.querySelectorAll('[data-action="selectConnection"]').length!==4)throw Error('Expected four choices');
  const modal=document.getElementById('settingsModal'),body=modal.querySelector('.settings-body');
  settings.querySelector('[data-tagging-connections]').scrollIntoView({block:'start'});
  await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
  if(body.scrollWidth>body.clientWidth+1)throw Error('Settings overflow');
  if(settings.querySelector('[data-field="credential"]').type!=='password'||settings.querySelector('[data-field="credential"]').value!=='fixture-not-a-real-key')throw Error('Stored key must be masked and retained');
  return ['PASS real desktop Settings: four connections, masked key, bounded layout'];
};
