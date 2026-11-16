import { createClient } from '@supabase/supabase-js';
import { AwsClient } from 'aws4fetch';
import { env } from '../../server/env';

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json' } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BYTES = 150 * 1024;

const R2_CONF = (e: any) => {
  const endpoint = env(e, 'R2_ENDPOINT'), bucket = env(e, 'R2_BUCKET'), id = env(e, 'R2_ACCESS_KEY_ID'), secret = env(e, 'R2_SECRET_ACCESS_KEY');
  return endpoint && bucket && id && secret ? { aws: new AwsClient({ accessKeyId: id, secretAccessKey: secret, service: 's3', region: 'auto' }), base: `${endpoint.replace(/\/$/, '')}/${bucket}` } : null;
};
const AVATAR_MAX = 60 * 1024, AVATAR_KEY = (uid: string) => new RegExp(`^restaurant/avatars/${uid}/[a-z0-9-]+\\.webp$`, 'i');
/** Foto profil: cukup login (tanpa restoran). Pengguna hanya boleh menulis/menghapus berkas di jalur miliknya sendiri. */
async function userGuard(request: Request, e: any) {
  const token = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const url = env(e, 'PUBLIC_SUPABASE_URL'), anon = env(e, 'PUBLIC_SUPABASE_ANON_KEY'), r2 = R2_CONF(e);
  if (!url || !anon || !r2) return { res: json({ error: 'Penyimpanan foto belum dikonfigurasi' }, 500) };
  if (!token) return { res: json({ error: 'Unauthorized' }, 401) };
  const sb = createClient(url, anon, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${token}` } } });
  const { data, error } = await sb.auth.getUser(token);
  if (error || !data?.user || !UUID.test(data.user.id)) return { res: json({ error: 'Unauthorized' }, 401) };
  return { uid: data.user.id.toLowerCase(), ...r2 };
}

/** Memastikan pemanggil login dan anggota restoran tersebut; mengembalikan klien R2 bila lolos. */
async function guard(request: Request, e: any, tenantId: string, kind: string) {
  const token = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const url = env(e, 'PUBLIC_SUPABASE_URL'), anon = env(e, 'PUBLIC_SUPABASE_ANON_KEY');
  const endpoint = env(e, 'R2_ENDPOINT'), bucket = env(e, 'R2_BUCKET'), id = env(e, 'R2_ACCESS_KEY_ID'), secret = env(e, 'R2_SECRET_ACCESS_KEY');
  if (!url || !anon || !endpoint || !bucket || !id || !secret) return { res: json({ error: 'Penyimpanan foto belum dikonfigurasi' }, 500) };
  if (!token) return { res: json({ error: 'Unauthorized' }, 401) };
  if (!UUID.test(tenantId)) return { res: json({ error: 'Bad request' }, 400) };
  const sb = createClient(url, anon, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${token}` } } });
  const { data, error } = await sb.auth.getUser(token);
  if (error || !data?.user) return { res: json({ error: 'Unauthorized' }, 401) };
  // foto menu: owner/manager; foto website (hero): hanya owner — diputuskan DATABASE
  const m = await sb.rpc(kind === 'site' ? 'can_edit_site' : 'can_edit_menu', { p_tenant: tenantId });
  if (m.error || m.data !== true) return { res: json({ error: 'Akses ditolak' }, 403) };
  const t = await sb.from('tenants').select('slug').eq('id', tenantId).maybeSingle();
  const slug = t.data?.slug; if (!slug || !/^[a-z0-9-]+$/.test(slug)) return { res: json({ error: 'Restoran tidak ditemukan' }, 404) };
  return { slug, aws: new AwsClient({ accessKeyId: id, secretAccessKey: secret, service: 's3', region: 'auto' }), base: `${endpoint.replace(/\/$/, '')}/${bucket}` };
}

