window.runBoundedListTests=async()=>{
  const results=[],q=s=>scope.querySelector(s), wait=()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
  const expect=(c,label)=>{if(!c)throw Error(label);results.push('PASS '+label)};
  const bounded=(list,label)=>{
    expect(list && getComputedStyle(list).overflowY==='auto' && list.scrollHeight>list.clientHeight,label+' scrolls inside its box');
    const height=list.clientHeight;
    list.scrollTop=list.scrollHeight;
    expect(list.scrollTop>0 && list.clientHeight===height,label+' exposes its last entry without growing');
  };
  testState.workspace='knowledge';
  testState.assets.knowledge.creators=[
    ...Array.from({length:763},(_,i)=>({id:'creator-'+i,subject:'youtube:handle:@creator'+i,name:'Creator '+i,platformID:'youtube',meaning:'Creator description '+i,writtenByUser:false})),
    ...Array.from({length:6},(_,i)=>({id:'reddit-'+i,subject:'reddit:community:source'+i,name:'Reddit source '+i,platformID:'reddit',meaning:'Reddit description '+i,writtenByUser:false})),
    ...Array.from({length:5},(_,i)=>({id:'bilibili-'+i,subject:'bilibili:'+i,name:'Bilibili source '+i,platformID:'bilibili',meaning:'Description '+i,writtenByUser:false}))
  ];
  testState.assets.knowledge.terms=Array.from({length:100},(_,i)=>({id:'term-'+i,subject:'Term '+i,meaning:'Meaning '+i,writtenByUser:true}));
  pushSnapshot();await wait();
  const creators=q('[data-list-key^="knowledge:creator:"]'),terms=q('[data-list-key="knowledge:term"]');
  expect(creators.children.length===763,'all 763 creators remain available');
  bounded(creators,'creators');bounded(terms,'terms');
  const creatorKey=creators.dataset.listKey,scroll=creators.scrollTop;
  testState.assets.knowledge.creators[0].meaning='Snapshot update';pushSnapshot();await wait();
  expect(Math.abs(q('[data-list-key="'+creatorKey+'"]').scrollTop-scroll)<2,'snapshot preserves the creator list scroll');
  const searchFor=key=>q('[data-vui-search-input="'+key+'"]');
  const typeSearch=(key,value)=>{const input=searchFor(key);input.value=value;input.dispatchEvent(new Event('input',{bubbles:true}));return input;};
  const visible=id=>!q('[data-id="'+id+'"]').classList.contains('vui-search-hidden');
  const termKey=terms.dataset.listKey,redditKey='knowledge:creator:reddit';
  expect(searchFor(creatorKey).closest('.vui-search').nextElementSibling===q('[data-list-key="'+creatorKey+'"]'),'Content sources search sits directly above its platform list');
  expect(!searchFor(creatorKey).closest('.vui-search').hidden && !searchFor(redditKey).closest('.vui-search').hidden,'six or more content sources show search for each platform');
  expect(searchFor('knowledge:creator:bilibili').closest('.vui-search').hidden,'five content sources stay simple');
  expect(!q('[data-knowledge-search-input]'),'no distant page-wide Knowledge search');
  searchFor(creatorKey).closest('.vui-search').querySelector('.vui-info-button').click();await wait();
  expect(document.querySelector('.vui-info-popover')?.textContent==='Find saved knowledge by name, identifier, or description.','Content sources search has the field-specific explanation');
  VaultInfo.close();
  const beforeSearch=JSON.stringify(testState.assets.knowledge),writesBefore=commands.length;
  typeSearch(creatorKey,'cReAtOr 762');
  expect(visible('creator-762') && !visible('creator-0'),'search reaches entries at the end of the list and ignores case');
  expect(q('[data-list-key="'+creatorKey+'"]').clientHeight<300,'one search result shrinks the box');
  expect(q('[data-list-key="'+creatorKey+'"]').closest('[data-knowledge-group]').querySelector('[data-knowledge-count]').textContent==='1 / 763','filtered count retains the full total');
  typeSearch(redditKey,'source5');typeSearch(termKey,'Term 99');
  expect(visible('reddit-5') && !visible('reddit-0') && visible('term-99') && !visible('term-0') && visible('creator-762'),'platform and Terms queries are independent');
  typeSearch(creatorKey,'youtube:handle:@creator762');expect(visible('creator-762'),'content source identifiers are searchable');
  const search=typeSearch(creatorKey,'description 762');search.focus();search.setSelectionRange(3,8);
  testState.issue='Knowledge snapshot';pushSnapshot();await wait();
  expect(scope.activeElement===searchFor(creatorKey) && scope.activeElement.value==='description 762' && scope.activeElement.selectionStart===3 && scope.activeElement.selectionEnd===8,'description query and caret survive native snapshots');
  expect(searchFor(redditKey).value==='source5' && searchFor(termKey).value==='Term 99','other list queries survive snapshots');
  typeSearch(creatorKey,'no-such-content-source');
  expect(!searchFor(creatorKey).closest('.vui-search').querySelector('.vui-search-empty').hidden && !visible('creator-762'),'content sources show an explicit no-match state');
  searchFor(creatorKey).closest('.vui-search').querySelector('.vui-search-clear').click();
  expect(visible('creator-0') && visible('creator-762') && searchFor(redditKey).value==='source5','clear restores only its own platform list');
  expect(JSON.stringify(testState.assets.knowledge)===beforeSearch && commands.length===writesBefore,'search sends no writes and preserves Knowledge data');
  typeSearch(termKey,'Term 0');
  const description=q('[data-id="term-0"] [data-field="meaning"]');
  description.focus();description.value='Draft nebula description';description.dispatchEvent(new Event('input',{bubbles:true}));
  testState.issue='Pending draft snapshot';pushSnapshot();await wait();
  expect(scope.activeElement?.value==='Draft nebula description','description edit focus and draft survive a snapshot');
  typeSearch(termKey,'nebula');expect(visible('term-0') && !visible('term-1'),'search matches the pending description draft');
  searchFor(termKey).closest('.vui-search').querySelector('.vui-search-clear').click();
  await new Promise(resolve=>setTimeout(resolve,350)); // Finish the draft's autosave acknowledgement before replacing fixture data.
  testState.assets.providerProfiles=Array.from({length:80},(_,i)=>({...testState.assets.providerProfiles[0],id:'provider-'+i,name:'Provider '+i}));
  pushSnapshot();await wait();q('[data-action="openUtilityPanel"]').click();await wait();bounded(q('[data-list-key="providers"]'),'API keys');
  const providers=q('[data-list-key="providers"]');expect(providers.children.length===80,'all API keys remain available');
  const input=providers.lastElementChild.querySelector('[data-field="customEndpoint"]');input.focus();input.value='https://example.test/last';input.dispatchEvent(new Event('input',{bubbles:true}));
  testState.issue='Synthetic snapshot';pushSnapshot();await wait();
  expect(scope.activeElement?.value==='https://example.test/last','editing the last entry preserves focus and draft through snapshots');
  expect(uiErrors.length===0,'no renderer exceptions');
  q('[data-action="closeUtilityPanel"]').click();
  testState.workspace='knowledge';testState.issue=null;pushSnapshot();await wait();
  for(const key of [creatorKey,termKey,redditKey]) typeSearch(key,'');
  q('[data-list-key^="knowledge:creator:"]').scrollTop=0;
  q('[data-list-key^="knowledge:creator:"]').parentElement.scrollIntoView({block:'start'});
  return results;
};
