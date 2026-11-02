import { db, json, loadMenu, UUID } from '../../server/v1';

/** GET /v1/menu?site=<site.id> → { cats, dishes }: hanya yang terlihat & tidak diarsipkan (RLS publik), berurutan. */
export const onRequestGet = async ({ request, env: e }: any) => {
  const site = new URL(request.url).searchParams.get('site') || '';
  if (!UUID.test(site)) return json({ error: 'bad_request' }, 400);
  const sb = db(e); if (!sb) return json({ error: 'not_configured' }, 503);
  try { return json(await loadMenu(e, sb, site)); } catch (err: any) { console.error('menu', err?.message); return json({ error: 'upstream' }, 502); }
};
export const onRequest = () => json({ error: 'method_not_allowed' }, 405);
