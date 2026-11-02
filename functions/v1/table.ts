import { db, json, TOKEN, UUID } from '../../server/v1';

/** GET /v1/table?site=<id>&token=<32 hex> → { label } atau 404 (token salah / meja nonaktif / bukan milik restoran ini). */
export const onRequestGet = async ({ request, env: e }: any) => {
  const q = new URL(request.url).searchParams, site = q.get('site') || '', token = q.get('token') || '';
  if (!UUID.test(site) || !TOKEN.test(token)) return json({ error: 'not_found' }, 404);
  const sb = db(e); if (!sb) return json({ error: 'not_configured' }, 503);
  const r = await sb.rpc('resolve_table', { p_tenant: site, p_token: token.toLowerCase() });
  if (r.error) { console.error('resolve_table', r.error.message); return json({ error: 'upstream' }, 502); }
  return r.data ? json({ label: r.data.label }) : json({ error: 'not_found' }, 404);
};
export const onRequest = () => json({ error: 'method_not_allowed' }, 405);
