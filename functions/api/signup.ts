import { createClient } from '@supabase/supabase-js';
import { env } from '../../server/env';

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/, SLUG = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const TYPES = ['vegan', 'vegetarian', 'umum'], LANGS = ['id', 'en', 'zh'];

/**
 * Pendaftaran mandiri restoran baru. Publik (tanpa login), dipanggil dari website pemasaran (lintas-origin, lihat CORS di bawah).
 *
 * GET  /api/signup?slug=<alamat>   → { available: boolean }   (cek ketersediaan alamat untuk formulir)
 * POST /api/signup  { email, password, brand, slug, template, type, lang, cf_token? }
 *      alur: validasi → (Turnstile) → buat akun → create_tenant() (restoran + owner + trial + <slug>.<domain-dasar>) → balasan.
 *      Bila create_tenant gagal, akun yang baru dibuat dihapus lagi (tidak ada akun yatim).
 *
 * Env: PUBLIC_SUPABASE_URL, PUBLIC_SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY (Secret), PUBLIC_BASE_DOMAIN,
 *      SIGNUP_ENABLED=true (wajib; bawaan mati), SIGNUP_ALLOWED_ORIGINS (daftar origin website pemasaran, pisahkan koma;
 *      bawaan https://<PUBLIC_BASE_DOMAIN>), SIGNUP_AUTO_CONFIRM=true (lewati email konfirmasi; bawaan: kirim email konfirmasi),
 *      SIGNUP_PLAN (bawaan basic), TURNSTILE_SECRET (opsional tapi sangat disarankan; jika ada, token wajib).
 */

