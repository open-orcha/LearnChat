'use strict';
// Run the shipped browser controller with delayed HTTP replies and a minimal DOM.
// Rendering is covered in the real browser; these checks control network ordering.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../muse_runtime/dashboard_assets/dashboard.js'), 'utf8');
const pending = [];
const elements = new Map();
const element = id => {
  if (!elements.has(id)) elements.set(id, {value:'', checked:false, options:[], addEventListener(){}, replaceChildren(...children){this.options=children;}});
  return elements.get(id);
};
const context = vm.createContext({document:{getElementById:element,createElement:()=>({})}, performance:{now:()=>0}, AbortController,
  setTimeout:()=>0, clearTimeout(){}, setInterval(){}, fetch:(url)=>new Promise(resolve=>pending.push({url,resolve}))});
vm.runInContext(source, context);
vm.runInContext('const renderControls=controls; resources=sessions=limits=events=controls=connection=tick=()=>{};', context);
const evaluate = s => vm.runInContext(s, context);
const window = (generation, boot, sequence) => ({producer_generation:generation,boot_id:boot,window_sequence:sequence,window_id:`${boot}-${sequence}`,events:[`events-${boot}-${sequence}`]});
const monitor = runtime => ({sampled_at:1,runtime,history:[{at:1}],control_token:'test-token'});
const settle = () => new Promise(resolve=>setImmediate(resolve));
function reply(url, body) {
  const index = pending.findIndex(x=>x.url===url);
  assert.notEqual(index,-1, `pending ${url}`);
  pending.splice(index,1)[0].resolve({ok:true,json:async()=>body});
}
async function poll(runtime) {
  const promise=evaluate('refresh()');reply('/api/monitor',monitor(runtime));await promise;
}
(async()=>{
  const old=window(1,'old',0), reset=window(2,'current',1);
  reply('/api/monitor', monitor(old));await settle();
  // This GET captured old data before reset and returns after reset has succeeded.
  const delayed=evaluate('refresh()');
  const control=evaluate('runControl("reset")');
  reply('/api/control',{...reset,ok:true,message:'Reset'});await control;
  assert.equal(evaluate('data.runtime'),null);
  reply('/api/monitor',monitor(old));await delayed;
  assert.equal(evaluate('data.runtime'),null);
  assert.equal(evaluate('data.history.length'),0);
  await poll(null);assert.equal(evaluate('data.history.length'),0);
  await poll(reset);assert.equal(evaluate('data.runtime.window_id'),reset.window_id);
  // The fence remains after the first fresh response, including old same-boot data.
  await poll(old);assert.equal(evaluate('data.runtime'),null);
  await poll(window(2,'current',0));assert.equal(evaluate('data.runtime'),null);
  await poll(window(2,'current',2));assert.equal(evaluate('data.runtime.window_sequence'),2);
  await poll(window(3,'later',0));assert.equal(evaluate('data.runtime.boot_id'),'later');
  // Legacy exports and unknown boot IDs at the same generation are not newer.
  await poll({boot_id:'legacy',window_id:'legacy',window_sequence:99});assert.equal(evaluate('data.runtime'),null);
  await poll(window(3,'unknown',99));assert.equal(evaluate('data.runtime'),null);
  await poll(window(3,'later',0));
  // A reset response delayed behind another tab's newer reset cannot lower the floor.
  const late=evaluate('runControl("reset")');
  await poll(window(3,'later',2));
  reply('/api/control',{...window(3,'later',1),ok:true,message:'Reset'});
  await settle();
  reply('/api/monitor',monitor(window(3,'later',1)));await late;
  assert.equal(evaluate('data.runtime'),null);
  await poll(window(3,'later',2));assert.equal(evaluate('data.runtime.window_sequence'),2);
  // The same conversation can become busy and then idle without changing IDs.
  evaluate('data.runtime={model_process:{},sessions:[{session:"test-session",in_flight:false}]}; renderControls();');
  element('cache-target').value='test-session';
  evaluate('data.runtime.sessions[0].in_flight=true; renderControls();');
  assert.match(element('cache-target').options[2].textContent,/\(busy\)$/);
  assert.equal(element('cache-target').value,'test-session');
  evaluate('data.runtime.sessions[0].in_flight=false; renderControls();');
  assert.doesNotMatch(element('cache-target').options[2].textContent,/\(busy\)$/);
  assert.equal(element('cache-target').value,'test-session');
  console.log('Dashboard polling races passed: old producer, delayed GET, persistent fence, later reset/restart, legacy/unknown producer, late reset reply.');
  console.log('Cache target labels follow busy/idle changes and preserve selection.');
})().catch(error=>{console.error(error);process.exitCode=1;});
