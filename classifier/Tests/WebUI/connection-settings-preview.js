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
  const connection=settings.querySelector('[data-field="connectionType"]');
  connection.nextElementSibling.querySelector('.vui-select-button').click();
  await new Promise(r=>requestAnimationFrame(r));
  const option=[...document.querySelectorAll('.vui-menu-item')].find(node=>node.textContent==='OpenAI API');
  if(!option)throw Error('Missing shared connection menu');
  option.click();
  await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
  if(settings.querySelector('[data-field="connectionType"]').options.length!==4)throw Error('Expected four choices');
  const modal=document.getElementById('settingsModal'),body=modal.querySelector('.settings-body');
  settings.querySelector('[data-tagging-connections]').scrollIntoView({block:'start'});
  await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
  if(body.scrollWidth>body.clientWidth+1)throw Error('Settings overflow');
  if(settings.querySelector('[data-field="credential"]').type!=='password'||settings.querySelector('[data-field="credential"]').value!=='fixture-not-a-real-key')throw Error('Stored key must be masked and retained');
  if(settings.querySelector('.provider-panel, .provider-panels, [data-action="createProviderProfile"], [data-action="confirmDeleteProviderProfile"]'))throw Error('Retired key-manager UI remains');
  if(settings.querySelectorAll('[data-field="credential"]').length!==1)throw Error('Expected one key field');
  const color=getComputedStyle(settings.host);
  if(color.backgroundImage!=='none'||color.backgroundColor!=='rgba(0, 0, 0, 0)')throw Error('Settings host must inherit its surrounding neutral surface');
  return ['PASS integrated Settings: shared selector, direct single key field, neutral surface, masked key, bounded layout'];
};
