import http from 'node:http';
import crypto from 'node:crypto';
import { renderTextToPngsWithCharLimit, DENSE_CONTENT_COLS, DENSE_CONTENT_CHARS_PER_IMAGE, DENSE_RENDER_STYLE, PAD_X, PAD_Y, CELL_W, CELL_H } from './vendor/render.js';
import { bytesToBase64 } from './vendor/png.js';

const PORT = Number(process.env.PORT || 47822);
const MAX_BODY_BYTES = Number(process.env.COMPRESSOR_MAX_BODY_BYTES || 32 * 1024 * 1024);
const MAX_IMAGES = Math.min(100, Number(process.env.COMPRESSOR_MAX_IMAGES || 80));
const MIN_CHARS = Number(process.env.COMPRESSOR_MIN_CHARS || 6000);
const SAFETY_TOKENS = Number(process.env.COMPRESSOR_SAFETY_TOKENS || 128);
const TEXT_CHARS_PER_TOKEN = Number(process.env.COMPRESSOR_TEXT_CHARS_PER_TOKEN || 2);
const KEEP_TAIL_ITEMS = Number(process.env.COMPRESSOR_HISTORY_KEEP_TAIL || 12);
const HISTORY_CHUNK_ITEMS = Number(process.env.COMPRESSOR_HISTORY_CHUNK_ITEMS || 10);
const PNG_PREFIX = 'data:image/png;base64,';

