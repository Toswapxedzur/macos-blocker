async function runInfoPopoverTests() {
  const scope = VaultScenes.scope('classifier'), q = selector => scope.querySelector(selector);
  const results = [], check = (ok, label) => { if (!ok) throw Error(label); results.push('PASS ' + label); };
  const delay = () => new Promise(resolve => setTimeout(resolve, 100));
  await delay(); q('[data-action="selectType"]').click(); await delay();
  const assertFields = () => {
    for (const label of scope.querySelectorAll('label.field,.research-model-field,.header-language,.toggle-row:not(.platform-choice)')) {
      if (!label.getBoundingClientRect().width || !label.querySelector('input,select')) continue;
      const button = label.querySelector('.vui-info-button');
      check(button && button.getBoundingClientRect().width === 14, 'Field Info is visible: ' + (label.querySelector('[data-field]')?.dataset.field || 'language'));
      check(getComputedStyle(button).color === 'rgb(148, 163, 184)', 'Field Info keeps the shared blue-gray color');
    }
  };
  assertFields();
  const groupNameInfo = q('.classifier-name-row .vui-info-button');
  const writesBefore = commands.length;
  groupNameInfo.click(); await delay();
  check(commands.length === writesBefore, 'Name Info does not send an edit or action');
  VaultInfo.close();
  const resident = q('.resident-model-note');
  const buttonFor = text => [...scope.querySelectorAll('.vui-info-button')].find(button => button.infoEntry.texts.some(copy => copy.includes(text)));
  check(getComputedStyle(resident).display === 'none', 'Model residency explanation no longer occupies a row');
  let button = buttonFor('Up to two');
  check(button?.getClientRects().length, 'Model residency explanation remains available through Info');
  const panel = q('.editor-panel'), before = panel.getBoundingClientRect();
  button.click(); await delay();
  check(document.querySelector('.vui-info-popover')?.textContent.includes('Up to two'), 'Info works from the Classifier shadow root');
  check(Math.abs(panel.getBoundingClientRect().height - before.height) < 1, 'Opening Info leaves the editor layout unchanged');
  testState.issue = 'Synthetic status'; pushSnapshot(); await delay();
  button = buttonFor('Up to two');
  check(document.querySelector('.vui-info-popover') && button.getAttribute('aria-expanded') === 'true', 'Open explanation survives a snapshot');
  check(q('.notice.red')?.getClientRects().length, 'Live errors remain visible');
  document.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true})); await delay();
  check(!document.querySelector('.vui-info-popover'), 'Escape dismisses shadow-root Info');
  q('[data-utility-panel="settings"]').click(); await delay();
  assertFields();
  check(q('.research-data-flow').classList.contains('vui-info-source'), 'Research details use Info');
  check(q('[data-field="enabled"]')?.closest('label').getClientRects().length, 'Research consent remains visible');
  check(q('.research-status')?.getClientRects().length, 'Research status remains visible');
  const consent = q('[data-field="enabled"]'), wasChecked = consent.checked;
  consent.closest('label').querySelector('.vui-info-button').click(); await delay();
  check(consent.checked === wasChecked, 'Consent Info does not enable research');
  document.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true})); await delay();
  check(q('.utility-settings-modal'), 'Escape keeps Settings open');
  const language = q('[data-language-selection]'); language.value = 'zh';
  language.dispatchEvent(new Event('change', {bubbles:true})); await delay();
  check(!q('.vui-info-button') && !q('.research-data-flow').classList.contains('vui-info-source'), 'Non-English layout retains inline explanations');
  const back = q('[data-language-selection]'); back.value = 'en'; back.dispatchEvent(new Event('change', {bubbles:true})); await delay();
  check(q('.vui-info-button'), 'English Info returns after a language change');
  q('[data-action="closeUtilityPanel"]').click(); await delay();
  testState.workspace = 'knowledge'; pushSnapshot(); await delay(); assertFields();
  const descriptionInfo = q('[data-form-id="knowledge-term-term-1"] .vui-info-button') ||
    [...scope.querySelectorAll('.knowledge-card .vui-info-button')][0];
  check(descriptionInfo, 'Saved knowledge descriptions have Info');
  descriptionInfo.click(); pushSnapshot(); await delay();
  check(q('.knowledge-card .vui-info-button[aria-expanded="true"]'), 'Knowledge Info rebinds to its own saved entry after a snapshot');
  VaultInfo.close();
  q('[data-action="newType"]').click(); await delay();
  const creation = q('[data-create-type-dialog]');
  check(creation.querySelector('[data-info-key="createType.nameLabel"] .vui-info-button') && creation.querySelector('[data-info-key="createType.platformLabel"] .vui-info-button'), 'Creation fields have explicit Info');
  q('[data-action="cancelCreateType"]').click(); await delay();
  q('[data-utility-panel="settings"]').click(); await delay();
  check(uiErrors.length === 0, 'Info causes no renderer errors');
  buttonFor('Optional web lookups').click(); await delay();
  return results;
}
