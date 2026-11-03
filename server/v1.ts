/**
 * API publik /v1 untuk website restoran (kontrak: API-CONTRACT.md di proyek frontend).
 * Dipanggil dari SERVER frontend (bukan dari browser). Hanya memakai kunci anon + RLS/RPC publik; tidak memakai service_role.
 */
import { createClient } from '@supabase/supabase-js';
import { env } from './env';

export const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' } });
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const TOKEN = /^[0-9a-f]{32}$/i;
const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const HOST = /^[a-z0-9]+(?:[.-][a-z0-9]+)*$/;
const RESERVED = new Set(['admin', 'www', 'api']);

export function db(e: any) {
  const url = env(e, 'PUBLIC_SUPABASE_URL'), key = env(e, 'PUBLIC_SUPABASE_ANON_KEY');
  return url && key ? createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } }) : null;
}

/** URL foto: kunci R2 → ${PUBLIC_MEDIA_URL}/kunci; alamat penuh atau berawalan "/" dipakai apa adanya; tanpa PUBLIC_MEDIA_URL → null. */
export function mediaUrl(e: any, key: string | null | undefined): string | null {
  if (!key) return null;
  if (/^https?:\/\//.test(key) || key.startsWith('/')) return key;
  const base = (env(e, 'PUBLIC_MEDIA_URL') || '').trim().replace(/\/+$/, '');
  return base ? `${base}/${key}` : null;
}

/** Host "<slug>.<PUBLIC_BASE_DOMAIN>" → slug (restoran tanpa domain sendiri). */
export function slugFromHost(e: any, host: string): string | null {
  const base = (env(e, 'PUBLIC_BASE_DOMAIN') || '').trim().toLowerCase().replace(/^\./, '');
  if (!base || !host.endsWith('.' + base)) return null;
  const label = host.slice(0, -(base.length + 1));
  return SLUG.test(label) && !RESERVED.has(label) ? label : null;
}
export const validHost = (h: string) => h.length > 0 && h.length <= 253 && HOST.test(h);
export const validSlug = (s: string) => s.length > 0 && s.length <= 63 && SLUG.test(s);

/* ---------------- tema (warna dihitung DI SINI; frontend hanya memetakan ke CSS) ---------------- */
type Colors = { primary: string; secondary: string; accent: string; bg: string; bg2: string; ink: string; ink2: string; line: string };
const PRESETS: Record<string, [string, string, string, string, string]> = {   // primary, secondary, accent, bg, bg2 — sama dengan src/lib/themes.ts (admin)
  giok: ['#2B5B47', '#3D735B', '#C35B3B', '#FBF8F2', '#F4EEE2'], teh: ['#7A4A21', '#96623A', '#A8402A', '#FBF7F0', '#F3EADB'],
  samudra: ['#1F4E6B', '#2F6F94', '#B45F14', '#F6F9FB', '#E8EFF4'], bata: ['#8E2A2A', '#A84545', '#8A6414', '#FCF8F4', '#F5EBE1'],
  anggur: ['#5B3A66', '#75507F', '#A5561B', '#FAF7FA', '#EFE8F1'], zaitun: ['#4F5D2F', '#6B7B45', '#B0532E', '#FAF9F3', '#EFEDDC'],
  arang: ['#2E3A3F', '#46565C', '#C4481F', '#F8F8F6', '#ECECE8'],
};
const HEX = /^#[0-9a-fA-F]{6}$/;
const rgb = (h: string) => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
const hex = (c: number[]) => '#' + c.map(v => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, '0')).join('').toUpperCase();
export const mix = (a: string, b: string, t: number) => { const x = rgb(a), y = rgb(b); return hex(x.map((v, i) => v * (1 - t) + y[i] * t)); };
const line = (primary: string) => { const [r, g, b] = rgb(primary); return `rgba(${r},${g},${b},.12)`; };

export function resolveTheme(t: { theme?: string; theme_custom?: any; theme_dark?: boolean } | null | undefined) {
  const id = String(t?.theme || 'giok'), dark = t?.theme_dark === true;
  if (id === 'custom') {
    const c = t?.theme_custom, p = String(c?.primary || ''), a = String(c?.accent || ''), b = String(c?.bg || '');
    if (![p, a, b].every(v => HEX.test(v))) return null;
    const primary = p.toUpperCase(), accent = a.toUpperCase(), bg = b.toUpperCase();
    const colors: Colors = { primary, secondary: mix(primary, '#FFFFFF', 0.15), accent, bg, bg2: mix(bg, primary, 0.06), ink: dark ? '#F2EFE9' : '#1E2621', ink2: dark ? '#C9C5BC' : '#404944', line: line(primary) };
    return { id: 'custom', dark, colors };
  }
  const p = PRESETS[id]; if (!p || (id === 'giok' && !dark)) return null;       // giok = tampilan bawaan frontend
  return { id, dark: false, colors: { primary: p[0], secondary: p[1], accent: p[2], bg: p[3], bg2: p[4], ink: '#1E2621', ink2: '#404944', line: line(p[0]) } as Colors };
}

/* ---------------- Site ---------------- */
const HERO_KEYS = ['eyebrow', 'title', 'title_em', 'lead', 'chip1', 'chip2', 'chip3', 'cta_order', 'cta_menu'];
const pickMap = (o: any, f: (x: any) => any) => {
  const out: Record<string, string> = {};
  if (o && typeof o === 'object') for (const [k, v] of Object.entries(o)) { const s = f(v); if (typeof s === 'string' && s.trim()) out[k] = s; }
  return out;
};

