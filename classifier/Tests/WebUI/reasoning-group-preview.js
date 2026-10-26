window.runReasoningGroupPreview = async () => {
  const scope=VaultScenes.scope('classifier');
  window.webkit ||= {messageHandlers:{}};const commands=[];window.webkit.messageHandlers.vaultClassifier={postMessage(message){commands.push(message)}};
  VaultClassifier.receive({presentationRevision:9100,workspace:'browserBridge',settings:{classificationEnabled:true,research:{enabled:false},dictionaries:{packs:[],contributionChoiceMade:true,contributionEnabled:false,creatorMode:'cache'}},backup:{},notices:{},assets:{
    classifierTypes:[{id:'group-preview',name:'Video topics',treeID:'t',datasetID:'d',applicablePlatformIDs:['youtube'],classificationProvider:'apiKey',apiKey:{profileID:'gemini-preview',model:'gemini-3.1-flash-lite',reasoningEffort:'low'},tagging:{strictness:3,houseRules:''},order:0}],
    trees:[{id:'t',name:'Topics',nodes:[],revision:1}],datasets:[{id:'d',name:'Videos',entries:[],revision:1}],bindings:[],collectionPlatforms:[{id:'youtube',name:'YouTube',classifiable:true}],knowledge:{creators:[],terms:[]},chatGPT:{connected:false,models:[]},apiKeyClassification:{requestsToday:0,failedProfileIDs:[]},
    providerProfiles:[{id:'gemini-preview',name:'Gemini key',type:'gemini',hasCredential:true}],providerProtocols:{},providerModelCatalogs:{'gemini-preview':['gemini-3.1-flash-lite','gemini-3.8-flash']},classificationModelCapabilities:{'api:gemini-preview:gemini-3.1-flash-lite':{searchCompatible:true,reasoningEfforts:['default','low','medium','high']},'api:gemini-preview:gemini-3.8-flash':{searchCompatible:true,reasoningEfforts:['default','low','medium','high']}}}});
  document.querySelector('[data-scene="classifier"]').click();
  await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
  scope.querySelector('[data-action="selectType"]').click();
  await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
  const form=scope.querySelector('[data-form-id="cloud-provider-group-preview"]'),model=form.querySelector('[data-field="providerModel"]'),effort=form.querySelector('[data-field="reasoningEffort"]');
  if(model.options.length!==3||effort.value!=='low'||effort.options.length!==4)throw Error('Model and reasoning controls missing');
  if(form.querySelector('[data-field="searchEnabled"]')||!form.querySelector('[data-search-always]'))throw Error('Search policy is not always enabled');
  form.scrollIntoView({block:'center'});
  await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
  const bounds=(form.closest('.type-detail-body')||form.parentElement).getBoundingClientRect();
  for(const input of [model,effort]){const visible=input.closest('label').querySelector('.vui-select-button')||input;const r=visible.getBoundingClientRect();if(!r.width||r.left<bounds.left-1||r.right>bounds.right+1)throw Error('Visible group control exceeds scene');}
  const button=effort.closest('label').querySelector('.vui-select-button');const hitBox=button.getBoundingClientRect(),hit=button.getRootNode().elementFromPoint(hitBox.left+hitBox.width/2,hitBox.top+hitBox.height/2);if(!button.contains(hit))throw Error('Reasoning control is obscured');button.click();
  const high=[...document.querySelectorAll('.vui-menu-item')].find(button=>button.textContent.trim()==='High');
  if(!high)throw Error('High effort is not reachable through the visible picker');high.click();
  await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
  if(effort.value!=='high'||!button.textContent.includes('High'))throw Error('Visible effort choice did not take effect');
  return ['PASS actual desktop group: model picker, four reasoning choices and always-enabled search'];
};
