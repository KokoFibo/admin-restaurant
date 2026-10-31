// Memindahkan foto bawaan (public/images/*.webp) ke Cloudflare R2 untuk satu restoran, lalu mencetak SQL pembaruan image_key.
// Jalur R2: restaurant/tenants/<slug-restoran>/menu/<berkas>.webp
// Pakai:  node --env-file=.env scripts/upload-images.mjs <slug-restoran> <id-restoran-uuid> [folder-gambar]
import { AwsClient } from 'aws4fetch';
import { readdirSync, readFileSync } from 'node:fs';
const [slug, tenant] = [process.argv[2], process.argv[3]];
const DIR = process.argv[4] || '../aisin-frontend/public/images'; // folder foto di proyek frontend
const { R2_ENDPOINT, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY } = process.env;
if (!/^[a-z0-9-]+$/.test(slug || '') || !/^[0-9a-f-]{36}$/i.test(tenant || '') || !R2_ENDPOINT || !R2_BUCKET || !R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY) {
  console.error('Isi R2_* di .env, lalu beri slug restoran (mis. aisin) dan id restoran (uuid dari tabel tenants).'); process.exit(1);
}
const aws = new AwsClient({ accessKeyId: R2_ACCESS_KEY_ID, secretAccessKey: R2_SECRET_ACCESS_KEY, service: 's3', region: 'auto' });
const sql = [];
for (const f of readdirSync(DIR).filter(f => f.endsWith('.webp'))) {
  const key = `restaurant/tenants/${slug}/menu/${f}`;
  const r = await aws.fetch(`${R2_ENDPOINT.replace(/\/$/, '')}/${R2_BUCKET}/${key}`, { method: 'PUT', body: readFileSync(`${DIR}/${f}`), headers: { 'content-type': 'image/webp', 'cache-control': 'public, max-age=31536000, immutable' } });
  console.error(r.ok ? 'OK  ' : 'GAGAL', key, r.status);
  if (r.ok) sql.push(`update public.menu_items set image_key = '${key}' where tenant_id = '${tenant}' and image_key = '/images/${f}';`);
}
console.log('-- Jalankan di Supabase SQL Editor:\n' + sql.join('\n'));
