import { db, json, orderError, TOKEN, UUID } from '../../server/v1';

/**
 * POST /v1/online-claim { site, token } → { ok: true }
 * Pelanggan menekan "Saya sudah bayar" (bayar di muka via QRIS). Hanya menandai; staf yang memverifikasi di aplikasi merchant. Idempotent.
 * Galat → { code }: E:invalid_order 404 (token salah / bukan pesanan bayar-di-muka / sudah diproses) · E:unavailable 503.
 */
export const onRequestPost = async ({ request, env: e }: any) => {
  let b: any; try { b = await request.json(); } catch { return json({ code: 'E:invalid_order' }, 404); }
  const site = String(b?.site || ''), token = String(b?.token || '');
  if (!UUID.test(site) || !TOKEN.test(token)) return json({ code: 'E:invalid_order' }, 404);
  const sb = db(e); if (!sb) return json({ code: 'E:unavailable' }, 503);
  const r = await sb.rpc('claim_online_payment', { p_tenant: site, p_token: token.toLowerCase() });
  if (r.error) { const [code, status] = orderError(r.error.message); if (status >= 500) console.error('claim_online_payment', r.error.message); return json({ code }, status); }
  return json({ ok: true });
};
export const onRequest = () => json({ error: 'method_not_allowed' }, 405);
