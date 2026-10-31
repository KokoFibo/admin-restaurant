import { authHeader } from './supabase';
import { t } from './i18n';
import { slug } from './image';
import { S } from '../store';

/** Unggah WebP ke R2 lewat /api/upload (Functions di subdomain admin yang sama). */
export async function uploadImage(blob: Blob, name: string, kind: 'menu' | 'site' = 'menu'): Promise<string> {
  const r = await fetch('/api/upload', { method: 'POST', headers: { ...(await authHeader()), 'x-tenant-id': S.tid, 'x-kind': kind, 'x-name': slug(name) || 'foto', 'content-type': 'image/webp' }, body: blob });
  if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || t('Gagal mengunggah foto'));
  return (await r.json()).key;
}
export async function deleteImage(key?: string) {
  if (!key || !(key.startsWith('restaurant/tenants/') || key.startsWith('tenants/'))) return;
  await fetch(`/api/upload?tenant_id=${S.tid}&key=${encodeURIComponent(key)}`, { method: 'DELETE', headers: await authHeader() }).catch(() => {});
}
export async function translate(source: string, target: string, fields: Record<string, string>): Promise<{ fields: Record<string, string>; over: string[] }> {
  const r = await fetch('/api/translate', { method: 'POST', headers: { 'content-type': 'application/json', ...(await authHeader()) }, body: JSON.stringify({ tenant_id: S.tid, source, target, fields }) });
  if (!r.ok) { const e: any = new Error(String(r.status)); e.detail = (await r.json().catch(() => ({}))).detail; throw e; }
  return r.json();
}
export const trErr = (e: any) => e?.message === '429' ? t('Kuota terjemahan AI bulan ini habis atau langganan tidak aktif. Isi terjemahan secara manual.')
  : e?.message === '503' ? t('Layanan terjemahan AI sedang penuh. Coba lagi beberapa menit lagi, atau isi terjemahan secara manual.')
  : t('Terjemahan otomatis gagal.') + (e?.detail ? ` (${e.detail})` : '');
export async function usersApi(body: any): Promise<any> {
  const r = await fetch('/api/users', { method: 'POST', headers: { 'content-type': 'application/json', ...(await authHeader()) }, body: JSON.stringify(body) });
  if (!r.ok) { const j = await r.json().catch(() => ({})); throw new Error((j.error || t('Gagal membuat akun')) + (j.detail ? ` (${j.detail})` : '')); }
  return r.json().catch(() => ({}));
}
export async function forgotApi(email: string): Promise<void> {
  await fetch('/api/forgot', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email }) });
}
