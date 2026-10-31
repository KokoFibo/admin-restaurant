import { createClient } from '@supabase/supabase-js';
import { env } from '../../server/env';

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json' } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const ROLES = ['owner', 'manager', 'cashier', 'kitchen', 'service'];

/**
 * Pengelolaan akun (butuh kunci service_role, hanya ada di server). Siapa boleh apa diputuskan DATABASE:
 *  - "create"     : can_create_role   → Super Admin: semua role | Owner: Manager, Cashier, Kitchen, Service
 *  - "password"   : can_manage_account → Super Admin: semua | Owner: staf restorannya
 *  - "deactivate" / "activate" : sama (tidak bisa login & akses data langsung tertutup / dibuka lagi)
 *  - "impact"     : restoran apa saja yang terdampak bila akun owner dihapus
 *  - "delete"     : hapus permanen (riwayat pesanan tetap); ditolak bila dia satu-satunya owner aktif sebuah restoran
 */
export const onRequestPost = async ({ request, env: e }: any) => {
  const token = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const url = env(e, 'PUBLIC_SUPABASE_URL'), anon = env(e, 'PUBLIC_SUPABASE_ANON_KEY'), service = env(e, 'SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !anon || !service) return json({ error: 'Server belum dikonfigurasi' }, 500);
  if (!token) return json({ error: 'Unauthorized' }, 401);
  const sb = createClient(url, anon, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${token}` } } });
  const { data, error } = await sb.auth.getUser(token);
  if (error || !data?.user) return json({ error: 'Unauthorized' }, 401);
  const db = createClient(url, service, { auth: { persistSession: false } });

  let b: any; try { b = await request.json(); } catch { return json({ error: 'Bad request' }, 400); }
  const tenantId = String(b.tenant_id || ''), action = String(b.action || '');
  if (!UUID.test(tenantId)) return json({ error: 'Bad request' }, 400);
  // Kunci lama (JWT "eyJ…") dikirim di apikey + Authorization; kunci baru "sb_secret_…" hanya di apikey.
  const svc: Record<string, string> = service.startsWith('eyJ') ? { apikey: service, Authorization: `Bearer ${service}` } : { apikey: service };
  const base = url.replace(/\/$/, '');
  const admin = (path: string, method: string, body?: unknown) => fetch(`${base}/auth/v1/admin/${path}`, { method, headers: { 'content-type': 'application/json', ...svc }, body: body ? JSON.stringify(body) : undefined });
  const why = async (r: Response) => { const j: any = await r.json().catch(() => ({})); return String(j.msg || j.message || j.error_description || j.error || r.status).slice(0, 200); };

  if (action === 'create') {
    const email = String(b.email || '').trim().toLowerCase(), role = String(b.role || ''), password = String(b.password || '');
    if (!EMAIL.test(email) || !ROLES.includes(role)) return json({ error: 'Bad request' }, 400);
    if (password.length < 8 || password.length > 72) return json({ error: 'Kata sandi harus 8–72 karakter' }, 400);
    const allowed = await sb.rpc('can_create_role', { p_tenant: tenantId, p_role: role });
    if (allowed.error || allowed.data !== true) return json({ error: 'Anda tidak berhak membuat akun dengan role ini' }, 403);
    const r = await admin('users', 'POST', { email, password, email_confirm: true });
    if (!r.ok) {
      const j: any = await r.clone().json().catch(() => ({}));
      if (j?.error_code === 'email_exists' || r.status === 422) return json({ error: 'Email sudah terdaftar. Hubungi Super Admin untuk menautkan akun yang sudah ada.' }, 409);
      return json({ error: 'Gagal membuat akun', detail: await why(r) }, 502);
    }
    const created: any = await r.json();
    const link = await db.from('tenant_members').insert({ tenant_id: tenantId, user_id: created.id, role });
    if (link.error) { await admin(`users/${created.id}`, 'DELETE').catch(() => {}); return json({ error: 'Akun dibuat tetapi gagal ditautkan, dibatalkan', detail: link.error.message }, 502); }
    return json({ ok: true, user_id: created.id });
  }

  const target = String(b.user_id || ''); if (!UUID.test(target)) return json({ error: 'Bad request' }, 400);
  const okMgr = await sb.rpc('can_manage_account', { p_tenant: tenantId, p_target: target });
  if (okMgr.error || okMgr.data !== true) return json({ error: 'Anda tidak berhak mengelola akun ini' }, 403);

  if (action === 'password') {
    const password = String(b.password || ''); if (password.length < 8 || password.length > 72) return json({ error: 'Kata sandi harus 8–72 karakter' }, 400);
    const r = await admin(`users/${target}`, 'PUT', { password });
    return r.ok ? json({ ok: true }) : json({ error: 'Gagal mengubah kata sandi', detail: await why(r) }, 502);
  }
  if (action === 'deactivate' || action === 'activate') {
    const on = action === 'activate';
    const u = await db.from('tenant_members').update({ is_active: on }).eq('user_id', target); if (u.error) return json({ error: 'Gagal mengubah status', detail: u.error.message }, 502);
    const r = await admin(`users/${target}`, 'PUT', { ban_duration: on ? 'none' : '876000h' });   // 100 tahun = tidak bisa login/refresh sesi
    return r.ok ? json({ ok: true }) : json({ error: 'Gagal mengubah status', detail: await why(r) }, 502);
  }
  if (action === 'impact' || action === 'delete') {
    const imp = await db.rpc('owner_impact', { p_user: target }); if (imp.error) return json({ error: 'Gagal memeriksa dampak', detail: imp.error.message }, 502);
    const restaurants = (imp.data || []).map((x: any) => x.slug), sole = (imp.data || []).filter((x: any) => x.sole).map((x: any) => x.slug);
    if (action === 'impact') return json({ restaurants, sole });
    if (sole.length) return json({ error: 'Akun ini owner aktif satu-satunya', sole }, 409);
    const r = await admin(`users/${target}`, 'DELETE');
    return r.ok ? json({ ok: true }) : json({ error: 'Gagal menghapus akun', detail: await why(r) }, 502);
  }
  return json({ error: 'Bad request' }, 400);
};
