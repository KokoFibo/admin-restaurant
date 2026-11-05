import { createClient } from '@supabase/supabase-js';
import { AwsClient } from 'aws4fetch';
import { env } from '../../server/env';

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json' } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CONFIRM_ALL = 'HAPUS SEMUA';
// Hanya jalur yang dibuat /api/upload yang boleh disentuh, apa pun yang dikirim klien.
const PREFIX_OK = /^(restaurant\/tenants\/([a-z0-9-]+\/)?|tenants\/([0-9a-f-]{36}\/)?)$/i;
const KEY_OK = /^(restaurant\/tenants\/[a-z0-9-]+|tenants\/[0-9a-f-]{36})\/(menu|site)\/[a-z0-9-]+\.webp$/i;
const SINGLE_FALLBACK = 40;   // batas permintaan per panggilan Functions bila hapus massal ditolak R2

function r2(e: any) {
  const endpoint = env(e, 'R2_ENDPOINT'), bucket = env(e, 'R2_BUCKET'), id = env(e, 'R2_ACCESS_KEY_ID'), secret = env(e, 'R2_SECRET_ACCESS_KEY');
  if (!endpoint || !bucket || !id || !secret) return null;
  return { aws: new AwsClient({ accessKeyId: id, secretAccessKey: secret, service: 's3', region: 'auto', retries: 1 }), base: `${endpoint.replace(/\/$/, '')}/${bucket}` };
}
type R2 = NonNullable<ReturnType<typeof r2>>;

const unxml = (s: string) => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
async function list(c: R2, prefix: string, startAfter?: string) {
  const q = new URLSearchParams({ 'list-type': '2', prefix, 'max-keys': '1000' }); if (startAfter) q.set('start-after', startAfter);
  const r = await c.aws.fetch(`${c.base}?${q}`);
  if (!r.ok) throw new Error('Gagal membaca daftar foto (R2 ' + r.status + ')');
  const x = await r.text();
  return { keys: [...x.matchAll(/<Key>([^<]*)<\/Key>/g)].map(m => unxml(m[1])), more: /<IsTruncated>true<\/IsTruncated>/.test(x) };
}
async function deleteBatch(c: R2, keys: string[]): Promise<boolean> {
  const body = `<?xml version="1.0" encoding="UTF-8"?><Delete><Quiet>true</Quiet>${keys.map(k => `<Object><Key>${k}</Key></Object>`).join('')}</Delete>`;
  const headers: Record<string, string> = { 'content-type': 'application/xml' };
  try { const md5 = await (crypto.subtle as any).digest('MD5', new TextEncoder().encode(body)); headers['content-md5'] = btoa(String.fromCharCode(...new Uint8Array(md5))); } catch { /* S3 asli mewajibkan; R2 biasanya tidak */ }
  const r = await c.aws.fetch(`${c.base}?delete`, { method: 'POST', headers, body });
  return r.ok && !/<Error>/.test(await r.text());
}

/**
 * Hapus data tenant — KHUSUS Super Admin (dicek di database lewat is_platform_admin, bukan hanya di tampilan).
 *  - "preview" : yang akan terhapus (hitungan per restoran, akun, jumlah foto di R2). Tidak mengubah apa pun.
 *  - "delete"  : hapus DATABASE dalam satu transaksi (purge_tenants). Wajib mengirim teks konfirmasi yang benar:
 *                slug restoran (satu tenant) atau "HAPUS SEMUA" (semua tenant). Mengembalikan jalur foto yang harus dibersihkan.
 *  - "images"  : hapus foto di R2 per halaman (dipanggil berulang oleh tampilan sampai cursor kosong).
 */
