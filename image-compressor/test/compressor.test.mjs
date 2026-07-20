import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { transform, stableStringify, profitable, closedHistoryBoundary } from '../server.mjs';

const long = (label) => Array.from({length: 500}, (_, i) => `${label} ${i} value=${i * 17}`).join('\n');
const fixture = () => ({
  model: 'muskapi/claude-sonnet-5',
  input: [
    {type:'message', role:'developer', content:[{type:'input_text', text:long('system')}]},
    {type:'message', role:'user', content:[{type:'input_text', text:'CURRENT_REQUEST'}]},
    {type:'function_call', call_id:'call_1', name:'Read', arguments:'{}'},
    {type:'function_call_output', call_id:'call_1', output:[{type:'input_text', text:long('output')}]},
  ],
  tools:[{type:'function', name:'Read', description:long('tool'), parameters:{type:'object',properties:{path:{type:'string',description:'path'}}}}],
  options:{static:true,tool_results:true,history:false}
});

test('same input produces identical PNG bytes', async () => {
  const a = await transform(fixture()); const b = await transform(fixture());
  assert.equal(stableStringify(a.request), stableStringify(b.request));
  assert.deepEqual(a.diagnostics.map(x => x.png_hashes), b.diagnostics.map(x => x.png_hashes));
});
test('current request and call identity survive compression', async () => {
  const result = await transform(fixture()); const raw = JSON.stringify(result.request);
  assert.match(raw, /CURRENT_REQUEST/); assert.match(raw, /call_1/); assert.doesNotMatch(raw, /pxpipe|relocated context|Tool Reference|preceding image/i);
});
test('non Claude input is byte semantic pass-through', async () => {
  const body = fixture(); body.model = 'gpt-5.6-sol'; const result = await transform(body);
  assert.equal(stableStringify(result.request), stableStringify(body)); assert.equal(result.changed, false);
});
test('history freeze boundary remains stable after appending live tail', () => {
  const input=[]; for(let i=0;i<30;i++){input.push({type:'function_call',call_id:`c${i}`});input.push({type:'function_call_output',call_id:`c${i}`});}
  const a=closedHistoryBoundary(input,40); const b=closedHistoryBoundary([...input,{role:'user',content:'next'}],40); assert.equal(a,b); assert.equal(a,39);
});
test('profit gate requires explicit safety margin', () => {
  assert.equal(profitable('x'.repeat(100), [{width:1568,height:728}]).profitable, false);
  assert.equal(profitable('x'.repeat(100000), [{width:1568,height:728}]).profitable, true);
});

test('history keeps the first real user request native', async () => {
  const body={model:'claude-sonnet-5',input:[{type:'message',role:'user',content:[{type:'input_text',text:'FIRST_USER'}]}],tools:[],options:{static:false,tool_results:false,history:true}};
  for(let i=0;i<30;i++){body.input.push({type:'function_call',call_id:`h${i}`,name:'Read',arguments:'{}'});body.input.push({type:'function_call_output',call_id:`h${i}`,output:[{type:'input_text',text:long(`history${i}`)}]});}
  body.input.push({type:'message',role:'user',content:[{type:'input_text',text:'CURRENT_USER'}]});
  const result=await transform(body); const raw=JSON.stringify(result.request);
  assert.match(raw,/FIRST_USER/); assert.match(raw,/CURRENT_USER/);
});
test('tool schemas retain property names while annotations are removed', async () => {
  const result=await transform(fixture()); const tool=result.request.tools[0];
  assert.equal(tool.description,''); assert.ok(tool.parameters.properties.path); assert.equal('description' in tool.parameters.properties.path,false);
});
