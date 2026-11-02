// Memindahkan gambar bawaan (folder public/images di frontend) ke Cloudflare R2. TIDAK menghapus apa pun
// (berkas lokal dan objek R2 tidak disentuh); berkas yang sudah ada di R2 dilewati kecuali memakai --force.
//
// Dua tujuan di R2:
//   1) restaurant/defaults/<slug>/<berkas>.webp         ← SEMUA gambar (default template; tidak bisa dihapus lewat admin)
//   2) restaurant/tenants/<slug>/menu/<berkas>.webp     ← hanya foto HIDANGAN (data restoran; dipakai menu_items.image_key)
// Gambar non-hidangan (mis. foto koki) ditandai lewat --brand (bawaan: koki-gu.webp) dan hanya masuk ke (1).
// Satu objek tidak pernah dipakai bersama: foto menu dan gambar default adalah salinan terpisah.
//
// Pakai:  node --env-file=.env scripts/upload-images.mjs <slug-restoran> <id-restoran-uuid> [folder-gambar] [--dry] [--force] [--brand=a.webp,b.webp]
//   --dry    : hanya menampilkan rencana (tanpa jaringan, tanpa kunci R2)
//   --force  : timpa objek yang sudah ada di R2
// Mencetak SQL pembaruan menu_items.image_key ('/images/<berkas>' → kunci R2) untuk dijalankan di Supabase SQL Editor.
import { AwsClient } from 'aws4fetch';
import { readdirSync, readFileSync } from 'node:fs';

const flags = process.argv.slice(2).filter(a => a.startsWith('--')), args = process.argv.slice(2).filter(a => !a.startsWith('--'));
const [slug, tenant] = args, DIR = args[2] || '../aisin-frontend/public/images';
const DRY = flags.includes('--dry'), FORCE = flags.includes('--force');
const BRAND = new Set((flags.find(f => f.startsWith('--brand='))?.slice(8) || 'koki-gu.webp').split(',').map(s => s.trim()).filter(Boolean));
const { R2_ENDPOINT, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, PUBLIC_MEDIA_URL } = process.env;
if (!/^[a-z0-9-]+$/.test(slug || '') || !/^[0-9a-f-]{36}$/i.test(tenant || '')) { console.error('Beri slug restoran (mis. aisin) dan id restoran (uuid dari tabel tenants).'); process.exit(1); }
if (!DRY && (!R2_ENDPOINT || !R2_BUCKET || !R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY)) { console.error('Isi R2_ENDPOINT, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY di .env (atau pakai --dry).'); process.exit(1); }

const files = readdirSync(DIR).filter(f => f.toLowerCase().endsWith('.webp')).sort();
if (!files.length) { console.error('Tidak ada .webp di', DIR); process.exit(1); }
const isWebp = b => b.length > 12 && b.toString('ascii', 0, 4) === 'RIFF' && b.toString('ascii', 8, 12) === 'WEBP';
const aws = DRY ? null : new AwsClient({ accessKeyId: R2_ACCESS_KEY_ID, secretAccessKey: R2_SECRET_ACCESS_KEY, service: 's3', region: 'auto' });
const base = DRY ? '' : `${R2_ENDPOINT.replace(/\/$/, '')}/${R2_BUCKET}`;
const sql = []; let ok = 0, skipped = 0, failed = 0;

async function put(key, buf) {
  if (DRY) { console.error('RENCANA', key, `(${Math.round(buf.length / 1024)} KB)`); return true; }
  if (!FORCE) { const h = await aws.fetch(`${base}/${key}`, { method: 'HEAD' }); if (h.ok) { console.error('ADA   ', key, '(dilewati)'); skipped++; return true; } }
  const r = await aws.fetch(`${base}/${key}`, { method: 'PUT', body: buf, headers: { 'content-type': 'image/webp', 'cache-control': 'public, max-age=31536000, immutable' } });
  console.error(r.ok ? 'OK    ' : 'GAGAL ', key, r.status); r.ok ? ok++ : failed++; return r.ok;
}
for (const f of files) {
  const buf = readFileSync(`${DIR}/${f}`);
  if (!isWebp(buf)) { console.error('BUKAN WEBP, dilewati:', f); failed++; continue; }
  await put(`restaurant/defaults/${slug}/${f}`, buf);
  if (BRAND.has(f)) continue;
  const key = `restaurant/tenants/${slug}/menu/${f}`;
  if (await put(key, buf)) sql.push(`update public.menu_items set image_key = '${key}' where tenant_id = '${tenant}' and image_key = '/images/${f}';`);
}
console.error(`\nSelesai${DRY ? ' (rencana, tidak ada yang diunggah)' : ''}: ${ok} diunggah, ${skipped} dilewati, ${failed} gagal. Berkas lokal di ${DIR} tidak diubah.`);
if (PUBLIC_MEDIA_URL) console.error('Contoh URL default:', `${PUBLIC_MEDIA_URL.replace(/\/$/, '')}/restaurant/defaults/${slug}/${files[0]}`);
console.log('-- Jalankan di Supabase SQL Editor (hanya foto hidangan):\n' + (sql.join('\n') || '-- (tidak ada)'));
process.exit(failed ? 2 : 0);
