/**
 * MODUL OPSIONAL — domain kustom pelanggan lewat Cloudflare for SaaS (custom hostname PERSIS, bukan wildcard).
 * Nonaktif kecuali CF_SAAS_ENABLED=true. Tanpa modul ini, Dapora tetap berjalan penuh dengan <slug>.dapora.id.
 *
 * Env (Secret): CF_API_TOKEN (izin: SSL and Certificates:Edit pada zona dapora.id), SUPABASE_SERVICE_ROLE_KEY
 * Env (biasa) : CF_SAAS_ENABLED=true, CF_ZONE_ID, CF_CNAME_TARGET (mis. cname.dapora.id), CF_MAX_CUSTOM_DOMAINS (default 1)
 *
 * GET    /api/domains?tenant_id=…            daftar domain + status (menyegarkan status dari Cloudflare)
 * POST   /api/domains {tenant_id, hostname}  daftarkan domain; balasan berisi instruksi DNS
 * DELETE /api/domains?id=<tenant_domains.id> hapus
 * Semua memakai header Authorization: Bearer <access token Supabase> milik owner restoran (atau Super Admin).
 */
import { createClient } from '@supabase/supabase-js';

const J = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' } });
const HOST = /^(?=.{4,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;
const CF = 'https://api.cloudflare.com/client/v4';

async function cf(e: any, path: string, init: RequestInit = {}) {
  const r = await fetch(`${CF}/zones/${e.CF_ZONE_ID}${path}`, { ...init, headers: { authorization: `Bearer ${e.CF_API_TOKEN}`, 'content-type': 'application/json', ...(init.headers || {}) }, signal: AbortSignal.timeout(15000) });
  const b: any = await r.json().catch(() => ({}));
  return { ok: r.ok && b.success !== false, body: b, status: r.status };
}

async function auth(e: any, request: Request, tenantId: string) {
  const token = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token) return null;
  const user = createClient(e.PUBLIC_SUPABASE_URL, e.PUBLIC_SUPABASE_ANON_KEY, { global: { headers: { authorization: `Bearer ${token}` } }, auth: { persistSession: false } });
  const { data: u } = await user.auth.getUser(token);
  if (!u?.user) return null;
  const [m, p] = await Promise.all([
    user.from('tenant_members').select('role').eq('tenant_id', tenantId).eq('user_id', u.user.id).maybeSingle(),
    user.from('platform_admins').select('user_id').eq('user_id', u.user.id).maybeSingle(),
  ]);
  return m.data?.role === 'owner' || p.data ? u.user.id : null;
}

const instructions = (e: any, hostname: string, cfHost: any) => ({
  cname: { type: 'CNAME', name: hostname, value: e.CF_CNAME_TARGET },
  ownership_txt: cfHost?.ownership_verification ? { type: 'TXT', name: cfHost.ownership_verification.name, value: cfHost.ownership_verification.value } : null,
  ssl_txt: cfHost?.ssl?.validation_records ?? [],
  note: 'Domain apex (tanpa www) butuh penyedia DNS yang mendukung CNAME flattening; sarankan pelanggan memakai www.',
});

export const onRequest = async ({ request, env: e }: any) => {
  if (String(e.CF_SAAS_ENABLED || '') !== 'true') return J({ error: 'custom_domains_disabled' }, 404);
  if (!e.CF_API_TOKEN || !e.CF_ZONE_ID || !e.CF_CNAME_TARGET || !e.SUPABASE_SERVICE_ROLE_KEY) return J({ error: 'not_configured' }, 503);
  const admin = createClient(e.PUBLIC_SUPABASE_URL, e.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const url = new URL(request.url);

  if (request.method === 'GET') {
    const tenantId = url.searchParams.get('tenant_id') || '';
    if (!(await auth(e, request, tenantId))) return J({ error: 'forbidden' }, 403);
    const { data: rows } = await admin.from('tenant_domains').select('id,hostname,kind,is_primary,status,cf_hostname_id').eq('tenant_id', tenantId).order('created_at');
    const out = [];
    for (const d of rows ?? []) {
      if (d.kind === 'custom' && d.cf_hostname_id && d.status !== 'active') {        // segarkan status dari Cloudflare
        const r = await cf(e, `/custom_hostnames/${d.cf_hostname_id}`);
        if (r.ok) {
          const h = r.body.result, live = h.status === 'active' && h.ssl?.status === 'active';
          const status = live ? 'active' : ['blocked', 'deleted'].includes(h.status) || ['timed_out_validation', 'validation_timed_out'].includes(h.ssl?.status) ? 'error' : 'pending';
          if (status !== d.status) await admin.from('tenant_domains').update({ status, verified_at: live ? new Date().toISOString() : null }).eq('id', d.id);
          out.push({ ...d, status, instructions: status === 'active' ? null : instructions(e, d.hostname, h) });
          continue;
        }
      }
      out.push(d);
    }
    return J({ domains: out });
  }

  if (request.method === 'POST') {
    const b: any = await request.json().catch(() => ({}));
    const tenantId = String(b.tenant_id || ''), hostname = String(b.hostname || '').trim().toLowerCase().replace(/\.$/, '');
    if (!(await auth(e, request, tenantId))) return J({ error: 'forbidden' }, 403);
    if (!HOST.test(hostname)) return J({ error: 'invalid_hostname' }, 400);                 // wildcard/IP/karakter aneh ditolak
    const { count } = await admin.from('tenant_domains').select('id', { count: 'exact', head: true }).eq('tenant_id', tenantId).eq('kind', 'custom');
    if ((count ?? 0) >= Number(e.CF_MAX_CUSTOM_DOMAINS || 1)) return J({ error: 'limit_reached' }, 409);
    const ins = await admin.from('tenant_domains').insert({ tenant_id: tenantId, hostname, kind: 'custom', is_primary: false, status: 'pending' }).select('id').single();
    if (ins.error) return J({ error: ins.error.code === '23505' ? 'hostname_taken' : 'rejected', detail: ins.error.message }, 409);   // trigger menolak domain platform
    const r = await cf(e, '/custom_hostnames', { method: 'POST', body: JSON.stringify({ hostname, ssl: { method: 'http', type: 'dv', settings: { min_tls_version: '1.2' } } }) });
    if (!r.ok) { await admin.from('tenant_domains').delete().eq('id', ins.data.id); return J({ error: 'cloudflare_error', detail: r.body.errors?.[0]?.message }, 502); }
    await admin.from('tenant_domains').update({ cf_hostname_id: r.body.result.id }).eq('id', ins.data.id);
    return J({ id: ins.data.id, hostname, status: 'pending', instructions: instructions(e, hostname, r.body.result) }, 201);
  }

  if (request.method === 'DELETE') {
    const id = url.searchParams.get('id') || '';
    const { data: d } = await admin.from('tenant_domains').select('id,tenant_id,kind,cf_hostname_id').eq('id', id).maybeSingle();
    if (!d || d.kind !== 'custom' || !(await auth(e, request, d.tenant_id))) return J({ error: 'forbidden' }, 403);
    if (d.cf_hostname_id) await cf(e, `/custom_hostnames/${d.cf_hostname_id}`, { method: 'DELETE' });
    await admin.from('tenant_domains').delete().eq('id', id);
    return J({ ok: true });
  }
  return J({ error: 'method_not_allowed' }, 405);
};
