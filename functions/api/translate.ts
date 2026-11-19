import { createClient } from '@supabase/supabase-js';
import { env } from '../../server/env';

// Terjemahan memakai SATU model saja: gemini-3.1-flash-lite (stabil/GA di Gemini API). Tidak ada pemilihan otomatis dan tidak ada model cadangan.
// AI_MODEL (opsional, di pengaturan Cloudflare) menggantinya; bila diisi, nilai itulah yang dipakai. Kosongkan/hapus variabel itu agar kembali ke model di bawah.
const MODEL = 'gemini-3.1-flash-lite';

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json' } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const LANG = /^[a-z]{2}$/;
const GLOSSARY_ZH = 'Glosarium: matsutake=松茸, morel=羊肚菌, jamur surai singa=猴头菇, jamur kuping hitam=黑木耳, kulit tahu=腐竹, truffle hitam=黑松露, pu-erh=普洱, teh putih=白茶, goji=枸杞, dim sum=点心, pangsit kuah=灌汤包.';

export const onRequestPost = async ({ request, env: e }: any) => {
  const token = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const url = env(e, 'PUBLIC_SUPABASE_URL'), anon = env(e, 'PUBLIC_SUPABASE_ANON_KEY'), apiKey = env(e, 'GEMINI_API_KEY');
  if (!url || !anon || !apiKey) return json({ error: 'Server belum dikonfigurasi' }, 500);
  if (!token) return json({ error: 'Unauthorized' }, 401);

  // 1) pengguna harus login; semua panggilan database memakai identitas pengguna itu
  const sb = createClient(url, anon, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${token}` } } });
  const { data, error } = await sb.auth.getUser(token);
  if (error || !data?.user) return json({ error: 'Unauthorized' }, 401);

  // 2) validasi input
  let tenantId = '', source = '', target = '', fields: Record<string, string> = {};
  try { const b = await request.json(); tenantId = String(b.tenant_id || ''); source = String(b.source || ''); target = String(b.target || ''); fields = b.fields ?? {}; }
  catch { return json({ error: 'Bad request' }, 400); }
  if (!UUID.test(tenantId) || !LANG.test(source) || !LANG.test(target) || source === target) return json({ error: 'Bad request' }, 400);
  const keys = Object.keys(fields).filter(k => typeof fields[k] === 'string' && fields[k].trim());
  if (!keys.length || keys.length > 8) return json({ error: 'Bad request' }, 400);
  const texts: Record<string, string> = {};
  for (const k of keys) texts[k] = fields[k].trim().slice(0, 1000);

  // 3) kedua bahasa harus aktif di restoran ini (mencegah kuota terpakai untuk hal lain)
  const [tl, lg, tn] = await Promise.all([
    sb.from('tenant_languages').select('lang').eq('tenant_id', tenantId),
    sb.from('languages').select('code,name_english,max_name,max_short,max_detail'),
    sb.from('tenants').select('restaurant_type').eq('id', tenantId).maybeSingle(),
  ]);
  const active = new Set((tl.data ?? []).map((r: any) => r.lang));
  if (!active.has(source) || !active.has(target) || !tn.data) return json({ error: 'Akses ditolak' }, 403);
  const L = new Map((lg.data ?? []).map((r: any) => [r.code, r]));
  const tgt: any = L.get(target), src: any = L.get(source);
  const limits: Record<string, number> = { name: tgt.max_name, short: tgt.max_short, detail: tgt.max_detail, badge: 40, category: 60, brand: 80, tagline: 160,
    eyebrow: 60, title: 120, title_em: 120, lead: 400, chip1: 40, chip2: 40, chip3: 40, cta_order: 30, cta_menu: 30, message: 140, label: 30 };   // hero & banner

  // 4) hanya anggota restoran dengan langganan aktif dan kuota bulan ini yang boleh melanjutkan
  const ok = await sb.rpc('consume_ai', { p_tenant: tenantId });
  if (ok.error || ok.data !== true) return json({ error: 'Kuota habis atau akses ditolak' }, 429);

  // 5) terjemahkan dengan Gemini (kunci dari Google AI Studio; tier gratis punya batas per menit/hari).
  //    Satu model tetap (MODEL); kegagalan dilaporkan apa adanya, tanpa mencoba model lain.
  const system = `You translate restaurant menu texts from ${src.name_english} to ${tgt.name_english} for a ${tn.data.restaurant_type} restaurant website. ` +
    `Write natural, appetising, concise menu language. Keep ingredient and cooking-technique names accurate; do not add claims that are not in the source. ` +
    `Each key has a maximum length in characters (see "limits"); never exceed it. ${target === 'zh' ? GLOSSARY_ZH : ''} ` +
    `Reply ONLY with a JSON object with exactly the same keys as "texts", values being the translations.`;
  const base = env(e, 'AI_BASE_URL') || 'https://generativelanguage.googleapis.com/v1beta';
  const body = JSON.stringify({
    systemInstruction: { parts: [{ text: system }] },
    contents: [{ role: 'user', parts: [{ text: JSON.stringify({ limits: Object.fromEntries(keys.map(k => [k, limits[k] ?? 300])), texts }) }] }],
    generationConfig: { responseMimeType: 'application/json', temperature: 0.2, maxOutputTokens: 4096 },
  });
  const model = (env(e, 'AI_MODEL') || '').trim() || MODEL;   // variabel kosong/hanya spasi dianggap tidak diisi
  let res: Response;
  try { res = await fetch(`${base}/models/${encodeURIComponent(model)}:generateContent`, { method: 'POST', headers: { 'content-type': 'application/json', 'x-goog-api-key': apiKey }, body }); }
  catch { return json({ error: 'Layanan terjemahan gagal', detail: 'Layanan Google tidak terjangkau' }, 502); }
  if (res.status === 429) return json({ error: 'Batas pemakaian AI penuh, coba lagi sebentar lagi' }, 503);
  if (!res.ok) {
    const msg = (await res.json().catch(() => ({})))?.error?.message || res.status;
    return json({ error: 'Layanan terjemahan gagal', detail: `${model}: ${msg}`.slice(0, 300) }, 502);   // mis. model tidak tersedia untuk kunci ini
  }
  try {
    const parts = (await res.json()).candidates?.[0]?.content?.parts ?? [];
    const text = parts.filter((p: any) => !p.thought).map((p: any) => p.text || '').join('').replace(/^```(?:json)?|```$/gm, '').trim();
    const out = JSON.parse(text);
    const clean: Record<string, string> = {}, over: string[] = [];
    for (const k of keys) if (typeof out[k] === 'string') { clean[k] = out[k].trim(); if ([...clean[k]].length > (limits[k] ?? 300)) over.push(k); }
    if (!Object.keys(clean).length) throw new Error('kosong');
    return json({ fields: clean, over });
  } catch { return json({ error: 'Format terjemahan tidak valid' }, 502); }
};