/** CORS: hanya origin yang terdaftar (atau origin admin sendiri) yang boleh memanggil dari browser. */
function corsHeaders(request: Request, e: any): Record<string, string> {
  const origin = request.headers.get('origin');
  if (!origin) return {};
  const base = (env(e, 'PUBLIC_BASE_DOMAIN') || '').replace(/^\./, '');
  const allowed = (env(e, 'SIGNUP_ALLOWED_ORIGINS') || (base ? `https://${base}` : '')).split(',').map(s => s.trim().replace(/\/+$/, '')).filter(Boolean);
  if (!allowed.includes(origin) && origin !== new URL(request.url).origin) return {};
  return { 'access-control-allow-origin': origin, 'access-control-allow-methods': 'GET, POST, OPTIONS', 'access-control-allow-headers': 'content-type', 'access-control-max-age': '86400', vary: 'Origin' };
}
const reply = (request: Request, e: any, o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store', ...corsHeaders(request, e) } });

/** Verifikasi token Turnstile. `reason` memudahkan diagnosis (mis. invalid-input-secret, invalid-input-response, timeout-or-duplicate, missing_token). */
async function turnstileCheck(secret: string, token: string, ip: string | null): Promise<{ ok: boolean; reason?: string }> {
  if (!token) { console.error('turnstile: token kosong (website tidak mengirim cf_token; VITE_TURNSTILE_SITEKEY belum terpasang di build?)'); return { ok: false, reason: 'missing_token' }; }
  const body = new URLSearchParams({ secret, response: token }); if (ip) body.set('remoteip', ip);
  const r = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', { method: 'POST', body, signal: AbortSignal.timeout(8000) }).catch(() => null);
  if (!r) { console.error('turnstile: siteverify tidak terjangkau'); return { ok: false, reason: 'unreachable' }; }
  const j: any = await r.json().catch(() => ({}));
  if (j.success === true) return { ok: true };
  const codes: string[] = Array.isArray(j['error-codes']) ? j['error-codes'] : [];
  console.error('turnstile ditolak:', codes.join(',') || 'tanpa kode', '| hostname:', j.hostname || '-');
  return { ok: false, reason: codes[0] || 'verify_failed' };
}

export const onRequestOptions = ({ request, env: e }: any) => new Response(null, { status: 204, headers: corsHeaders(request, e) });

export const onRequestGet = async ({ request, env: e }: any) => {
  if (env(e, 'SIGNUP_ENABLED') !== 'true') return reply(request, e, { error: 'signup_disabled' }, 403);
  const url = env(e, 'PUBLIC_SUPABASE_URL'), service = env(e, 'SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !service) return reply(request, e, { error: 'not_configured' }, 500);
  const slug = (new URL(request.url).searchParams.get('slug') || '').trim().toLowerCase();
  if (!SLUG.test(slug) || slug.length < 3 || slug.length > 40) return reply(request, e, { available: false, reason: 'invalid' });
  const r = await createClient(url, service, { auth: { persistSession: false } }).rpc('slug_available', { p_slug: slug });
  if (r.error) { console.error('slug_available', r.error.message); return reply(request, e, { error: 'upstream' }, 502); }
  return reply(request, e, { available: r.data === true });
};

export const onRequestPost = async ({ request, env: e }: any) => {
  const json = (o: unknown, s = 200) => reply(request, e, o, s);
  if (env(e, 'SIGNUP_ENABLED') !== 'true') return json({ error: 'signup_disabled' }, 403);
  const url = env(e, 'PUBLIC_SUPABASE_URL'), anon = env(e, 'PUBLIC_SUPABASE_ANON_KEY'), service = env(e, 'SUPABASE_SERVICE_ROLE_KEY'), base = (env(e, 'PUBLIC_BASE_DOMAIN') || '').replace(/^\./, '');
  if (!url || !anon || !service || !base) return json({ error: 'not_configured' }, 500);

  let b: any = {}; try { b = await request.json(); } catch { return json({ error: 'bad_request' }, 400); }
  const email = String(b.email || '').trim().toLowerCase(), password = String(b.password || ''), brand = String(b.brand || '').trim().replace(/\s+/g, ' ');
  const slug = String(b.slug || '').trim().toLowerCase(), template = String(b.template || 'aisin'), type = String(b.type || 'umum'), lang = String(b.lang || 'id');
  if (!EMAIL.test(email) || email.length > 254) return json({ error: 'invalid_email' }, 400);
  if (password.length < 8 || password.length > 72) return json({ error: 'invalid_password' }, 400);
  if (brand.length < 2 || brand.length > 80) return json({ error: 'invalid_brand' }, 400);
  if (!SLUG.test(slug) || slug.length < 3 || slug.length > 40) return json({ error: 'invalid_slug' }, 400);
  if (!TYPES.includes(type) || !LANGS.includes(lang) || !/^[a-z0-9-]{1,40}$/.test(template)) return json({ error: 'bad_request' }, 400);

  const secret = env(e, 'TURNSTILE_SECRET');
  if (secret) {
    const c = await turnstileCheck(secret, String(b.cf_token || ''), request.headers.get('cf-connecting-ip'));
    if (!c.ok) return json({ error: 'captcha_failed', reason: c.reason }, 400);
  }

  const admin = createClient(url, service, { auth: { persistSession: false } });
  const free = await admin.rpc('slug_available', { p_slug: slug });
  if (free.error) { console.error('slug_available', free.error.message); return json({ error: 'upstream' }, 502); }
  if (free.data !== true) return json({ error: 'slug_taken' }, 409);

  const adminLang = lang === 'en' ? 'en' : 'id', auto = env(e, 'SIGNUP_AUTO_CONFIRM') === 'true';
  let uid = '';
  if (auto) {
    const r = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { admin_lang: adminLang } });
    if (r.error) return json({ error: (r.error as any).code === 'email_exists' || /already|registered/i.test(r.error.message) ? 'email_taken' : 'auth_failed' }, (r.error as any).status === 422 ? 409 : 400);
    uid = r.data.user.id;
  } else {
    const pub = createClient(url, anon, { auth: { persistSession: false } });
    const r = await pub.auth.signUp({ email, password, options: { emailRedirectTo: new URL(request.url).origin + '/', data: { admin_lang: adminLang } } });
    if (r.error) return json({ error: (r.error as any).code === 'over_email_send_rate_limit' || r.error.status === 429 ? 'rate_limited' : 'auth_failed' }, r.error.status === 429 ? 429 : 400);
    if (!r.data.user || (r.data.user.identities ?? []).length === 0) return json({ error: 'email_taken' }, 409);   // email sudah terdaftar (Supabase menyamarkan)
    uid = r.data.user.id;
  }

  const t = await admin.rpc('create_tenant', { p_owner: uid, p_slug: slug, p_brand: brand, p_template: template, p_type: type, p_lang: lang, p_plan: env(e, 'SIGNUP_PLAN') || 'basic' });
  if (t.error) {
    await admin.auth.admin.deleteUser(uid).catch(() => {});                                             // jangan tinggalkan akun tanpa restoran
    const m = t.error.message || '';
    const code = t.error.code === '23505' ? 'slug_taken' : /dicadangkan|3–40|check/i.test(m) || t.error.code === '23514' ? 'invalid_slug' : /Template/i.test(m) ? 'invalid_template' : 'create_failed';
    if (code === 'create_failed') console.error('create_tenant', t.error.code, m);
    return json({ error: code }, code === 'create_failed' ? 500 : 409);
  }
  return json({ ok: true, slug, needs_confirmation: !auto, site_url: `https://${slug}.${base}` }, 201);
};
export const onRequest = ({ request, env: e }: any) => reply(request, e, { error: 'method_not_allowed' }, 405);
