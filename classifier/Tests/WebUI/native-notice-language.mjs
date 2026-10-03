import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const context=vm.createContext({window:{}});
vm.runInContext(fs.readFileSync(new URL('../../Sources/VaultClassifierApp/WebAssets/notice-language.js',import.meta.url),'utf8'),context);
const catalog={
 'notice.field.1':'le nom',
 'notice.inputCheck':'Vérifiez {field}.',
 'notice.inputLimit':'{field} : {limit} caractères maximum.',
 'notice.providerProtocols.5':'Ce protocole exige une adresse.',
 'notice.providerProtocols.3':'Ce protocole exige {field}.',
 'notice.providerProtocols.1':'Le fournisseur a répondu HTTP {status}.',
 'notice.backupCreated':'Sauvegarde créée dans {folder}.',
 'notice.termLookupPending':'Recherche de « {subject} » en cours.',
};
const translate=(key,values={})=>(catalog[key]??key).replace(/\{([A-Za-z0-9_]+)\}/g,(_,name)=>String(values[name]??''));
const localize=text=>context.window.VaultNoticeLanguage(text,translate);
assert.equal(localize('Check the name and try again.'),'Vérifiez le nom.');
assert.equal(localize('Use at most 2048 characters for the name.'),'le nom : 2048 caractères maximum.');
assert.equal(localize('The provider protocol requires an endpoint.'),'Ce protocole exige une adresse.');
assert.equal(localize('The provider protocol requires apiVersion.'),'Ce protocole exige apiVersion.');
assert.equal(localize('The provider returned HTTP 429.'),'Le fournisseur a répondu HTTP 429.');
assert.equal(localize('Local model snapshot created in model-用户-01.'),'Sauvegarde créée dans model-用户-01.');
assert.equal(localize('Looking up “ユーザー”. It appears under Known terms when the lookup finishes.'),'Recherche de « ユーザー » en cours.');
for(const raw of ['Provider-specific error: secret-code-123','Check the name and try again. extra text','Taxonomy has a parent cycle at 私のタグ.','',null]) {
 assert.equal(localize(raw),String(raw??''));
}
assert.equal(context.window.VaultNoticeLanguage('Check the name and try again.',key=>key),'Check the name and try again.');
console.log('PASS known native notices, field grammar, literal IDs, exact templates, unknown diagnostics and missing catalog fallback (13 checks)');