// Unggah foto WebP: body = berkas WebP; header x-tenant-id, x-kind (menu | site | avatar), x-name (nama menu, untuk nama berkas).
// kind=avatar (foto profil): tanpa x-tenant-id; hanya perlu login; jalur restaurant/avatars/<id-pengguna>/<kode>.webp; maks 60 KB.
// Jalur di R2: restaurant/tenants/<slug-restoran>/<menu|site>/<nama>-<kode>.webp
export const onRequestPost = async ({ request, env: e }: any) => {
  const tenantId = request.headers.get('x-tenant-id') || '', kind = request.headers.get('x-kind') || 'menu';
  if (!['menu', 'site', 'avatar'].includes(kind)) return json({ error: 'Bad request' }, 400);
  const u = kind === 'avatar' ? await userGuard(request, e) : null; if (u?.res) return u.res;
  const g = u ? null : await guard(request, e, tenantId, kind); if (g?.res) return g.res;
  const buf = await request.arrayBuffer();
  const b = new Uint8Array(buf);
  const isWebp = b.length > 12 && String.fromCharCode(...b.slice(0, 4)) === 'RIFF' && String.fromCharCode(...b.slice(8, 12)) === 'WEBP';
  if (!isWebp) return json({ error: 'Berkas harus WebP' }, 415);
  if (u) {   // foto profil: restaurant/avatars/<id-pengguna>/<kode>.webp
    if (b.length > AVATAR_MAX) return json({ error: 'Foto terlalu besar (maks 60 KB)' }, 413);
    const akey = `restaurant/avatars/${u.uid}/${crypto.randomUUID().slice(0, 8)}.webp`;
    const aput = await u.aws.fetch(`${u.base}/${akey}`, { method: 'PUT', body: buf, headers: { 'content-type': 'image/webp', 'cache-control': 'public, max-age=31536000, immutable' } });
    return aput.ok ? json({ key: akey }) : json({ error: 'Gagal menyimpan foto' }, 502);
  }
  if (!g) return json({ error: 'Bad request' }, 400);
  if (b.length > MAX_BYTES) return json({ error: 'Foto terlalu besar (maks 150 KB)' }, 413);
  const name = (request.headers.get('x-name') || '').normalize('NFKD').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'foto';
  const key = `restaurant/tenants/${g.slug}/${kind}/${name}-${crypto.randomUUID().slice(0, 8)}.webp`;
  const put = await g.aws!.fetch(`${g.base}/${key}`, { method: 'PUT', body: buf, headers: { 'content-type': 'image/webp', 'cache-control': 'public, max-age=31536000, immutable' } });
  if (!put.ok) return json({ error: 'Gagal menyimpan foto' }, 502);
  return json({ key });
};

// Hapus foto: ?tenant_id=...&key=restaurant/tenants/<slug>/menu/<berkas>.webp (jalur lama tenants/<id>/... juga diterima)
export const onRequestDelete = async ({ request, env: e }: any) => {
  const url = new URL(request.url);
  const tenantId = url.searchParams.get('tenant_id') || '', key = url.searchParams.get('key') || '';
  if (url.searchParams.get('kind') === 'avatar') {   // hapus foto profil sendiri
    const u = await userGuard(request, e); if (u.res) return u.res;
    if (!AVATAR_KEY(u.uid).test(key)) return json({ error: 'Bad request' }, 400);
    const adel = await u.aws.fetch(`${u.base}/${key}`, { method: 'DELETE' });
    return adel.ok || adel.status === 404 ? json({ ok: true }) : json({ error: 'Gagal menghapus foto' }, 502);
  }
  const g = await guard(request, e, tenantId, key.includes('/site/') ? 'site' : 'menu'); if (g.res) return g.res;
  if (!new RegExp(`^(restaurant/tenants/${g.slug}|tenants/${tenantId})/(menu|site)/[a-z0-9-]+\\.webp$`, 'i').test(key)) return json({ error: 'Bad request' }, 400);
  const del = await g.aws!.fetch(`${g.base}/${key}`, { method: 'DELETE' });
  return del.ok || del.status === 404 ? json({ ok: true }) : json({ error: 'Gagal menghapus foto' }, 502);
};
