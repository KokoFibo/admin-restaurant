import { db, json, orderError, TOKEN, UUID } from '../../server/v1';

/**
 * POST /v1/bill-request { site, token, client? } → { table_label, my_total_idr, has_fees }
 * Pelanggan menekan "Minta bill": kasir/manager/owner melihat penandanya di tab Tagihan. Idempotent.
 * my_total_idr = jumlah pesanan perangkat ini (sebelum diskon/pajak/biaya layanan; has_fees = ada pajak/biaya layanan). Pesanan orang lain tidak ditampilkan.
 * Galat → { code }: E:invalid_table 403 · E:no_bill 409 (belum ada pesanan di meja ini) · E:unavailable 503.
 */
export const onRequestPost = async ({ request, env: e }: any) => {
  const fail = (code: string, status: number) => json({ code }, status);
  let b: any; try { b = await request.json(); } catch { return fail('E:invalid_table', 403); }
  const site = String(b?.site || ''), token = String(b?.token || ''), client = /^[0-9a-f]{32}$/i.test(String(b?.client ?? '')) ? String(b.client).toLowerCase() : null;
  if (!UUID.test(site) || !TOKEN.test(token)) return fail('E:invalid_table', 403);
  const sb = db(e); if (!sb) return fail('E:unavailable', 503);
  const r = await sb.rpc('request_bill', { p_tenant: site, p_token: token.toLowerCase(), p_client: client });
  if (r.error) { const [code, status] = orderError(r.error.message); if (status >= 500) console.error('request_bill', r.error.message); return fail(code, status); }
  return json({ table_label: r.data.table_label, my_total_idr: r.data.my_total_idr, has_fees: r.data.has_fees === true });
};
export const onRequest = () => json({ error: 'method_not_allowed' }, 405);
