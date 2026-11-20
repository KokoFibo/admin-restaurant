// Uji /api/translate dengan Supabase & Google (Gemini) palsu: memastikan HANYA satu model dipakai (gemini-3.1-flash-lite), tanpa pemilihan otomatis/cadangan.
import { build } from 'esbuild';
import { pathToFileURL } from 'node:url';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

let pass = 0, fail = 0; const ok = (n, c, x = '') => { c ? pass++ : fail++; console.log(c ? '  ✔' : '  ✘', n, c ? '' : x); };
const dir = mkdtempSync(join(tmpdir(), 'tr-')), out = join(dir, 'translate.mjs');
const r = await build({ entryPoints: ['functions/api/translate.ts'], bundle: true, format: 'esm', platform: 'node', write: false, target: 'es2022' });
writeFileSync(out, r.outputFiles[0].text);
const { onRequestPost } = await import(pathToFileURL(out).href);

const T = '11111111-1111-1111-1111-111111111111';
let gemini = [], other = [], mode = 'ok', geminiBody = null;
const real = globalThis.fetch;
globalThis.fetch = async (input, init = {}) => {
  const u = String(input?.url ?? input), method = (init.method || 'GET').toUpperCase();
  const j = (o, status = 200, h = {}) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json', ...h } });
  if (u.startsWith('https://supabase.test/auth/v1/user')) return j({ id: 'u1', aud: 'authenticated', email: 'o@x', app_metadata: {}, user_metadata: {}, created_at: '2026-01-01T00:00:00Z' });
  if (u.includes('/rest/v1/tenant_languages')) return j([{ lang: 'id' }, { lang: 'en' }, { lang: 'zh' }, { lang: 'zt' }]);
  if (u.includes('/rest/v1/languages')) return j([{ code: 'id', name_english: 'Indonesian', max_name: 40, max_short: 120, max_detail: 400 }, { code: 'en', name_english: 'English', max_name: 12, max_short: 120, max_detail: 400 }, { code: 'zh', name_english: 'Chinese (Simplified)', max_name: 30, max_short: 80, max_detail: 350 }, { code: 'zt', name_english: 'Chinese (Traditional)', max_name: 30, max_short: 80, max_detail: 350 }]);
  if (u.includes('/rest/v1/tenants')) return j({ restaurant_type: 'vegan' });
  if (u.includes('/rest/v1/rpc/consume_ai')) return j(true);
  if (u.startsWith('https://gemini.test/')) {
    gemini.push(u); geminiBody = init.body ? JSON.parse(init.body) : null;
    if (mode === 'net') throw new Error('ECONNRESET');
    if (mode === '404') return j({ error: { message: 'models/xyz is not found for API version v1beta' } }, 404);
    if (mode === '429') return j({ error: { message: 'quota' } }, 429);
    if (mode === '500') return j({ error: { message: 'Internal error' } }, 500);
    if (mode === 'trunc') return j({ candidates: [{ finishReason: 'MAX_TOKENS', content: { parts: [{ text: '{"eyebrow":"Ab' }] } }] });
    if (mode === 'hero') { const src = JSON.parse(geminiBody.contents[0].parts[0].text).texts; return j({ candidates: [{ content: { parts: [{ text: JSON.stringify(Object.fromEntries(Object.keys(src).map(k => [k, 'EN ' + src[k]]))) }] } }] }); }
    if (mode === 'junk') return j({ candidates: [{ content: { parts: [{ text: 'bukan json' }] } }] });
    if (mode === 'long') return j({ candidates: [{ content: { parts: [{ text: JSON.stringify({ name: 'A very long dish name that is too long' }) }] } }] });
    return j({ candidates: [{ content: { parts: [{ thought: true, text: 'berpikir' }, { text: '```json\n{"name":"Tofu"}\n```' }] } }] });
  }
  other.push(u); return j({ error: 'tak terduga: ' + u }, 500);
};
const env = (extra = {}) => ({ PUBLIC_SUPABASE_URL: 'https://supabase.test', PUBLIC_SUPABASE_ANON_KEY: 'anon', GEMINI_API_KEY: 'k', AI_BASE_URL: 'https://gemini.test/v1beta', ...extra });
const call = async (e = env(), fields = { name: 'Tahu' }, target = 'en') => {
  gemini = []; other = []; geminiBody = null;
  const res = await onRequestPost({ request: new Request('https://admin.test/api/translate', { method: 'POST', headers: { authorization: 'Bearer t', 'content-type': 'application/json' }, body: JSON.stringify({ tenant_id: T, source: 'id', target, fields }) }), env: e });
  return { status: res.status, body: await res.json() };
};

