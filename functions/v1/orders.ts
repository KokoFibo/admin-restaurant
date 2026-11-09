import { db, json, orderError, TOKEN, UUID } from '../../server/v1';

/**
 * POST /v1/orders { site, token, lang, items[{id,qty}], name, note, client? } → { order_no, table_label, total_idr, my_total_idr }
 * Harga TIDAK dikirim: place_order menghitung ulang dan memvalidasi semuanya (meja, ketersediaan, ditutup, batas pelanggan).
 * client = 32 hex acak per perangkat (dibuat frontend, disimpan di browser) untuk mengenali pelanggan yang sama; tanpa itu dibuatkan acak.
 * Galat → { code } dengan status HTTP: E:invalid_table 403 · E:empty 400 · E:rate_limited 429 (1 pesanan/10 dtk/perangkat) · E:table_full 409 (maks 15 pelanggan/meja) · E:item_unavailable 409 · E:closed 409 · E:unavailable 503.
 */
export const onRequestPost = async ({ request, env: e }: any) => {
  const fail = (code: string, status: number) => json({ code }, status);
  let b: any; try { b = await request.json(); } catch { return fail('E:empty', 400); }
  const site = String(b?.site || ''), token = String(b?.token || ''), lang = /^[a-z]{2}$/.test(String(b?.lang)) ? String(b.lang) : 'id';
  const items = Array.isArray(b?.items) ? b.items : [];
  const client = /^[0-9a-f]{32}$/i.test(String(b?.client ?? '')) ? String(b.client).toLowerCase() : crypto.randomUUID().replace(/-/g, '');
  const name = String(b?.name ?? '').trim().slice(0, 60), note = String(b?.note ?? '').trim().slice(0, 200);
  if (!UUID.test(site) || !TOKEN.test(token)) return fail('E:invalid_table', 403);
  if (!items.length || items.length > 40 || !items.every((i: any) => i && UUID.test(String(i.id)) && Number.isInteger(i.qty) && i.qty >= 1 && i.qty <= 20)) return fail('E:empty', 400);
  const sb = db(e); if (!sb) return fail('E:unavailable', 503);
  const r = await sb.rpc('place_order', { p_tenant: site, p_token: token.toLowerCase(), p_items: items.map((i: any) => ({ id: String(i.id).toLowerCase(), qty: i.qty })), p_name: name, p_note: note, p_lang: lang, p_client: client });
  if (r.error) { const [code, status] = orderError(r.error.message); if (status >= 500) console.error('place_order', r.error.message); return fail(code, status); }
  return json({ order_no: r.data.order_no, table_label: r.data.table_label, total_idr: r.data.total_idr, my_total_idr: r.data.my_total_idr ?? r.data.total_idr });
};
export const onRequest = () => json({ error: 'method_not_allowed' }, 405);
