window.runRecordingHistoryTests = async () => {
  const results = [], q = selector => scope.querySelector(selector);
  const expect = (ok, name) => { if (!ok) throw Error(name); results.push('PASS ' + name); };
  const wait = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  const end = Date.now(), start = end - 3600000;
  const segment = (key, label, seconds, offset, colorIndex) => ({key, label, seconds, startedAtMs: start + offset * 1000, startFraction: offset / 3600, widthFraction: seconds / 3600, colorIndex});
  const app = segment('com.google.Chrome', 'Saved Chrome', 600, 0, 1);
  const site = segment('youtube.com', 'Saved website', 300, 0, 2);
  const video = segment('youtube:saved', 'Saved lesson', 180, 30, 3);
  const settings = enabled => ({appUsage:{enabled,retentionDays:null},webVisit:{enabled,retentionDays:null},contentWatched:{enabled,retentionDays:null},retentionDays:365});
  const snapshot = {rangeStartMs:start,rangeEndMs:end,settings:settings(false),groups:[],app:{totalSeconds:600,bars:[app],timeline:[app]},web:{totalSeconds:300,bars:[site],timeline:[site]},watchedTimeline:[video]};
  const tags = [{id:'math',name:'Math'},{id:'unused',name:'Unused'}];
  const facts = {'youtube:saved':{title:'Saved lesson',creator:'Saved teacher',tags:[tags[0]]}};
  const original = JSON.stringify(snapshot);
  const replyUsageHistory = () => {
    const request = [...commands].reverse().find(command => command.kind === 'history' && command.section === 'usage');
    const day = new Date(start); day.setHours(0,0,0,0);
    const daily = entry => ({...entry,startFraction:(entry.startedAtMs-day.getTime())/86400000,widthFraction:entry.seconds/86400});
    activityHistory(request, {map:{dayStartsMs:[day.getTime()],daySeconds:[600]},days:[{dayStartMs:day.getTime(),app:[daily(app)],web:[daily(site)]}]});
  };
  const apply = (value = snapshot, content) => {
    activityApply(structuredClone(value), {}, facts, {platforms:[]}, tags, content && structuredClone(content));
    replyUsageHistory();
  };
  const row = label => [...scope.querySelectorAll('#usage-section .colour-row')].find(node => node.querySelector('.colour-name')?.textContent === label);
  const summary = section => q('#' + section + '-section .section-summary strong')?.textContent;
  document.body.dataset.scene = 'activity';
  apply(); await wait();
  expect(!q('#usage-section .off') && summary('usage') === '00:10:00', 'saved Usage remains visible with both recording switches off');
  expect(row('Saved Chrome')?.querySelector('.colour-time').textContent === '00:10:00' && row('Saved website')?.querySelector('.colour-time').textContent === '00:05:00', 'OFF Usage retains complete browser and website rows');
  const pieLabels = [...scope.querySelectorAll('#usage-section .legend-label')].map(node => node.textContent);
  expect(pieLabels.includes('Saved website') && !pieLabels.includes('Saved Chrome'), 'OFF Usage pie still excludes browser double counting');
  expect(!q('#content-section .off') && summary('content') === '00:03:00', 'saved Content remains visible with recording off');
  expect(q('#content-section .raw-row')?.textContent.includes('Saved lesson') && q('#content-section .author-row')?.textContent.includes('Saved teacher'), 'OFF Content retains saved facts and author rows');
  expect(!commands.some(command => command.kind === 'setSettings' || command.kind === 'delete'), 'reading saved OFF history never changes recording or deletes records');

  apply({...snapshot,settings:settings(true)}); await wait();
  row('Saved Chrome').click();
  replyUsageHistory();
  let contentFilter = q('#content-section .section-head select');
  contentFilter.value = 'tag|math'; contentFilter.dispatchEvent(new Event('change', {bubbles:true}));
  const block = q('#usage-totals select'); block.value = '5'; block.dispatchEvent(new Event('change', {bubbles:true}));
  const recording = q('.settings-panel details'); recording.open = true; await wait();
  const beforeClick = commands.length;
  q('[data-info-key="record:app-usage"] input').click();
  expect(commands.slice(beforeClick).length === 1 && commands.at(-1).kind === 'setSettings' && commands.at(-1).category === 'app-usage' && commands.at(-1).enabled === false, 'normal recording switch sends only its requested future-collection edit');
  for (const enabled of [false, true, false]) {
    apply({...snapshot,settings:settings(enabled)}); await wait();
    expect(summary('usage') === '00:10:00' && summary('content') === '00:03:00', 'recording ' + enabled + ' snapshot preserves historical totals');
    expect(q('#usage-section .section-head select').value === 'app|com.google.Chrome' && q('#content-section .section-head select').value === 'tag|math' && q('#usage-totals select').value === '5', 'recording ' + enabled + ' snapshot preserves filters and graph block size');
  }
  contentFilter = q('#content-section .section-head select');
  contentFilter.value = 'tag|unused'; contentFilter.dispatchEvent(new Event('change', {bubbles:true}));
  expect(!q('#content-section .off') && summary('content') === '00:00:00', 'empty tag focus does not hide retained OFF Content history');
  let usageFilter = q('#usage-section .section-head select'); usageFilter.value = 'all'; usageFilter.dispatchEvent(new Event('change', {bubbles:true}));
  contentFilter = q('#content-section .section-head select'); contentFilter.value = 'all'; contentFilter.dispatchEvent(new Event('change', {bubbles:true}));

  const empty = {...snapshot,app:{totalSeconds:0,bars:[],timeline:[]},web:{totalSeconds:0,bars:[],timeline:[]},watchedTimeline:[]};
  apply(empty, snapshot); await wait();
  expect(!!q('#usage-section .off') && summary('content') === '00:03:00', 'independent Content snapshot remains readable when Usage range is empty and OFF');
  apply({...empty,web:snapshot.web}); await wait();
  expect(!!row('Saved website') && !q('#usage-section .off'), 'website-only saved Usage remains readable while Apps and Websites are off');
  expect(!q('#content-section .off') && q('#content-section .section-summary').textContent.includes('00:05:00 other pages'), 'saved platform website time remains visible as Other pages while Content is off');
  apply({...empty,web:{totalSeconds:300,bars:[{...site,key:'example.com'}],timeline:[{...site,key:'example.com'}]}}); await wait();
  expect(!!q('#content-section .off'), 'unrelated website history does not fabricate Content history');
  apply(empty); await wait();
  expect(!!q('#usage-section .off') && !!q('#content-section .off') && !q('#usage-section .section-summary') && !q('#content-section .section-summary'), 'genuinely empty OFF ranges retain Not recorded and Turn on');
  const beforeTurnOn = commands.length;
  q('#usage-section .off button').click(); q('#content-section .off button').click();
  expect(JSON.stringify(commands.slice(beforeTurnOn)) === JSON.stringify(['app-usage','web-visit','content-watched'].map(category => ({kind:'setSettings',category,enabled:true}))), 'empty OFF Turn on controls retain their explicit category commands');
  expect(!!q('#usage-section .off') && !!q('#content-section .off'), 'empty OFF controls await the authoritative settings snapshot');
  expect(JSON.stringify(snapshot) === original, 'rendering and recording toggles do not mutate retained snapshots');
  expect(!window.uiErrors.length, 'production renderer has no page errors');
  return results;
};