console.log('\nTerjemahan: satu model tetap');
let r1 = await call(); mode = 'ok'; r1 = await call();
ok('berhasil: hasil terjemahan dikembalikan (blok ``` dan "thought" dibuang)', r1.status === 200 && r1.body.fields.name === 'Tofu', JSON.stringify(r1));
ok('tepat SATU panggilan ke Gemini, ke gemini-3.1-flash-lite', gemini.length === 1 && gemini[0] === 'https://gemini.test/v1beta/models/gemini-3.1-flash-lite:generateContent', gemini.join(','));
ok('TIDAK membaca daftar model (tanpa pemilihan otomatis)', !gemini.some(u => u.includes('/models?')) && other.length === 0, other.join(','));
ok('tanpa pengaturan "thinking" yang kedaluwarsa; JSON mode & temperature 0,2 dipertahankan', geminiBody.generationConfig.responseMimeType === 'application/json' && geminiBody.generationConfig.temperature === 0.2 && !('thinkingConfig' in geminiBody.generationConfig));
const r2 = await call(env({ AI_MODEL: 'gemini-lain' })); ok('AI_MODEL (opsional) mengganti model bila diisi', gemini.length === 1 && gemini[0].endsWith('/models/gemini-lain:generateContent'), gemini.join(','));
const r3 = await call(env({ AI_MODEL: '   ' })); ok('AI_MODEL kosong/spasi → tetap gemini-3.1-flash-lite', gemini[0].endsWith('/models/gemini-3.1-flash-lite:generateContent'), gemini.join(','));
mode = 'long'; const r4 = await call(); ok('batas panjang tetap dicek (over)', r4.status === 200 && r4.body.over.includes('name'), JSON.stringify(r4.body));
mode = '404'; const r5 = await call(); ok('model tidak tersedia (404): 502 + nama model di detail, TANPA model cadangan', r5.status === 502 && r5.body.detail.startsWith('gemini-3.1-flash-lite:') && gemini.length === 1, JSON.stringify(r5.body) + ' calls=' + gemini.length);
mode = '429'; const r6 = await call(); ok('batas pemakaian (429): 503 pesan "Batas pemakaian AI penuh", tanpa model cadangan', r6.status === 503 && r6.body.error.includes('Batas pemakaian') && gemini.length === 1);
mode = '500'; const r7 = await call(); ok('galat server Google (500): 502 dengan rincian (bukan "Format tidak valid")', r7.status === 502 && r7.body.error === 'Layanan terjemahan gagal' && r7.body.detail.includes('Internal error'), JSON.stringify(r7.body));
mode = 'net'; const r8 = await call(); ok('Google tidak terjangkau: 502 + rincian', r8.status === 502 && r8.body.detail === 'Layanan Google tidak terjangkau', JSON.stringify(r8.body));
mode = 'junk'; const r9 = await call(); ok('keluaran bukan JSON: 502 "Format terjemahan tidak valid"', r9.status === 502 && r9.body.error === 'Format terjemahan tidak valid', JSON.stringify(r9.body));

console.log('\nHero website (9 kolom) dan batas kolom');
const HERO = { eyebrow: 'Vegetarian', title: 'Rasa', title_em: 'tenang', lead: 'Deskripsi hero', chip1: 'Halal', chip2: 'Segar', chip3: 'Sehat', cta_order: 'Pesan', cta_menu: 'Menu' };
mode = 'hero'; const h1 = await call(env(), HERO);
ok('hero 9 kolom: berhasil, semua kolom diterjemahkan', h1.status === 200 && Object.keys(h1.body.fields).length === 9 && h1.body.fields.cta_menu === 'EN Menu', JSON.stringify(h1));
ok('hero: tetap satu panggilan ke gemini-3.1-flash-lite', gemini.length === 1 && gemini[0].endsWith('/models/gemini-3.1-flash-lite:generateContent'));
ok('hero: batas keluaran 8192 token', geminiBody.generationConfig.maxOutputTokens === 8192);
const THIRTEEN = Object.fromEntries(Array.from({ length: 13 }, (_, i) => ['k' + i, 'x']));
const h2 = await call(env(), THIRTEEN); ok('13 kolom ditolak 400 dengan rincian, tanpa memanggil Gemini', h2.status === 400 && h2.body.detail.includes('maks 12') && gemini.length === 0, JSON.stringify(h2.body));
const h3 = await call(env(), { a: '   ', b: '' }); ok('semua kolom kosong: 400 dengan rincian', h3.status === 400 && h3.body.detail.includes('Tidak ada teks') && gemini.length === 0, JSON.stringify(h3.body));
const TWELVE = Object.fromEntries(Array.from({ length: 12 }, (_, i) => ['k' + i, 'x']));
const h4 = await call(env(), TWELVE); ok('12 kolom (batas) masih diterima', h4.status === 200, JSON.stringify(h4.body));
mode = 'trunc'; const h5 = await call(env(), HERO); ok('hasil terpotong (MAX_TOKENS): 502 dengan pesan yang jelas', h5.status === 502 && h5.body.detail.includes('terpotong'), JSON.stringify(h5.body));

console.log('\nChinese Traditional (zt) dan Simplified (zh)');
mode = 'ok';
await call(env(), { name: 'Jamur surai singa' }, 'zt'); const bzt = JSON.stringify(geminiBody);
ok('target zt: glosarium 繁體 (猴頭菇) dan perintah memakai karakter Traditional', bzt.includes('猴頭菇') && bzt.includes('灌湯包') && bzt.includes('Traditional') && !bzt.includes('猴头菇'), bzt.slice(0, 200));
ok('target zt: nama bahasa Chinese (Traditional) dikirim ke model', bzt.includes('Chinese (Traditional)'));
await call(env(), { name: 'Jamur surai singa' }, 'zh'); const bzh = JSON.stringify(geminiBody);
ok('target zh: glosarium 简体 (猴头菇), tanpa glosarium Traditional', bzh.includes('猴头菇') && !bzh.includes('猴頭菇'));
const tz = await call(env(), { name: 'Tahu' }, 'zt'); ok('target zt diterima server (kode 2 huruf) dan tetap satu panggilan', tz.status === 200 && gemini.length === 1, JSON.stringify(tz));
globalThis.fetch = real;
console.log(`\nHasil: ${pass} lulus, ${fail} gagal`); process.exit(fail ? 1 : 0);
