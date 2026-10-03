async function runIntegratedSettingsTests() {
  const results = [];

  const check = (ok, label) => { if (!ok) throw Error(label); results.push('PASS ' + label); };
  const until = async predicate => {
    const end = performance.now() + 5000;
    while (!predicate()) { if (performance.now() > end) throw Error('Timed out'); await new Promise(resolve => setTimeout(resolve, 20)); }
  };
  const scene = VaultScenes.scope('classifier'), settings = VaultSettings.scope;
  if (window.__INTEGRATION_INITIAL_STORAGE) {
    await until(() => scene.getElementById('app').lang === window.__INTEGRATION_EXPECTED_LANGUAGE);
    check(document.documentElement.lang === window.__INTEGRATION_EXPECTED_LANGUAGE, 'shared language restores the reconciled preference');
    check(localStorage.getItem('vaultClassifier.language') === null, 'retired Classifier language storage is removed');
  }
  const snapshot = { presentationRevision: 8000, workspace: 'knowledge', settings: {
    classificationEnabled: true, research: { enabled: false, llmProviderProfileID: 'sample', llmModelIdentifier: 'sample-model' },
    localModels: {modelLibrary: []}, dictionaries: {creatorMode: 'cache', creatorCacheSize: 10000, contributionEnabled: false, packs: []}
  }, assets: {classifierTypes: [], trees: [], datasets: [], bindings: [], collectionPlatforms: [], knowledge: {creators: [], terms: []},
    providerProfiles: [{id:'sample',name:'Literal provider',type:'openAI',credential:'synthetic-key',hasCredential:true}],
    providerProtocols: {openAI:{supportsGenerateText:true,supportsNativeWebSearch:true,supportsLLMConfiguration:true,credentialRequired:true}},
    providerModelCatalogs: {sample:['sample-model','sample-next']}
  }, notices: {} };
  const commands = [];
  window.webkit ||= {messageHandlers: {}};
  window.webkit.messageHandlers.vaultClassifier ||= {postMessage() {}};
  const send = webkit.messageHandlers.vaultClassifier.postMessage;
  webkit.messageHandlers.vaultClassifier.postMessage = message => {
    commands.push(structuredClone(message));
    if (message.action === 'saveClassificationSettings') snapshot.settings.classificationEnabled = message.data.classificationEnabled;
    if (message.action === 'saveDictionarySettings') Object.assign(snapshot.settings.dictionaries, message.data);
    if (message.action === 'updateProviderConnection') Object.assign(snapshot.assets.providerProfiles[0], message.data);
    snapshot.presentationRevision++;
    VaultClassifier.receive(structuredClone(snapshot));
  };
  try {
    VaultClassifier.receive(structuredClone(snapshot));
    const storedPolicy = JSON.stringify(snapshot.settings);
    for (const locale of Object.keys(getAvailableLanguages())) {
      await setLanguage(locale);
      await until(() => scene.getElementById('app').lang === locale);
      const catalog = await VaultLoadMessages(locale);
      await until(() => scene.querySelector('[data-editor-panel] h2')?.textContent.includes(catalog['classifier.knowledge.title']));
      check(scene.getElementById('app').dir === (locale === 'ar' ? 'rtl' : 'ltr'), locale + ': Classifier shares app language and direction');
      check(document.querySelector('.settings-language [data-i18n="language.label"]').textContent === catalog['language.label'], locale + ': shared language label remains localized');
      check(JSON.stringify(snapshot.settings) === storedPolicy, locale + ': language preserves native settings');
    }
    await setLanguage('en');
    await until(() => scene.getElementById('app').lang === 'en');
    const modal = document.getElementById('settingsModal');
    for (const name of ['vault', 'classifier', 'activity']) {
      document.querySelector(`[data-scene="${name}"]`).click();
      const opener = name === 'vault' ? document.getElementById('settingsButton') : name === 'classifier'
        ? scene.querySelector('[data-action="openUtilityPanel"]') : VaultScenes.scope('activity').getElementById('activitySettingsButton');
      opener.focus(); opener.click();
      await until(() => !!settings.querySelector('[data-field="classificationEnabled"]'));
      check(!modal.classList.contains('hidden') && document.body.dataset.scene === name, name + ': opens the same Settings without switching pages');
      check(document.querySelectorAll('#languageSelect').length === 1 && !settings.querySelector('[data-language-selection], [data-field="packageUpdateMode"]'), name + ': no separate language/update policy');
      check(!!settings.querySelector('.utility-dictionary-section') && !!document.getElementById('settingsQuitRetryMinutes'), name + ': native tagging/dictionaries and app behavior share Settings');
      const body = modal.querySelector('.settings-body');
      check(body.scrollWidth <= body.clientWidth + 1 && settings.host.scrollWidth <= settings.host.clientWidth + 1, name + ': shared Settings fits the viewport');
      VaultSettings.close();
      await until(() => !settings.querySelector('[data-field="classificationEnabled"]'));
      const focusRoot = name === 'vault' ? document : VaultScenes.scope(name);
      check(focusRoot.activeElement?.matches(name === 'classifier' ? '[data-action="openUtilityPanel"]' : name === 'activity' ? '#activitySettingsButton' : '#settingsButton'), name + ': closing Settings restores its current opener');
    }
    VaultSettings.open();
    await until(() => !!settings.querySelector('[data-field="classificationEnabled"]'));
    settings.querySelector('[data-field="classificationEnabled"]').click();
    await until(() => snapshot.settings.classificationEnabled === false);
    check(commands.some(message => message.action === 'saveClassificationSettings'), 'shared Settings autosaves native tagging');
    const credential = settings.querySelector('[data-field="credential"]');
    credential.focus(); check(credential.isConnected, 'credential stays connected after focus'); credential.value = 'draft-key'; credential.setSelectionRange(2, 6);
    credential.dispatchEvent(new InputEvent('input', {bubbles: true}));
    snapshot.presentationRevision++; VaultClassifier.receive(structuredClone(snapshot));
    const replacement = settings.querySelector('[data-field="credential"]');
    check(replacement.value === 'draft-key' && settings.activeElement === replacement && replacement.selectionStart === 2, 'native snapshot preserves Settings draft and caret');
    VaultSettings.close();
    await until(() => snapshot.assets.providerProfiles[0].credential === 'draft-key');
    check(snapshot.settings.dictionaries.contributionEnabled === false && snapshot.settings.dictionaries.creatorCacheSize === 10000, 'other settings edits preserve dictionary choices');
    VaultSettings.open();
    await until(() => !!settings.querySelector('[data-model-selector]'));
    const selector = settings.querySelector('[data-model-selector]'); selector.click();
    await until(() => settings.querySelector('.research-model-picker').open);
    const settingsBody = modal.querySelector('.settings-body');
    const before = settingsBody.scrollTop;
    settingsBody.scrollTop += 60;
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    const menuBox = settings.querySelector('.research-model-menu').getBoundingClientRect();
    const anchorBox = settings.querySelector('[data-model-selector]').getBoundingClientRect();
    check(Math.abs(menuBox.left - anchorBox.left) < 2 && menuBox.bottom <= innerHeight - 7, 'model menu follows the shared dialog scroll and stays in the viewport');
    settingsBody.scrollTop = before;
    settings.querySelector('[data-model-search]').dispatchEvent(new KeyboardEvent('keydown', {key:'Escape',bubbles:true,composed:true}));
    check(!settings.querySelector('.research-model-picker').open && !modal.classList.contains('hidden'), 'Escape closes the model chooser before shared Settings');
    const card = modal.querySelector('.modal-card');
    settings.querySelector('[data-field="creatorCacheSize"]').focus();
    document.dispatchEvent(new KeyboardEvent('keydown', {key:'Tab',bubbles:true}));
    check(settings.activeElement?.matches('[data-field="contributionEnabled"]'), 'dialog keyboard navigation includes nested native controls');
    check(card.getClientRects().length > 0, 'shared Settings remains visible during native edits');
    document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
    await until(() => modal.classList.contains('hidden'));
    check(!commands.some(message => message.action === 'savePackageSettings'), 'retired package policy emits no command');
    check(window.__CB_DESKTOP_PROGRAM_ID === (window.__INTEGRATION_EXPECTED_PROGRAM || 'macapp'), 'tested the requested desktop product assets');
    return results;
  } finally { webkit.messageHandlers.vaultClassifier.postMessage = send; VaultSettings.close(); }
}