export const onRequestPost = async ({ request, env: e }: any) => {
  try {
    const token = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    const url = env(e, 'PUBLIC_SUPABASE_URL'), anon = env(e, 'PUBLIC_SUPABASE_ANON_KEY'), service = env(e, 'SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !anon || !service) return json({ error: 'Server belum dikonfigurasi' }, 500);
    if (!token) return json({ error: 'Unauthorized' }, 401);
    const sb = createClient(url, anon, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${token}` } } });
    const { data, error } = await sb.auth.getUser(token);
    if (error || !data?.user) return json({ error: 'Unauthorized' }, 401);
    const isMaster = await sb.rpc('is_platform_admin');
    if (isMaster.error || isMaster.data !== true) return json({ error: 'Hanya Super Admin' }, 403);

    let b: any; try { b = await request.json(); } catch { return json({ error: 'Bad request' }, 400); }
    const action = String(b.action || '');
    const db = createClient(url, service, { auth: { persistSession: false } });

    if (action === 'images') {
      const prefix = String(b.prefix || ''), cursor = b.cursor ? String(b.cursor) : undefined;
      if (!PREFIX_OK.test(prefix) || (cursor && !cursor.startsWith(prefix))) return json({ error: 'Bad request' }, 400);
      const c = r2(e); if (!c) return json({ error: 'Penyimpanan foto belum dikonfigurasi' }, 500);
      const { keys, more } = await list(c, prefix, cursor);
      const todo = keys.filter(k => KEY_OK.test(k)), skipped = keys.length - todo.length;
      if (!todo.length) return json({ deleted: 0, skipped, failed: 0, cursor: more ? keys[keys.length - 1] : null });
      if (await deleteBatch(c, todo)) return json({ deleted: todo.length, skipped, failed: 0, cursor: more ? keys[keys.length - 1] : null });
      // R2 menolak hapus massal → satu per satu, dibatasi agar tidak melewati batas permintaan Functions
      const slice = todo.slice(0, SINGLE_FALLBACK); let deleted = 0, failed = 0;
      for (const k of slice) { const r = await c.aws.fetch(`${c.base}/${k}`, { method: 'DELETE' }); if (r.ok || r.status === 404) deleted++; else failed++; }
      const rest = todo.length > slice.length || more;
      return json({ deleted, skipped, failed, cursor: rest ? slice[slice.length - 1] : null });
    }

    if (action !== 'preview' && action !== 'delete') return json({ error: 'Bad request' }, 400);
    const scope = String(b.scope || '');
    if (scope !== 'tenant' && scope !== 'all') return json({ error: 'Bad request' }, 400);
    const tenantId = String(b.tenant_id || '');
    if (scope === 'tenant' && !UUID.test(tenantId)) return json({ error: 'Bad request' }, 400);
    const ids = scope === 'all' ? null : [tenantId];

    const pv = await db.rpc('purge_preview', { p_ids: ids, p_keep: data.user.id });
    if (pv.error) return json({ error: 'Gagal membaca data (sudah menjalankan 08-hapus-tenant.sql?)', detail: pv.error.message }, 502);
    const tenants: any[] = pv.data?.tenants || [];
    if (scope === 'tenant' && !tenants.length) return json({ error: 'Restoran tidak ditemukan' }, 404);
    const slug = tenants[0]?.slug as string | undefined;
    const prefixes = scope === 'all' ? ['restaurant/tenants/', 'tenants/'] : [`restaurant/tenants/${slug}/`, `tenants/${tenantId}/`];

    if (action === 'preview') {
      let images: { configured: boolean; count?: number; more?: boolean } = { configured: false };
      const c = r2(e);
      if (c) {
        try {
          let count = 0, more = false;
          for (const p of prefixes) { const l = await list(c, p); count += l.keys.filter(k => KEY_OK.test(k)).length; more = more || l.more; }
          images = { configured: true, count, more };
        } catch { images = { configured: true }; }
      }
      return json({ tenants, users: pv.data?.users || [], images, confirm: scope === 'all' ? CONFIRM_ALL : slug, prefixes });
    }

    // ---- delete ----
    const typed = String(b.confirm || '').trim();
    if (typed !== (scope === 'all' ? CONFIRM_ALL : slug)) return json({ error: 'Teks konfirmasi tidak cocok' }, 400);
    const del = await db.rpc('purge_tenants', { p_ids: ids, p_delete_users: b.delete_users === true, p_keep: data.user.id });
    if (del.error) return json({ error: 'Gagal menghapus (tidak ada yang berubah)', detail: del.error.message }, 502);
    return json({ ok: true, result: del.data, prefixes });
  } catch (err: any) {
    return json({ error: 'Gagal', detail: String(err?.message || err).slice(0, 200) }, 502);
  }
};
