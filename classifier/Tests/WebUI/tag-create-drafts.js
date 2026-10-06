window.runTagDraftTests = async () => {
  const scope = document.getElementById('host').shadowRoot;
  const q = selector => scope.querySelector(selector);
  const wait = () => new Promise(resolve => setTimeout(resolve, 60));
  const check = (condition, message) => { if (!condition) throw Error(message); };
  const open = () => {
    const map = q('[data-tree-map]');
    const rect = map.getBoundingClientRect();
    map.dispatchEvent(new MouseEvent('contextmenu', {bubbles:true, composed:true, clientX:rect.left+180, clientY:rect.top+120}));
  };
  pushSnapshot(); await wait(); q('[data-action="selectType"]').click(); await wait(); open(); await wait();
  let name = q('[data-tree-popover] [data-field="name"]');
  let description = q('[data-tree-popover] [data-field="description"]');
  name.value = 'Mathematics';
  description.value = 'Calculus, algebra and geometry.';
  name.focus(); name.setSelectionRange(3, 7);
  name.dispatchEvent(new Event('input', {bubbles:true}));
  description.dispatchEvent(new Event('input', {bubbles:true}));
  const count = commands.length;
  // Real downloads change visible progress repeatedly, forcing a full render.
  for (let progress=0.1; progress<=0.3; progress+=0.1) {
    testState.settings.localModels.modelLibrary=[{id:'test-model', displayName:'Qwen', ggufFileName:'test.gguf', tier:'balanced', state:{kind:'downloading', fraction:progress}}];
    pushSnapshot(); await wait();
    name=q('[data-tree-popover] [data-field="name"]');
    description=q('[data-tree-popover] [data-field="description"]');
    check(name.value==='Mathematics' && description.value==='Calculus, algebra and geometry.', 'Download progress erased the pending tag fields');
    check(scope.activeElement===name && name.selectionStart===3 && name.selectionEnd===7, 'Download progress lost the pending tag caret');
  }
  description.focus(); description.setSelectionRange(8, 15, 'backward');
  testState.settings.localModels.modelLibrary[0].state.fraction=0.4;
  pushSnapshot(); await wait();
  description=q('[data-tree-popover] [data-field="description"]');
  check(scope.activeElement===description && description.selectionStart===8 && description.selectionEnd===15 && description.selectionDirection==='backward', 'Download progress lost the description caret');
  check(commands.length===count, 'A pending tag was saved before explicit creation');
  q('[data-action="addTag"]').click(); await wait();
  const created=commands.findLast(command=>command.action==='addTag');
  check(created?.data.name==='Mathematics' && created.data.description==='Calculus, algebra and geometry.', 'Create submitted different tag fields');
  open(); await wait();
  check(q('[data-tree-popover] [data-field="name"]').value==='' && q('[data-tree-popover] [data-field="description"]').value==='', 'A new tag reused the previous draft');
  q('[data-tree-popover] [data-field="name"]').value='Cancelled';
  q('[data-action="cancelTagPanel"]').click(); await wait(); open(); await wait();
  check(q('[data-tree-popover] [data-field="name"]').value==='', 'Cancelled tag draft leaked into a new tag');
  check(uiErrors.length===0, uiErrors.join('\n'));
  return ['PASS pending tag fields and caret survive model progress', 'PASS explicit create submits preserved values', 'PASS create and cancel discard the old draft'];
};
