// Metadata-only execution record. A passing local run is never a launch verdict.
export function disabledControls(value) {
  return value && typeof value==='object' && !Array.isArray(value) && Object.keys(value).length>0 && Object.values(value).every(v=>v===false);
}
export function controlsMatch(before,after) {
  return disabledControls(before)&&disabledControls(after)&&Object.keys(before).sort().join('\n')===Object.keys(after).sort().join('\n');
}
export async function executeVerification({suite,stages,preflight,controls,run,save,log=()=>{},now=()=>Date.now()}) {
  const result={schemaVersion:2,suite,target:'local-only',startedAt:new Date(now()).toISOString(),status:'running',preflight:'pending',
    stages:stages.map(s=>({name:s.name,status:'not_run',durationMs:null})),controlsRestored:null,reason:null,
    limitations:['Pending SQL drafts are excluded from the active database suite','No production-shaped dataset','No concurrent staff load baseline','No field INP or staging SLO certification','No production pilot enabled']};
  let before=null;
  await save(result);
  try {
    // Catch command/SDK errors here, before their potentially sensitive payloads
    // can reach stderr or the evidence file. The failure code is deliberately fixed.
    try {await preflight();before=controls();}
    catch {result.preflight='blocked';result.reason='local-preflight-unavailable';result.status='blocked';return result;}
    if(!disabledControls(before)){result.preflight='blocked';result.reason='local-controls-not-disabled';result.status='blocked';return result;}
    result.preflight='passed';await save(result);
    for(let i=0;i<stages.length;i++) {
      const entry=result.stages[i],start=now();entry.status='running';log(`START ${entry.name}`);await save(result);
      let code;
      try {code=await run(stages[i]);}catch {code=null;}
      entry.status=code===0?'passed':'failed';entry.durationMs=Math.max(0,now()-start);
      log(`${code===0?'PASS':'FAIL'} ${entry.name}`);await save(result);
      if(code!==0){result.reason='stage-failed';result.status='failed';return result;}
      let after;try{after=controls();}catch{after=null;}
      if(!controlsMatch(before,after)){result.reason='control-restoration-unverified';result.status='failed';return result;}
    }
    result.status='local_passed';return result;
  } finally {
    if(disabledControls(before)) {
      try{result.controlsRestored=controlsMatch(before,controls());}catch{result.controlsRestored=false;}
      if(!result.controlsRestored){result.status='failed';result.reason='control-restoration-unverified';}
    }
    result.finishedAt=new Date(now()).toISOString();await save(result);
  }
}