function enabled(value, fallback = true) {
  if (value === undefined || value === null || value === '') return fallback;
  return !['0', 'off', 'false', 'no'].includes(String(value).toLowerCase());
}
function stableStringify(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(stableStringify).join(',') + ']';
  return '{' + Object.keys(value).sort().map(k => JSON.stringify(k) + ':' + stableStringify(value[k])).join(',') + '}';
}
function isClaude(model) {
  const leaf = String(model || '').toLowerCase().split('/').pop();
  return leaf.startsWith('claude-');
}
function textFromContent(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.filter(b => b && (b.type === 'input_text' || b.type === 'output_text' || b.type === 'text') && typeof b.text === 'string').map(b => b.text).join('\n');
}
function outputText(output) {
  if (typeof output === 'string') return output;
  if (!Array.isArray(output)) return '';
  return output.filter(b => b && (b.type === 'input_text' || b.type === 'output_text' || b.type === 'text') && typeof b.text === 'string').map(b => b.text).join('\n');
}
function imageDimensions(png) {
  const view = new DataView(png.buffer, png.byteOffset, png.byteLength);
  return { width: view.getUint32(16), height: view.getUint32(20) };
}
function profitable(text, dims) {
  const imageTokens = Math.ceil(dims.reduce((n, d) => n + d.width * d.height / 750, 0) * 1.10);
  const textTokens = Math.ceil(text.length / TEXT_CHARS_PER_TOKEN);
  return { imageTokens, textTokens, profitable: imageTokens + SAFETY_TOKENS < textTokens };
}
async function render(text, bucket) {
  if (text.length < MIN_CHARS) return null;
  const pages = await renderTextToPngsWithCharLimit(text, DENSE_CONTENT_COLS, DENSE_CONTENT_CHARS_PER_IMAGE, DENSE_RENDER_STYLE);
  if (!pages.length || pages.length > MAX_IMAGES) return null;
  const dims = pages.map(p => imageDimensions(p.png));
  const gate = profitable(text, dims);
  if (!gate.profitable) return { applied: false, bucket, ...gate };
  return {
    applied: true, bucket, ...gate,
    images: pages.map((p, i) => ({ type: 'input_image', image_url: PNG_PREFIX + bytesToBase64(p.png), hash: crypto.createHash('sha256').update(p.png).digest('hex'), ...dims[i] }))
  };
}
function imageBlocks(rendered) {
  return rendered.images.map(({ hash, width, height, ...block }) => block);
}
function toolDoc(tool) {
  const name = tool?.name || tool?.function?.name || '';
  const description = tool?.description || tool?.function?.description || '';
  const parameters = tool?.parameters || tool?.input_schema || tool?.function?.parameters || {};
  return stableStringify({ name, description, parameters });
}
function stripSchemaAnnotations(value, depth = 0) {
  if (depth > 20 || value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map(v => stripSchemaAnnotations(v, depth + 1));
  const out = {};
  for (const [key, child] of Object.entries(value)) {
    if (['description', 'title', 'examples', 'default', '$schema', '$id', '$comment'].includes(key)) continue;
    if (key === 'properties' || key === 'patternProperties' || key === '$defs' || key === 'definitions') {
      out[key] = Object.fromEntries(Object.entries(child || {}).map(([name, schema]) => [name, stripSchemaAnnotations(schema, depth + 1)]));
    } else out[key] = stripSchemaAnnotations(child, depth + 1);
  }
  return out;
}
function minimizeTool(tool) {
  const clone = structuredClone(tool);
  if ('description' in clone) clone.description = '';
  if ('parameters' in clone) clone.parameters = stripSchemaAnnotations(clone.parameters);
  if ('input_schema' in clone) clone.input_schema = stripSchemaAnnotations(clone.input_schema);
  if (clone.function) {
    if ('description' in clone.function) clone.function.description = '';
    if ('parameters' in clone.function) clone.function.parameters = stripSchemaAnnotations(clone.function.parameters);
  }
  return clone;
}
function callID(item) { return item?.call_id || item?.id || ''; }
function closedHistoryBoundary(input, limit) {
  const open = new Set(); let boundary = -1;
  for (let i = 0; i < Math.min(limit, input.length); i++) {
    const item = input[i];
    if (item?.type === 'function_call') open.add(callID(item));
    if (item?.type === 'function_call_output') open.delete(callID(item));
    if (open.size === 0) boundary = i;
  }
  return boundary;
}
function historyText(items) {
  return items.map(item => {
    if (item?.type === 'function_call') return stableStringify({ name: item.name, arguments: item.arguments });
    if (item?.type === 'function_call_output') return outputText(item.output);
    return textFromContent(item?.content);
  }).filter(Boolean).join('\n\n');
}
function collectText(value, out = []) {
  if (typeof value === 'string') out.push(value);
  else if (Array.isArray(value)) value.forEach(v => collectText(v, out));
  else if (value && typeof value === 'object') Object.values(value).forEach(v => collectText(v, out));
  return out;
}
function validate(original, transformed) {
  const originalCurrent = [...original.input].reverse().find(i => i?.role === 'user' && textFromContent(i.content));
  if (originalCurrent) {
    const currentText = textFromContent(originalCurrent.content);
    if (!collectText(transformed.input).includes(currentText)) throw new Error('current user request was not preserved');
  }
  const ids = new Set();
  for (const item of transformed.input) {
    if (item?.type === 'function_call') {
      const id = callID(item); if (!id || ids.has(id)) throw new Error('duplicate or empty call id'); ids.add(id);
    }
  }
  const images = JSON.stringify(transformed).match(/data:image\/png;base64,/g)?.length || 0;
  if (images > MAX_IMAGES) throw new Error('image limit exceeded');
  if (Buffer.byteLength(JSON.stringify(transformed)) > MAX_BODY_BYTES) throw new Error('request size exceeded');
}
async function transform(body) {
  if (!body || !isClaude(body.model) || !Array.isArray(body.input)) return { request: body, changed: false, diagnostics: [] };
  const original = structuredClone(body); const request = structuredClone(body); const diagnostics = [];
  let imagesUsed = 0;
  if (enabled(body.options?.static, true)) {
    const staticItems = request.input.filter(i => ['system', 'developer'].includes(i?.role));
    const slabText = [...staticItems.map(i => textFromContent(i.content)), ...(request.tools || []).map(toolDoc)].filter(Boolean).join('\n\n');
    const rendered = await render(slabText, 'static');
    if (rendered) diagnostics.push(rendered);
    if (rendered?.applied && imagesUsed + rendered.images.length <= MAX_IMAGES) {
      request.input = request.input.filter(i => !['system', 'developer'].includes(i?.role));
      const firstUser = request.input.findIndex(i => i?.role === 'user');
      const slab = { type: 'message', role: 'user', content: imageBlocks(rendered) };
      request.input.splice(firstUser < 0 ? 0 : firstUser, 0, slab);
      request.tools = (request.tools || []).map(minimizeTool);
      imagesUsed += rendered.images.length;
    }
  }
  if (enabled(body.options?.tool_results, true)) {
    for (const item of request.input) {
      if (item?.type !== 'function_call_output' || item.error) continue;
      const text = outputText(item.output); const rendered = await render(text, 'tool_result');
      if (rendered) diagnostics.push(rendered);
      if (rendered?.applied && imagesUsed + rendered.images.length <= MAX_IMAGES) {
        const preserved = Array.isArray(item.output) ? item.output.filter(b => !b || !['input_text', 'output_text', 'text'].includes(b.type)) : [];
        item.output = [...imageBlocks(rendered), ...preserved]; imagesUsed += rendered.images.length;
      }
    }
  }
  if (enabled(body.options?.history, true) && request.input.length > KEEP_TAIL_ITEMS + HISTORY_CHUNK_ITEMS) {
    const firstRealUser = request.input.findIndex(i => i?.role === 'user' && textFromContent(i.content));
    const start = firstRealUser < 0 ? 0 : firstRealUser + 1;
    const available = request.input.length - start - KEEP_TAIL_ITEMS;
    const frozenCount = Math.floor(available / HISTORY_CHUNK_ITEMS) * HISTORY_CHUNK_ITEMS;
    const boundary = closedHistoryBoundary(request.input.slice(start), frozenCount);
    if (boundary >= HISTORY_CHUNK_ITEMS - 1) {
      const text = historyText(request.input.slice(start, start + boundary + 1)); const rendered = await render(text, 'history');
      if (rendered) diagnostics.push(rendered);
      if (rendered?.applied && imagesUsed + rendered.images.length <= MAX_IMAGES) {
        request.input.splice(start, boundary + 1, { type: 'message', role: 'user', content: imageBlocks(rendered) }); imagesUsed += rendered.images.length;
      }
    }
  }
  validate(original, request);
  return { request, changed: stableStringify(original) !== stableStringify(request), diagnostics: diagnostics.map(d => ({ bucket: d.bucket, applied: d.applied, text_tokens: d.textTokens, image_tokens: d.imageTokens, png_hashes: d.images?.map(i => i.hash) || [] })) };
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') { res.writeHead(200, {'content-type':'application/json'}); return res.end('{"ok":true}'); }
  if (req.method !== 'POST' || req.url !== '/compress') { res.writeHead(404); return res.end(); }
  let size = 0; const chunks = [];
  req.on('data', chunk => { size += chunk.length; if (size > MAX_BODY_BYTES) req.destroy(); else chunks.push(chunk); });
  req.on('end', async () => {
    try { const result = await transform(JSON.parse(Buffer.concat(chunks).toString('utf8'))); res.writeHead(200, {'content-type':'application/json'}); res.end(JSON.stringify(result)); }
    catch (error) { res.writeHead(422, {'content-type':'application/json'}); res.end(JSON.stringify({error:String(error?.message || error)})); }
  });
});
if (process.argv[1] === new URL(import.meta.url).pathname) server.listen(PORT, '0.0.0.0');
export { transform, stableStringify, profitable, closedHistoryBoundary };