/** raw = rpc resolve_tenant (tenant_public_json), content = rpc site_content_json */
export function buildSite(e: any, raw: any, content: any) {
  const texts: Record<string, Record<string, string>> = {};
  for (const k of HERO_KEYS) { const m = pickMap(content?.texts?.[`hero.${k}`], x => x); if (Object.keys(m).length) texts[k] = m; }
  const banners = (Array.isArray(content?.banners) ? content.banners : []).slice(0, 3).map((b: any) => {
    const labels = pickMap(b.texts, x => x?.link_label);
    return { id: b.id, kind: b.kind, scope: b.scope, link_url: b.link_url ?? null, blocks_orders: b.blocks_orders === true, rev: b.rev, text: pickMap(b.texts, x => x?.message), link_label: Object.keys(labels).length ? labels : null };
  });
  return {
    id: raw.id, slug: raw.slug, status: raw.status, restaurant_type: raw.restaurant_type, template_id: raw.template_id ?? 'aisin', languages: raw.languages ?? ['id'], translations: raw.translations ?? {},
    phone: raw.phone ?? null, whatsapp: raw.whatsapp ?? null, email: raw.email ?? null, maps_url: raw.maps_url ?? null, address: raw.address ?? null, opening_hours: raw.opening_hours ?? null,
    primary_color: null, theme: resolveTheme(raw), orders_open: content?.orders_open !== false,
    hero: { texts, image: mediaUrl(e, content?.images?.hero) }, banners,
  };
}

/* ---------------- Menu ---------------- */
async function all(q: (from: number, to: number) => PromiseLike<{ data: any[] | null; error: any }>) {
  const out: any[] = [];
  for (let i = 0; ; i += 1000) { const { data, error } = await q(i, i + 999); if (error) throw error; out.push(...(data || [])); if ((data || []).length < 1000) break; }
  return out;
}
const bySort = (a: any, b: any) => a.sort - b.sort || String(a.created_at || '').localeCompare(String(b.created_at || ''));

export async function loadMenu(e: any, sb: ReturnType<typeof db>, site: string) {
  const s = sb!;
  const [cats, catTr, items, itemTr] = await Promise.all([
    all((a, b) => s.from('categories').select('id,slug,sort,created_at').eq('tenant_id', site).order('id').range(a, b)),
    all((a, b) => s.from('category_translations').select('category_id,lang,name').eq('tenant_id', site).order('category_id').range(a, b)),
    all((a, b) => s.from('menu_items').select('id,category_id,price_idr,image_key,has_egg,has_onion,is_non_halal,is_spicy,spice_level,is_sold_out,is_featured,sort,created_at').eq('tenant_id', site).order('id').range(a, b)),
    all((a, b) => s.from('menu_item_translations').select('menu_item_id,lang,name,short_description,detail_description,badge').eq('tenant_id', site).order('menu_item_id').range(a, b)),
  ]);
  const slugOf = new Map(cats.map(c => [c.id, c.slug]));
  const group = (rows: any[], key: string, f: (r: any) => Record<string, string | null>) => {
    const m = new Map<string, Record<string, Record<string, string | null>>>();
    for (const r of rows) { const g = m.get(r[key]) ?? {}; g[r.lang] = f(r); m.set(r[key], g); }
    return m;
  };
  const cn = group(catTr, 'category_id', r => ({ name: r.name }));
  const it = group(itemTr, 'menu_item_id', r => ({ name: r.name, short: r.short_description, detail: r.detail_description, badge: r.badge }));
  const loc = (g: Record<string, Record<string, string | null>> | undefined, f: string) => {
    const o: Record<string, string> = {};
    for (const [lang, v] of Object.entries(g ?? {})) if (v[f] && String(v[f]).trim()) o[lang] = String(v[f]);
    return o;
  };
  const orNull = (o: Record<string, string>) => (Object.keys(o).length ? o : null);
  return {
    cats: cats.sort(bySort).map(c => ({ slug: c.slug, glyph: '', name: loc(cn.get(c.id), 'name') })),
    dishes: items.filter(d => slugOf.has(d.category_id)).sort(bySort).map(d => ({
      id: d.id, cat: slugOf.get(d.category_id), price: d.price_idr, img: mediaUrl(e, d.image_key),
      egg: !!d.has_egg, onion: !!d.has_onion, nonHalal: !!d.is_non_halal, spicy: d.is_spicy ? Number(d.spice_level) || 1 : 0, soldOut: !!d.is_sold_out, featured: !!d.is_featured,
      name: loc(it.get(d.id), 'name'), short: loc(it.get(d.id), 'short'), detail: orNull(loc(it.get(d.id), 'detail')), badge: orNull(loc(it.get(d.id), 'badge')),
    })),
  };
}

/* ---------------- Pesanan ---------------- */
const ORDER_STATUS: Record<string, number> = { 'E:invalid_table': 403, 'E:empty': 400, 'E:rate_limited': 429, 'E:too_many_active': 429, 'E:item_unavailable': 409, 'E:closed': 409 };
export function orderError(message: unknown): [string, number] {
  const code = /E:[a-z_]+/.exec(String(message ?? ''))?.[0];
  return code && ORDER_STATUS[code] ? [code, ORDER_STATUS[code]] : ['E:unavailable', 503];
}
