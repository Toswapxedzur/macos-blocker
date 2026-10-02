window.runDropdownLayoutTests = async () => {
  await import('/classifier/Tests/WebUI/model-picker.js');
  const results = await runModelPickerTests();
  const q = selector => scope.querySelector(selector);
  const wait = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  const check = (condition, label) => { if (!condition) throw Error(label); results.push('PASS ' + label); };
  const dismiss = node => node.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, composed: true }));
  q('.research-model-picker').open = false; await wait();
  const modal = q('.utility-popover'), note = q('.utility-research-section > p.small-copy');
  const before = { y: note.getBoundingClientRect().top, height: modal.scrollHeight };
  q('[data-model-selector]').focus(); q('[data-model-selector]').click(); await wait();
  check(Math.abs(note.getBoundingClientRect().top - before.y) < 1 && modal.scrollHeight === before.height,
    'model menu leaves downstream positions and Settings height unchanged');
  const receivesClick = node => { const rect = node.getBoundingClientRect(); const hit = scope.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2); return node.contains(hit); };
  check(receivesClick(q('[data-model-search]')), 'model menu receives clicks above its Settings panel');
  modal.style.transform = 'translateZ(0)'; await wait();
  check(receivesClick(q('[data-model-search]')), 'model menu escapes a transformed clipped dialog');
  modal.style.removeProperty('transform');
  let menu = q('.research-model-menu'), anchor = q('[data-model-selector]');
  const box = menu.getBoundingClientRect(), field = anchor.getBoundingClientRect();
  check(getComputedStyle(menu).position === 'fixed' && Math.abs(box.width - field.width) < 2,
    'model menu floats at the selector width');
  check(box.left >= 7 && box.right <= innerWidth - 7 && box.top >= 7 && box.bottom <= innerHeight - 7,
    'floating model menu fits the viewport');
  check(scope.activeElement.matches('[data-model-search]'), 'opening model menu focuses search');
  const searchInfo = q('[data-info-key="research.modelSearch"] .vui-info-button');
  const commandCount = commands.length;
  searchInfo.click(); await wait();
  check(q('.research-model-menu .vui-info-popover') && q('.research-model-picker').open && commands.length === commandCount,
    'Model-search Info preserves the menu and sends no provider request');
  searchInfo.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true,composed:true})); await wait();
  check(!q('.vui-info-popover') && q('.research-model-picker').open && q('.utility-popover'),
    'Escape closes Info before the model menu and Settings');
  const search = q('[data-model-search]'); search.value = ''; search.dispatchEvent(new InputEvent('input', { bubbles: true }));
  search.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
  check(scope.activeElement.matches('[data-model-pick]'), 'model results support arrow-key navigation');
  dismiss(q('.utility-settings-section-title'));
  check(!q('.research-model-picker').open && q('.utility-popover'), 'outside click closes model menu without closing Settings');
  const card = q('[data-provider-panel]'), fields = card.querySelector('.provider-connection-fields');
  const footer = card.querySelector('footer.provider-request-summary'), body = card.querySelector('.provider-panel-body');
  check(footer && footer.getBoundingClientRect().top >= body.getBoundingClientRect().bottom - 1,
    'API usage and diagnostics sit below the connection fields');
  check(fields.getBoundingClientRect().width >= body.getBoundingClientRect().width - 1,
    'API connection fields use the full card width');
  q('[data-action="closeUtilityPanel"]').click(); await wait();
  testState.assets.knowledge.knownCreators = Array.from({ length: 60 }, (_, i) => ({ id: `creator-${i}`, name: `Creator ${i}`, platformID: 'youtube' }));
  testState.workspace = 'knowledge'; testState.issue = null; pushSnapshot(); await wait();
  const creator = q('[data-knowledge-creator]'), description = q('[data-form-id="knowledge-add-creator"] [data-field="meaning"]');
  creator.scrollIntoView({ block: 'center' }); await wait();
  const descriptionY = description.getBoundingClientRect().top;
  creator.focus(); creator.value = 'Creator'; creator.dispatchEvent(new InputEvent('input', { bubbles: true }));
  creator.setSelectionRange(1, 3); await wait();
  check(q('[data-knowledge-suggestions]').children.length === 6 && Math.abs(description.getBoundingClientRect().top - descriptionY) < 1,
    'creator suggestions float without moving the description');
  const suggestions = q('[data-knowledge-suggestions]'), suggestionsBox = suggestions.getBoundingClientRect();
  check(receivesClick(suggestions.firstElementChild), 'creator suggestions receive clicks outside their clipped card');
  check(getComputedStyle(suggestions).position === 'fixed' && suggestionsBox.left >= 7 && suggestionsBox.right <= innerWidth - 7 && suggestionsBox.bottom <= innerHeight - 7,
    'creator suggestion menu stays within the viewport');
  testState.issue = 'Synthetic snapshot'; pushSnapshot(); await wait();
  check(q('[data-knowledge-creator]').value === 'Creator' && scope.activeElement.selectionStart === 1 && q('[data-knowledge-suggestions]').children.length === 6,
    'snapshot preserves creator query, caret and suggestion menu');
  q('[data-knowledge-creator]').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
  check(scope.activeElement.matches('[data-knowledge-pick]'), 'creator results support arrow-key navigation');
  const chosen = scope.activeElement.dataset.knowledgePick; scope.activeElement.click(); await wait();
  check(q('[data-knowledge-creator]').value === chosen && !q('[data-knowledge-suggestions]').children.length && scope.activeElement.matches('[data-knowledge-creator]'),
    'creator choice fills the input and closes suggestions');
  q('[data-knowledge-creator]').value = 'Creator'; q('[data-knowledge-creator]').dispatchEvent(new InputEvent('input', { bubbles: true }));
  dismiss(q('[data-form-id="knowledge-add-creator"] [data-field="meaning"]'));
  check(!q('[data-knowledge-suggestions]').children.length, 'outside click dismisses creator suggestions');
  check(uiErrors.length === 0, 'floating dropdowns produce no renderer errors');
  return results;
};
