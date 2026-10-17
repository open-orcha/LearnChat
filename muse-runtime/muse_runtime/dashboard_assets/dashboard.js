'use strict';
const $ = id => document.getElementById(id);
const number = value => Number.isFinite(value) ? value.toLocaleString(undefined, {maximumFractionDigits: 1}) : 'Unavailable';
const gib = value => Number.isFinite(value) ? `${(value / 1073741824).toFixed(2)} GiB` : 'Unavailable';
const when = value => Number.isFinite(value) ? new Date(value * 1000).toLocaleString(undefined, {month:'short', day:'numeric', hour:'2-digit', minute:'2-digit', second:'2-digit', hour12:false}) : 'Unavailable';
const seconds = value => { if (!Number.isFinite(value)) return 'Unavailable'; value=Math.max(0, Math.ceil(value)); return `${Math.floor(value/60)}m ${String(value%60).padStart(2,'0')}s`; };
const chat = ref => ref ? `Chat ${ref.slice(0,8)}…${ref.slice(-4)}` : 'Runtime';
const node = (tag, text, className) => {const el=document.createElement(tag); if(text !== undefined) el.textContent=text; if(className) el.className=className; return el;};
let data=null, receivedAt=0, fetchFailed=false, loading=false, previousBoot=null, restartSeen=false;
const currentTime = () => data ? data.sampled_at + (performance.now()-receivedAt)/1000 : 0;
const isLive = () => data && !fetchFailed && data.connection==='live' && currentTime()-data.runtime?.sampled_at <= data.stale_after_seconds;
function chart(id, points, max) {
  $(id).querySelector('path').setAttribute('d', points.map((v,i)=>`${i?'L':'M'}${points.length>1?i*400/(points.length-1):0},${46-Math.min(1,Math.max(0,v/max))*44}`).join(' '));
}
function connection() {
  const live=isLive(), state=fetchFailed?'disconnected':live?'live':data?.connection==='live'?'stale':data?.connection || 'connecting';
  $('connection').className=`badge ${state}`;
  $('connection').textContent={live:'Live',stale:'Runtime data is stale',disconnected:'Disconnected',starting:'Starting',connecting:'Connecting'}[state] || state;
  $('updated').textContent=data?`Last monitor sample ${when(data.sampled_at)}`:'Waiting for the first sample';
  $('notice').className=live?'notice':'notice warning';
  $('notice').textContent=live ? 'Automatic monitoring is passive. Controls below act only when clicked; measurements refresh every 2 seconds.' : fetchFailed ? 'The dashboard server cannot be reached. Displayed measurements are old; lease countdowns are frozen. Start the dashboard service to reconnect.' : data?.runtime ? `Runtime telemetry is unavailable or older than ${data.stale_after_seconds} seconds. The last known conversation state is shown with countdowns frozen; this does not confirm a lease is still active.` : 'No runtime telemetry yet. Start the instrumented runtime; this page will reconnect automatically.';
}
function resources() {
  const host=data.host;
  $('ram').textContent=host?gib(host.ram_used_bytes):'Unavailable';
  $('ram-detail').textContent=host?`${gib(host.ram_available_bytes)} available of ${gib(host.ram_total_bytes)} • Swap ${gib(host.swap_used_bytes)}`:'Install the optional psutil dependency for resource measurements.';
  $('ram-meter').value=host?100*host.ram_used_bytes/host.ram_total_bytes:0;
  $('cpu').textContent=host?`${number(host.cpu_percent)}%`:'Unavailable';
  $('cpu-meter').value=host?.cpu_percent || 0;
  $('cpu-detail').textContent=host?`0–100% across all ${host.logical_cpus} logical CPUs`:'Host CPU measurements unavailable';
  const tbody=$('processes');tbody.replaceChildren();
  for(const [key,label] of [['model','Model / llama.cpp'],['runtime','Chat service'],['dashboard','Dashboard']]) {
    const p=data.processes[key], row=node('tr');
    row.append(node('td',label),node('td',p?gib(p.rss_bytes):'Unavailable'),node('td',p?.cpu_warming_up?'Sampling…':p?`${number(p.cpu_percent)}%`:'Unavailable'));tbody.append(row);
  }
  chart('cpu-chart',data.history.map(x=>x.cpu_percent),100);
  chart('ram-chart',data.history.map(x=>x.ram_used_bytes),host?.ram_total_bytes||1);
}
function sessions() {
  const r=data?.runtime, container=$('sessions');container.replaceChildren();
  if(!r){$('slots').textContent='Waiting for runtime';container.append(node('p','No runtime sample yet.','empty'));return;}
  $('slots').textContent=`${r.active_leases} active leases • ${r.slots_busy} busy / ${r.slots_occupied} occupied / ${r.slots_free} free slots`;
  if(!r.sessions.length) container.append(node('p',isLive()?'No conversation leases right now. A conversation will appear when you chat in QChat.':'No leases in the last known sample. Current state is unavailable.','empty'));
  for(const s of r.sessions){
    const row=node('article',undefined,'lease'), identity=node('div'), timer=node('div'), renewal=node('div'), cache=node('div');
    identity.append(node('p',chat(s.session),'name'),node('p',s.in_flight?'Reply in progress':s.state==='awaiting_expiry'?'Awaiting expiry sweep':'Idle conversation','state'),node('p',`Cache ${s.slot===null?'evicted / no slot':`in slot ${s.slot+1}`} • ${s.cache_valid?'reusable':'rebuild needed'}`,'detail'));
    const countdown=node('p',undefined,'time');countdown.dataset.expires=s.expires_at;countdown.dataset.busy=s.in_flight;timer.append(countdown,node('p','Until idle lease expiry','detail'));
    const meter=node('meter');meter.min=0;meter.max=r.limits.lease_seconds;meter.dataset.expires=s.expires_at;meter.setAttribute('aria-label',`${chat(s.session)} lease time remaining`);timer.append(meter);
    renewal.append(node('p',`Last renewal ${when(s.last_renewal_at)}`),node('p',`From ${reasons[s.renewal_source]||s.renewal_source}`,'detail'),node('p',`Expires ${when(s.expires_at)}`,'detail'));
    cache.append(node('p',`${number(s.tokens)} tracked tokens`),node('p',`${number(Math.max(0,r.limits.session_tokens-s.tokens))} below session limit • ${s.token_source==='tokenizer'?'tokenizer-based':'estimated'}`,'detail'),node('p',`Last prompt budget ${number(s.prompt_limit)} • ${s.compactions} compactions • ${s.rebuilds} fallback rebuilds${s.snapshot_available?' • snapshot available':''}`,'detail'));
    row.append(identity,timer,renewal,cache);container.append(row);
  }
  $('sessions-note').textContent=`Conversation labels are private aliases and change after a runtime restart. ${r.sessions_omitted?`${r.sessions_omitted} additional leases omitted (display bound: 256).`:''} Tracked tokens estimate cache use; they are not an exact KV allocation measurement.`;
  tick();
}
const reasons={request_started:'chat request started',request_completed:'reply completed',heartbeat:'app heartbeat',slot_pressure:'all slots occupied; least recently used idle cache evicted',token_pressure:'total cached-token limit exceeded; idle cache evicted',compaction:'context compacted',cache_unavailable:'no reusable cache; rebuild from supplied history',session_busy:'same conversation already busy',all_slots_busy:'all inference slots busy',context_limit:'safe prompt budget could not be met',backend_or_disconnect:'backend error or client disconnect',missing_or_expired:'lease missing or expired',restore:'snapshot restore failed',save:'snapshot save failed'};
function limits() {
  const r=data.runtime, container=$('limits');container.replaceChildren(); if(!r){$('activity').replaceChildren();$('model-status').textContent='Waiting for runtime';return;}
  const l=r.limits;
  $('model-status').textContent=`${r.model} • ${isLive()?(r.ready?'Backend ready':'Backend unavailable'):'Readiness unknown (old sample)'}`;
  const items=[
    ['Time',`${seconds(l.lease_seconds)} per renewal`,'Idle leases expire on the next one-second sweep. In-flight replies are protected. Chat start, successful completion and app heartbeats renew the lease.'],
    ['Context',`${number(l.session_tokens)} tokens / session`,`${number(l.context_tokens)} total context, ${number(l.slot_context_tokens)} per slot. Each request reserves its output budget, up to ${number(l.max_output_tokens)} tokens; the remaining slot space is the prompt budget. Long prompts compact before generation.`],
    ['Cache pressure',`${number(r.cached_tokens)} / ${number(l.total_cache_tokens)}`,`${number(Math.max(0,l.total_cache_tokens-r.cached_tokens))} tracked-token headroom${r.cached_tokens>l.total_cache_tokens?`; ${number(r.cached_tokens-l.total_cache_tokens)} over target`:''}. ${l.slots} slots. Pressure evicts idle caches by least recent activity; no fixed countdown. Busy/current work can temporarily exceed the token target.`],
    ['Memory & model',l.model_unload_policy==='keep_loaded'?'Model stays loaded':l.model_unload_policy==='immediate'?'Unload when unused':`Unload after ${seconds(l.model_idle_seconds)} idle`, `No RAM-byte eviction threshold is configured. RSS includes more than cache; exact KV/GPU bytes are unavailable. Weight lifetime is separate from leases. Snapshots: ${l.snapshot_mode}.`]
  ];
  for(const [title,value,help] of items){const item=node('article',undefined,'limit');item.append(node('h3',title),node('p',value,'value'),node('p',help));container.append(item);}
  const c=r.counters, durations=r.events.filter(e=>e.kind==='request_completed'&&Number.isFinite(e.duration_ms)).map(e=>e.duration_ms);
  $('activity').replaceChildren(...[
    `Runtime uptime ${seconds(Math.max(0,(isLive()?currentTime():r.sampled_at)-r.started_at))}`,
    `${number(c.requests)} admitted chats`,`${number(c.request_errors)} failed / interrupted`,`${number(c.heartbeats)} app renewals`,`${number(c.cache_reuses)} cache reuses`,`${number(c.evictions)} cache evictions`,`${number(c.compactions)} compactions`,
    durations.length?`Mean completed request ${(durations.reduce((a,b)=>a+b,0)/durations.length/1000).toFixed(2)}s (${durations.length} retained events)`:'Request latency unavailable until a reply completes'
  ].map(text=>node('span',text)));
}
const names={runtime_started:'Runtime started',backend_ready:'Backend ready',backend_unavailable:'Backend unavailable',lease_renewed:'Lease renewed',lease_expired:'Lease expired',lease_released:'Lease released',cache_evicted:'Cache evicted',cache_rebuild:'Cache rebuild',cache_reused:'Cache reused',cache_erase_failed:'Cache erase failed',compaction_started:'Compaction started',compaction_completed:'Compaction completed',compaction_failed:'Compaction failed',request_completed:'Reply completed',request_failed:'Request failed',request_rejected:'Request rejected',heartbeat_rejected:'Heartbeat rejected',snapshot_saved:'Snapshot saved',snapshot_restored:'Snapshot restored',snapshot_failed:'Snapshot failed'};
function events() {
  const r=data?.runtime;if(!r){$('events').replaceChildren();$('history-note').textContent='Waiting for the current observation window';return;}
  const selected=$('event-session').value, refs=[...new Set([...r.sessions.map(s=>s.session),...r.events.map(e=>e.session).filter(Boolean)])].sort();
  const options=['all',...refs];if([...$('event-session').options].map(x=>x.value).join()!==options.join()){
    $('event-session').replaceChildren(...options.map(ref=>{const o=node('option',ref==='all'?'All conversations':chat(ref));o.value=ref;return o;}));
    $('event-session').value=options.includes(selected)?selected:'all';
  }
  const kind=$('event-kind').value, ref=$('event-session').value;
  const filtered=r.events.filter(e=>(ref==='all'||e.session===ref)&&(kind==='all'||e.kind===kind||(kind==='cache'&&/cache|compaction|snapshot/.test(e.kind))||(kind==='errors'&&/failed|rejected|unavailable/.test(e.kind))));
  $('events').replaceChildren();
  for(const e of [...filtered].reverse()){
    const details=[];if(e.reason)details.push(reasons[e.reason]||e.reason);if(e.expires_at)details.push(`expires ${when(e.expires_at)}`);if(e.tokens!==undefined)details.push(`${number(e.tokens)} tokens`);if(e.limit!==undefined)details.push(`budget ${number(e.limit)}`);if(e.slot!==undefined)details.push(`slot ${e.slot+1}`);if(e.duration_ms!==undefined)details.push(`${(e.duration_ms/1000).toFixed(2)}s`);
    const row=node('tr'); row.append(node('td',when(e.at)),node('td',chat(e.session)),node('td',names[e.kind]||e.kind,e.kind==='lease_renewed'?'renewal':/failed|rejected|unavailable/.test(e.kind)?'error':''),node('td',details.join(' • ')||'—'));$('events').append(row);
  }
  if(!filtered.length){const cell=node('td','No events match this view.','empty');cell.colSpan=4;const row=node('tr');row.append(cell);$('events').append(row);}
  $('history-note').textContent=`${filtered.length} shown of ${r.events.length} retained events (maximum ${r.event_capacity}). ${r.events_dropped?`${number(r.events_dropped)} older events have rolled out. `:''}Observation window began ${when(r.window_started_at || r.started_at)}; earlier history is not retained. ${restartSeen||data.restarts_observed?'A runtime restart was observed; its earlier history is gone. ':''}Times use ${Intl.DateTimeFormat().resolvedOptions().timeZone}.`;
}
function tick(){
  if(!data)return;connection();const r=data.runtime;if(!r)return;
  const live=isLive(), now=live?currentTime():r.sampled_at;
  if(!live) $('model-status').textContent=`${r.model} • Readiness unknown (old sample)`;
  document.querySelectorAll('[data-expires]').forEach(el=>{const remaining=Math.max(0,Number(el.dataset.expires)-now);if(el.tagName==='METER'){el.value=remaining;return;}el.textContent=!live?`${seconds(remaining)} (last seen)`:remaining>0?seconds(remaining):el.dataset.busy==='true'?'Protected while busy':'Awaiting expiry';});
}
async function refresh(){
  if(loading)return;loading=true;
  const controller=new AbortController(), timeout=setTimeout(()=>controller.abort(),4000);
  try{
    const response=await fetch('/api/monitor',{cache:'no-store',signal:controller.signal});if(!response.ok)throw new Error('monitor unavailable');
    const next=await response.json();if(!Number.isFinite(next.sampled_at))throw new Error('not yet sampled');
    if(expectedWindow && (!next.runtime || !windowAtLeast(next.runtime,expectedWindow))){next.runtime=null;next.history=[];}
    else if(next.runtime){expectedWindow=windowKey(next.runtime);}
    data=next;receivedAt=performance.now();fetchFailed=false;
    if(previousBoot&&data.runtime?.boot_id&&previousBoot!==data.runtime.boot_id)restartSeen=true;
    if(data.runtime)previousBoot=data.runtime.boot_id;
    resources();sessions();limits();events();controls();connection();
    $('footer-detail').textContent=`Only available on this Mac. Conversation text and original IDs are excluded. Collector ${number(data.sample_duration_ms)} ms / sample; resource history capped at ${data.history_capacity} samples.`;
  }catch(_error){fetchFailed=true;tick();connection();}finally{clearTimeout(timeout);loading=false;}
}
let controlBusy=false, expectedWindow=null;
const windowKey = r => ({boot_id:r.boot_id,window_id:r.window_id,window_sequence:r.window_sequence || 0,producer_generation:r.producer_generation || 0});
function windowAtLeast(candidate,floor){
  if(!floor)return true;
  const c=windowKey(candidate), f=windowKey(floor);
  if(c.producer_generation!==f.producer_generation)return c.producer_generation>f.producer_generation;
  if(c.boot_id!==f.boot_id)return false;
  return c.window_sequence>f.window_sequence || (c.window_sequence===f.window_sequence && c.window_id===f.window_id);
}
function controls(){
  const r=data?.runtime;
  $('observation-window').textContent=r?`Observation window began ${when(r.window_started_at || r.started_at)}`:'Waiting for a fresh runtime window';
  const select=$('cache-target'), selected=select.value;
  const options=[['','Choose a target…'],['all','All caches'],...(r?.sessions || []).map(s=>[s.session,`${chat(s.session)}${s.in_flight?' (busy)':''}`])];
  if(JSON.stringify([...select.options].map(o=>[o.value,o.textContent]))!==JSON.stringify(options)){
    select.replaceChildren(...options.map(([value,label])=>{const option=node('option',label);option.value=value;return option;}));
    select.value=options.some(o=>o[0]===selected)?selected:'';
  }
  if(r?.model_process.paused || r?.recovery_required){
    $('recovery').open=true;
    $('model-status').textContent=r.model_process.paused?'Model manually paused — reload required':'Cache recovery required — unload and reload';
  }
  for(const id of ['reset-data','evict-cache','unload-model','reload-model'])$(id).disabled=controlBusy || !data?.control_token;
}
async function runControl(action){
  if(controlBusy)return;
  const target=$('cache-target').value;
  if(action==='evict'&&!target){$('control-result').textContent='Choose a conversation or All caches first.';return;}
  if(action==='unload'&&!$('interrupt-confirm').checked){$('control-result').textContent='Confirm that all chats will be interrupted before unloading.';$('recovery').open=true;return;}
  controlBusy=true;controls();$('control-result').className='';
  $('control-result').textContent=action==='reload'?'Reloading the model; allow up to 60 seconds…':'Control running; monitoring continues…';
  const controller=new AbortController(), timer=setTimeout(()=>controller.abort(),65000);
  try{
    const response=await fetch('/api/control',{method:'POST',headers:{'Content-Type':'application/json','X-Dashboard-Token':data.control_token},body:JSON.stringify({action,target}),signal:controller.signal});
    const result=await response.json();
    $('control-result').textContent=result.message || 'Control failed.';$('control-result').className=result.ok?'':'error';
    if(!result.ok&&action==='evict')$('recovery').open=true;
    const describe=m=>m?.available?`host ${gib(m.host_used_bytes)}; model RSS ${m.model_process_exists?gib(m.model_rss_bytes):'no supervised process observed'}`:'measurement unavailable';
    $('control-memory').textContent=`Before (${when(result.before?.at)}): ${describe(result.before)}. After (${when(result.after?.at)}): ${describe(result.after)}. Host totals include other apps; RSS does not isolate KV/GPU memory. A lower cache counter is not proof of returned RAM.`;
    if(action==='reset'&&result.ok){if(windowAtLeast(result,expectedWindow))expectedWindow=windowKey(result);data.runtime=null;data.history=[];restartSeen=false;$('activity').replaceChildren();$('events').replaceChildren();resources();sessions();}
    await refresh();
  }catch(_error){$('control-result').className='error';$('control-result').textContent='Control connection failed or timed out. Outcome is unknown; inspect live state before retrying.';}
  finally{clearTimeout(timer);controlBusy=false;controls();}
}
for(const [id,action] of [['reset-data','reset'],['evict-cache','evict'],['unload-model','unload'],['reload-model','reload']])$(id).addEventListener('click',()=>runControl(action));
$('refresh').addEventListener('click',refresh);$('event-kind').addEventListener('change',events);$('event-session').addEventListener('change',events);
refresh();setInterval(refresh,2000);setInterval(tick,1000);
