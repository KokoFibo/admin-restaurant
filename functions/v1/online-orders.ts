import { db, json, orderError, TOKEN, UUID } from '../../server/v1';

/**
 * Pesanan online (takeaway) — pelanggan memesan lewat tautan, tanpa QR meja.
 *
 * POST /v1/online-orders { site, lang, items[{id,qty}], name, phone, pickup_by: "customer"|"courier", pay_plan: "at_pickup"|"prepay_qris", note, client? }
 *   → { order_no, token, status: "pending", pickup_by, pay_plan, figures{subtotal,service_pct,service,tax_pct,tax,total}, total_idr }
 *   Harga TIDAK dikirim; place_online_order menghitung ulang. total_idr = total AKHIR (sudah termasuk biaya layanan & pajak) — itu yang dibayar pelanggan.
 *   Galat → { code }: E:online_off 409 · E:closed 409 · E:empty 400 · E:name_required 400 · E:phone_invalid 400 · E:prepay_off 409 · E:rate_limited 429 (1 pesanan/60 dtk per perangkat & per nomor)
 *          · E:pending_full 429 (maks 3 menunggu per perangkat/nomor, 30 per restoran) · E:item_unavailable 409 · E:unavailable 503
 *
 * GET /v1/online-orders?site=<id>&token=<32 hex> → status untuk halaman pelanggan (tanpa nomor WhatsApp)
 *   → { order_no, status: pending|new|preparing|ready|done|cancelled|rejected|expired, name, pickup_by, pay_plan, pay_claimed, paid, reject_reason, created_at, note,
 *       figures{subtotal,discount,service,tax,total}, items[{name,qty,line_total}] }
 *   404 { code: "E:invalid_order" } bila token salah.
 */
export const onRequestPost = async ({ request, env: e }: any) => {
  const fail = (code: string, status: number) => json({ code }, status);
  let b: any; try { b = await request.json(); } catch { return fail('E:empty', 400); }
  const site = String(b?.site || ''), lang = /^[a-z]{2}$/.test(String(b?.lang)) ? String(b.lang) : 'id';
  const items = Array.isArray(b?.items) ? b.items : [];
  const client = /^[0-9a-f]{32}$/i.test(String(b?.client ?? '')) ? String(b.client).toLowerCase() : null;
  if (!UUID.test(site)) return fail('E:online_off', 409);
  if (!items.length || items.length > 40 || !items.every((i: any) => i && UUID.test(String(i.id)) && Number.isInteger(i.qty) && i.qty >= 1 && i.qty <= 20)) return fail('E:empty', 400);
  const sb = db(e); if (!sb) return fail('E:unavailable', 503);
  const r = await sb.rpc('place_online_order', {
    p_tenant: site, p_items: items.map((i: any) => ({ id: String(i.id).toLowerCase(), qty: i.qty })),
    p_name: String(b?.name ?? '').slice(0, 60), p_phone: String(b?.phone ?? '').slice(0, 30),
    p_pickup_by: b?.pickup_by === 'courier' ? 'courier' : 'customer', p_pay_plan: b?.pay_plan === 'prepay_qris' ? 'prepay_qris' : 'at_pickup',
    p_note: String(b?.note ?? '').slice(0, 200), p_lang: lang, p_client: client,
  });
  if (r.error) { const [code, status] = orderError(r.error.message); if (status >= 500) console.error('place_online_order', r.error.message); return fail(code, status); }
  return json(r.data);
};

export const onRequestGet = async ({ request, env: e }: any) => {
  const q = new URL(request.url).searchParams, site = q.get('site') || '', token = q.get('token') || '';
  if (!UUID.test(site) || !TOKEN.test(token)) return json({ code: 'E:invalid_order' }, 404);
  const sb = db(e); if (!sb) return json({ code: 'E:unavailable' }, 503);
  const r = await sb.rpc('online_order_status', { p_tenant: site, p_token: token.toLowerCase() });
  if (r.error) { const [code, status] = orderError(r.error.message); if (status >= 500) console.error('online_order_status', r.error.message); return json({ code }, status); }
  return json(r.data);
};
export const onRequest = () => json({ error: 'method_not_allowed' }, 405);
