import assert from 'node:assert/strict';
import {executeVerification,disabledControls,controlsMatch} from './verification-run.mjs';
assert(!disabledControls({}));assert(!disabledControls({a:0}));assert(!disabledControls({a:true}));assert(!disabledControls(null));
assert(controlsMatch({a:false,b:false},{b:false,a:false}));assert(!controlsMatch({a:false,b:false},{a:false}));
const stages=[{name:'alpha'},{name:'beta'}];
async function scenario(overrides={}) {
 const saved=[],logs=[],ran=[];
 const result=await executeVerification({suite:'synthetic',stages,preflight:async()=>{},controls:()=>({a:false}),run:async s=>{ran.push(s.name);return 0;},save:async r=>saved.push(JSON.parse(JSON.stringify(r))),log:s=>logs.push(s),...overrides});
 assert(!JSON.stringify({saved,logs,result}).includes('PRIVATE-SENTINEL'));
 return {result,saved,logs,ran};
}
let r=await scenario();assert.equal(r.result.status,'local_passed');assert.equal(r.result.controlsRestored,true);assert.deepEqual(r.ran,['alpha','beta']);assert.equal(r.saved[0].stages[0].status,'not_run');
r=await scenario({preflight:async()=>{throw Error('PRIVATE-SENTINEL');}});assert.equal(r.result.status,'blocked');assert.equal(r.result.controlsRestored,null);assert.equal(r.ran.length,0);assert(r.result.stages.every(s=>s.status==='not_run'));
r=await scenario({controls:()=>({a:true})});assert.equal(r.result.reason,'local-controls-not-disabled');assert.equal(r.ran.length,0);
r=await scenario({controls:()=>{throw Error('PRIVATE-SENTINEL');}});assert.equal(r.result.preflight,'blocked');
r=await scenario({run:async()=>{throw Error('PRIVATE-SENTINEL');}});assert.equal(r.result.status,'failed');assert.equal(r.result.stages[0].status,'failed');assert.equal(r.result.stages[1].status,'not_run');
r=await scenario({run:async()=>2});assert.equal(r.result.status,'failed');
let reads=0;r=await scenario({controls:()=>++reads===1?{a:false,b:false}:{a:false}});assert.equal(r.result.reason,'control-restoration-unverified');assert.equal(r.result.controlsRestored,false);assert.equal(r.result.stages[1].status,'not_run');
reads=0;r=await scenario({controls:()=>{if(++reads===4)throw Error('PRIVATE-SENTINEL');return {a:false};}});assert.equal(r.result.status,'failed','even final inventory failure invalidates passing stages');
console.log('PASS verification recorder: preflight blockers, safe failures, pending-stage truth, control inventory drift and final restoration checks');
