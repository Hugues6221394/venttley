// Execute the actual submit handlers with a deterministic hook/form adapter.
// Complements, but does not replace, the pending hydrated-browser test.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import vm from 'node:vm';
import ts from 'typescript';
const require=createRequire(import.meta.url);
const source=await readFile(new URL('../components/workflows/workflow-form.tsx',import.meta.url),'utf8');
const code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX}}).outputText;
function harness(action,blockUncertainRetry=true) {
 const slots=[];let cursor=0,initialized=false,readyEffect,tree,refreshes=0;
 const useState=initial=>{const i=cursor++;if(!(i in slots))slots[i]=initial;return [slots[i],value=>{slots[i]=value;}];};
 const useRef=initial=>{const i=cursor++;return slots[i]??=( {current:initial} );};
 class LocalFormData extends Map {constructor(form){super(form.values);}}
 const exported={};
 const mocks={
  react:{useState,useRef,useId:()=> 'synthetic-id',useEffect:(callback,deps)=>{if(!deps.length&&!initialized)readyEffect=callback;}},
  'next/navigation':{useRouter:()=>({refresh:()=>refreshes++})},
  'next/link':{default:()=>null},
  '@/components/staff-attention':{useStaffAttention:()=>({refresh:()=>refreshes++})},
  '@/lib/workflow-model':{workflowFailure:()=>({status:'unknown',message:'Unconfirmed result'})},
 };
 vm.runInNewContext(code,{exports:exported,FormData:LocalFormData,require:name=>name in mocks?mocks[name]:require(name)});
 const form={values:new Map([['reason','Sensitive retained reason'],['operation_id','fixed-operation']]),requestSubmit:()=>{void tree.props.onSubmit({preventDefault(){},currentTarget:form});}};
 const render=()=>{cursor=0;tree=exported.WorkflowForm({action,label:'Save',confirmation:'Check access',children:null,blockUncertainRetry});tree.props.ref.current=form;return tree;};
 const submit=()=>tree.props.onSubmit({preventDefault(){},currentTarget:form});
 const walk=node=>!node||typeof node!=='object'?[]:[node,...[node.props?.children].flat(Infinity).flatMap(walk)];
 const button=type=>walk(tree).find(node=>node.type==='button'&&(type==='submit'?node.props.type==='submit':Array.isArray(node.props.children)&&node.props.children[0]==='Confirm '));
 const mount=()=>{readyEffect();initialized=true;render();};
 render();
 return {render,submit,mount,form,button,tree:()=>tree,refreshes:()=>refreshes};
}
let resolve,submitted=0;
const h=harness(async fd=>{submitted++;assert.equal(fd.get('reason'),'Sensitive retained reason');return new Promise(done=>{resolve=done;});});
assert.equal(h.tree().props.method,'post');assert.equal(h.button('submit').props.disabled,true);
await h.submit();assert.equal(submitted,0,'pre-hydration submit blocked');
h.mount();assert.equal(h.button('submit').props.disabled,false);
await h.submit();h.render();assert.equal(submitted,0,'first submit requests confirmation only');
const confirm=h.button('confirm');confirm.props.onClick();confirm.props.onClick();
h.render();assert.equal(submitted,1,'double confirmation dispatches once');assert.equal(h.button('submit').props.disabled,true);
resolve({status:'unknown',message:'Inspect before retrying'});await new Promise(done=>setTimeout(done,0));
h.render();assert.equal(h.button('submit').props.disabled,true);await h.submit();assert.equal(submitted,1);
assert.equal(h.form.values.get('reason'),'Sensitive retained reason');assert.equal(h.refreshes(),0,'ambiguous writes do not refresh/clear inputs');
let attempts=0;
const retry=harness(async()=>{attempts++;return {status:'error',message:'MFA required'};});
retry.mount();await retry.submit();retry.render();retry.button('confirm').props.onClick();await new Promise(done=>setTimeout(done,0));retry.render();
assert.equal(retry.button('submit').props.disabled,false,'definite preflight failure allows correction');
assert.equal(retry.form.values.get('reason'),'Sensitive retained reason');assert.equal(attempts,1);
const failed=harness(async()=>{throw Error('transport failure');});
failed.mount();await failed.submit();failed.render();failed.button('confirm').props.onClick();await new Promise(done=>setTimeout(done,0));failed.render();assert.equal(failed.button('submit').props.disabled,true,'thrown/ambiguous transport locks staff retry');
let successes=0;
const success=harness(async()=>{successes++;return {status:'success',message:'Confirmed'};});
success.mount();await success.submit();success.render();success.button('confirm').props.onClick();await new Promise(done=>setTimeout(done,0));success.render();
assert.equal(success.button('submit'),undefined);await success.submit();assert.equal(successes,1,'confirmed operation cannot be resubmitted');assert.equal(success.refreshes(),1);
console.log('PASS workflow form handlers: hydration gate, POST fallback, confirmation, duplicate pending submit, retained inputs and uncertain retry lock (synthetic hooks/form adapter)');
