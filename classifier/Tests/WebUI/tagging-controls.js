window.runTaggingControlTests = async () => {
  const results = [], q = selector => scope.querySelector(selector);
  const check = (ok, label) => { if (!ok) throw Error(label); results.push('PASS ' + label); };
  const tick = () => new Promise(resolve => setTimeout(resolve, 60));
  q('[data-action="selectType"][data-type-id="group-1"]').click();
  const kinds = ['video', 'short', 'live', 'post'];
  check(kinds.every(kind => q(`[data-form-id="youtube-kinds-group-1"] [data-field="${kind}"]`)?.checked),
    'all four YouTube entry kinds start enabled in an existing group');
  const youtube = q('.classifier-type-panel [data-platform-choice][value="youtube"]');
  check(youtube?.checked && youtube.closest('.classifier-platform-option')?.querySelector('.classifier-platform-children'),
    'YouTube kinds are indented beneath the selected platform');
  q('[data-form-id="youtube-kinds-group-1"] [data-field="short"]').click(); await tick();
  check(commands.at(-1).action === 'saveYouTubeEntryTypes' && commands.at(-1).data.short === false
    && testState.assets.classifierTypes[0].enabledYouTubeEntryTypes.join(',') === 'video,live,post',
    'Shorts switch autosaves without changing the other kinds');
  q('[data-form-id="youtube-kinds-group-1"] [data-field="short"]').click(); await tick();
  check(testState.assets.classifierTypes[0].enabledYouTubeEntryTypes.length === 4,
    'Shorts can be re-enabled independently');
  for (const kind of kinds) q(`[data-form-id="youtube-kinds-group-1"] [data-field="${kind}"]`).click();
  await tick();
  check(testState.assets.classifierTypes[0].enabledYouTubeEntryTypes.length === 0 &&
    q('[data-platform-choice][value="youtube"]')?.checked, 'YouTube may remain selected with zero content kinds');
  q('.classifier-type-panel [data-platform-choice][value="youtube"]').click(); await tick();
  check(testState.assets.classifierTypes[0].applicablePlatformIDs.length === 0 &&
    !q('[data-form-id="youtube-kinds-group-1"]'), 'group may have zero platforms');
  q('.classifier-type-panel [data-platform-choice][value="youtube"]').click(); await tick();
  check(testState.assets.classifierTypes[0].applicablePlatformIDs.join(',') === 'youtube' &&
    testState.assets.classifierTypes[0].enabledYouTubeEntryTypes.length === 0,
    'reselecting YouTube keeps its content kind choices');
  q('[data-action="newType"]').click();
  check(q('[data-create-type-dialog]'), 'new group dialog opens with platform choices');
  q('[data-create-type-dialog] [data-platform-choice]:checked')?.click();
  q('[data-action="confirmCreateType"]').click(); await tick();
  check(commands.at(-1).action === 'createClassifierType' &&
    commands.at(-1).data.platformIDs.length === 0,
    'new group can be created with zero platforms');
  q('[data-action="selectType"][data-type-id="group-1"]').click();
  let pause = q('[data-action="setClassifierTypePaused"]');
  check(pause && !pause.closest('details') && pause.textContent === 'Pause tagging', 'group pause is visible outside More and new groups start active');
  pause.click(); await tick();
  check(commands.at(-1).action === 'setClassifierTypePaused' && commands.at(-1).data.paused === true, 'group pause uses the native action');
  check(testState.assets.classifierTypes[0].isPaused === true && q('[data-action="setClassifierTypePaused"]').textContent === 'Resume tagging', 'native snapshot preserves paused state and offers Resume');
  q('[data-action="setClassifierTypePaused"]').click(); await tick();
  check(testState.assets.classifierTypes[0].isPaused === false, 'Resume reactivates the same group');
  q('[data-action="openUtilityPanel"]').click();
  let toggle = q('[data-form-id="classification-settings-form"] [data-field="classificationEnabled"]');
  check(toggle?.checked === true, 'Classifier Settings contains the enabled global tagging switch');
  const concurrency = q('[data-form-id="classification-settings-form"] [data-field="maximumConcurrentTaggingRequests"]');
  check(concurrency?.value === '16' && !concurrency.hasAttribute('max'), 'tagging request limit defaults to 16 without a fixed maximum');
  concurrency.value = '48'; concurrency.dispatchEvent(new Event('input', {bubbles:true})); await tick();
  concurrency.dispatchEvent(new Event('change', {bubbles:true})); await tick();
  check(testState.settings.maximumConcurrentTaggingRequests === 48, 'tagging request limit autosaves above 32');
  toggle = q('[data-form-id="classification-settings-form"] [data-field="classificationEnabled"]');
  toggle.click(); await tick();
  check(commands.at(-1).action === 'saveClassificationSettings' && testState.settings.classificationEnabled === false, 'global tagging disable autosaves natively');
  check(testState.assets.classifierTypes[0].isPaused === false, 'global disable preserves independent group pause state');
  q('[data-action="closeUtilityPanel"]').click();
  check(q('.classifier-tagging-control').textContent.includes('Disabled in Settings'), 'group explains the global disabled state');
  q('[data-action="openUtilityPanel"]').click();
  q('[data-form-id="classification-settings-form"] [data-field="classificationEnabled"]').click(); await tick();
  check(testState.settings.classificationEnabled === true, 'global enable restores tagging');
  check(uiErrors.length === 0, 'no browser errors');
  return results;
};
