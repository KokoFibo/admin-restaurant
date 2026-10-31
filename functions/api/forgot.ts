import { createClient } from '@supabase/supabase-js';
import { env } from '../../server/env';

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json' } });
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

/**
 * "Lupa kata sandi" — HANYA untuk Owner (dan Super Admin). Email lain tidak dikirimi apa pun,
 * tetapi jawabannya selalu sama supaya orang luar tidak bisa menebak email yang terdaftar.
 * Tautan di email membuka admin ini lagi (halaman buat kata sandi baru). Wajib: SMTP di Supabase + URL admin terdaftar di Redirect URLs.
 */
export const onRequestPost = async ({ request, env: e }: any) => {
  const url = env(e, 'PUBLIC_SUPABASE_URL'), anon = env(e, 'PUBLIC_SUPABASE_ANON_KEY'), service = env(e, 'SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !anon || !service) return json({ error: 'Server belum dikonfigurasi' }, 500);
  let email = ''; try { email = String((await request.json()).email || '').trim().toLowerCase(); } catch { /* kosong */ }
  if (!EMAIL.test(email)) return json({ error: 'Bad request' }, 400);
  const db = createClient(url, service, { auth: { persistSession: false } });
  const ok = await db.rpc('can_self_reset', { p_email: email });
  if (ok.data === true) {
    const pub = createClient(url, anon, { auth: { persistSession: false } });
    await pub.auth.resetPasswordForEmail(email, { redirectTo: new URL(request.url).origin + '/' }).catch(() => {});
  }
  return json({ ok: true });
};
