import { buildSite, db, json, validHost, validSlug } from '../../server/v1';

/**
 * GET /v1/site?host=<domain>&slug=<opsional> → Site (lihat API-CONTRACT.md). 404 = domain tidak dikenal.
 * Restoran HANYA dicari lewat tabel tenant_domains (subdomain bawaan <slug>.<domain-dasar> maupun domain kustom).
 * Slug hanya dilayani bila ALLOW_SLUG_FALLBACK=true (pratinjau/pengembangan); jangan diaktifkan di produksi.
 */
export const onRequestGet = async ({ request, env: e }: any) => {
  const u = new URL(request.url), host = (u.searchParams.get('host') || '').trim().toLowerCase().replace(/\.$/, '');
  const allowSlug = String(e.ALLOW_SLUG_FALLBACK || '') === 'true';
  const slug = allowSlug ? (u.searchParams.get('slug') || '').trim().toLowerCase() : '';
  if ((host && !validHost(host)) || (slug && !validSlug(slug)) || (!host && !slug)) return json({ error: 'bad_request' }, 400);
  const sb = db(e); if (!sb) return json({ error: 'not_configured' }, 503);
  const r = await sb.rpc('resolve_tenant', { p_host: host || '-', p_slug: slug || null });
  if (r.error) { console.error('resolve_tenant', r.error.message); return json({ error: 'upstream' }, 502); }
  if (!r.data) return json({ error: 'not_found' }, 404);
  const c = await sb.rpc('site_content_json', { p_tenant: r.data.id });
  if (c.error) { console.error('site_content_json', c.error.message); return json({ error: 'upstream' }, 502); }
  return json(buildSite(e, r.data, c.data ?? {}));
};
export const onRequest = () => json({ error: 'method_not_allowed' }, 405);
