import { reactive, ref } from 'vue';
import { sb } from './lib/supabase';
import { t, lang, applyLang } from './lib/i18n';

export const ROLE_LABEL: Record<string, string> = { super_admin: 'Super Admin', owner: 'Owner', manager: 'Manager', cashier: 'Cashier', kitchen: 'Kitchen', service: 'Service' };
export const CREATE_ROLES: Record<string, string[]> = { super_admin: ['owner', 'manager', 'cashier', 'kitchen', 'service'], owner: ['manager', 'cashier', 'kitchen', 'service'] };
export const TYPES: Record<string, string> = { vegan: 'Vegan', vegetarian: 'Vegetarian', umum: 'Umum' };
export const TYPE_DEFAULTS: Record<string, string[]> = { vegan: ['has_onion', 'is_spicy'], vegetarian: ['has_egg', 'has_onion', 'is_spicy'], umum: ['is_non_halal', 'is_spicy'] };
export const optionMeta = (): [string, string][] => [['has_egg', t('Mengandung telur')], ['has_onion', t('Mengandung bawang')], ['is_non_halal', t('Non halal')], ['is_spicy', t('Pedas & tingkat kepedasan')]];

export const S = reactive<any>({
  view: 'boot' as 'boot' | 'login' | 'panel' | 'recover', uid: '', email: '', isMaster: false, tenants: [], tid: '', myRoles: {}, tab: 'menu', noTenant: false,
  langsAll: [], T: null, TL: ['id'], cats: [], items: [], catTr: [], itTr: [], tenTr: [], members: [], tables: [], domains: [],
});
/** Penanda "minta bill" dari pelanggan (tanpa nominal) — dibaca kasir/manager/owner dan Service. */
export const billReqs = ref<any[]>([]); let billReqInit = false;
export async function loadBillReqs() {
  const tid = S.tid; if (!tid || !(can.pay() || role() === 'service')) { billReqs.value = []; billReqInit = false; return; }
  const { data, error } = await sb.rpc('list_bill_requests', { p_tenant: tid }); if (error || tid !== S.tid) return;
  const old = new Set(billReqs.value.map((x: any) => x.bill_id)), fresh = (data || []).filter((x: any) => !old.has(x.bill_id));
  billReqs.value = data || [];
  if (billReqInit && fresh.length) toast(t('Minta bill: {0}', fresh.map((x: any) => x.label).join(', ')));
  billReqInit = true;
}
export const toastMsg = ref(''); let toastTimer: any;
export const toast = (m: string) => { toastMsg.value = m; clearTimeout(toastTimer); toastTimer = setTimeout(() => (toastMsg.value = ''), 4200); };
/** Daftar meja yang QR-nya sedang ditampilkan (null = tertutup). */
export const qrList = ref<any[] | null>(null);

export const bySort = (a: any, b: any) => a.sort - b.sort || (a.created_at || '').localeCompare(b.created_at || '');
export const role = (): string => (S.isMaster ? 'super_admin' : S.myRoles[S.tid] || '');
export const can = {
  edit: () => ['super_admin', 'owner', 'manager'].includes(role()),
  sold: () => ['super_admin', 'owner', 'manager', 'kitchen'].includes(role()),
  resto: () => ['super_admin', 'owner'].includes(role()),
  accounts: () => ['super_admin', 'owner'].includes(role()),
  site: () => ['super_admin', 'owner'].includes(role()),
  banner: () => ['super_admin', 'owner', 'manager'].includes(role()),
  pay: () => ['super_admin', 'owner', 'manager', 'cashier'].includes(role()),
  void: () => ['super_admin', 'owner', 'manager'].includes(role()),   // tutup paksa tagihan / batalkan pembayaran
  price: () => role() !== 'kitchen',                                  // dapur tidak perlu melihat harga
};
export const lim = (c: string) => S.langsAll.find((l: any) => l.code === c) || { code: c, name_native: c, max_name: 60, max_short: 160, max_detail: 700 };
export const itText = (id: string, l: string): any => S.itTr.find((r: any) => r.menu_item_id === id && r.lang === l) || {};
export const catName = (id: string, l = S.TL[0]) => S.catTr.find((r: any) => r.category_id === id && r.lang === l)?.name || t('(tanpa nama)');
export const enabled = (o: string) => (S.T?.menu_options || []).includes(o);
const defaultTab = () => (role() === 'cashier' ? 'bills' : ['kitchen', 'service'].includes(role()) ? 'orders' : 'menu');

/** Alamat website publik restoran (untuk "Lihat website" dan QR meja): domain sendiri dari tenant_domains, kalau tidak ada <slug>.<domain-dasar>. Bukan alamat admin. */
const BASE_DOMAIN = (import.meta.env.PUBLIC_BASE_DOMAIN || '').replace(/^\./, '');
export function siteBase(): string {
  const d = S.domains.find((x: any) => x.is_primary && x.status === 'active') || S.domains.find((x: any) => x.status === 'active');
  if (d) return 'https://' + d.hostname;
  const slug = S.tenants.find((x: any) => x.id === S.tid)?.slug;
  return slug && BASE_DOMAIN ? `https://${slug}.${BASE_DOMAIN}` : '';
}

/* ---------- sesi ---------- */
let booting: Promise<void> | null = null;
export const boot = () => (booting ??= start().finally(() => (booting = null)));
/** Mode "buat kata sandi baru" setelah membuka tautan lupa-kata-sandi dari email. */
export const rec = { on: false };
export function watchAuth() {
  rec.on = /type=recovery/.test(location.hash); if (rec.on) S.view = 'recover';
  sb.auth.onAuthStateChange((ev: string, s: any) => {
    if (ev === 'PASSWORD_RECOVERY') { rec.on = true; S.view = 'recover'; return; }
    if (!s) { S.uid = ''; S.T = null; S.view = 'login'; return; }
    if (rec.on) { S.view = 'recover'; return; }
    S.view = 'panel'; if (S.uid !== s.user?.id) boot();   // token refresh tidak memuat ulang apa pun
  });
  sb.auth.getSession().then(({ data }: any) => { if (rec.on) return; S.view = data.session ? 'panel' : 'login'; if (data.session) boot(); });
}
export function endRecovery() { rec.on = false; history.replaceState(null, '', location.pathname); S.view = 'panel'; boot(); }
export const login = (email: string, pw: string) => sb.auth.signInWithPassword({ email, password: pw });
export const logout = () => sb.auth.signOut();

async function start() {
  const { data } = await sb.auth.getUser(); S.uid = data.user?.id || ''; S.email = data.user?.email || '';
  const userLang = data.user?.user_metadata?.admin_lang; if (userLang === 'en' || userLang === 'id') applyLang(userLang);
  const [tn, pa, lg, mm] = await Promise.all([sb.from('tenants').select('id,slug').order('slug'), sb.from('platform_admins').select('user_id').eq('user_id', S.uid),
    sb.from('languages').select('*').order('sort'), sb.from('tenant_members').select('tenant_id,role').eq('user_id', S.uid)]);
  if (tn.error) return toast(t('Gagal memuat restoran: {0}', tn.error.message));
  S.tenants = tn.data || []; S.isMaster = (pa.data || []).length > 0; S.langsAll = lg.data || [];
  S.myRoles = Object.fromEntries((mm.data || []).map((x: any) => [x.tenant_id, x.role]));
  S.noTenant = S.tenants.length === 0; if (S.noTenant) return;
  // Satu alamat admin untuk semua: restoran ditentukan oleh AKUN yang login (keanggotaan), bukan nama host.
  const saved = localStorage.getItem('admin_tenant');
  S.tid = S.tenants.find((y: any) => y.id === saved)?.id || S.tenants[0].id;
  S.tab = defaultTab();
  await load(!userLang);
}
export function selectTenant(id: string) { S.tid = id; localStorage.setItem('admin_tenant', id); S.tab = defaultTab(); return load(false); }

export async function load(useTenantLang = false) {
  const id = S.tid;
  const r = await Promise.all([
    sb.from('categories').select('*').eq('tenant_id', id), sb.from('category_translations').select('*').eq('tenant_id', id),
    sb.from('menu_items').select('*').eq('tenant_id', id), sb.from('menu_item_translations').select('*').eq('tenant_id', id),
    sb.from('tenants').select('*').eq('id', id).single(), sb.from('tenant_translations').select('*').eq('tenant_id', id),
    sb.from('tenant_languages').select('lang,position').eq('tenant_id', id).order('position'),
    sb.from('tenant_domains').select('hostname,is_primary,status').eq('tenant_id', id)]);
  if (id !== S.tid) return;
  const bad = r.find((x: any) => x.error); if (bad) return toast(t('Gagal memuat data: {0}', bad.error.message));
  S.cats = (r[0].data || []).sort(bySort); S.catTr = r[1].data || []; S.items = (r[2].data || []).sort(bySort); S.itTr = r[3].data || [];
  S.T = r[4].data; S.tenTr = r[5].data || []; S.TL = (r[6].data || []).map((x: any) => x.lang); if (!S.TL.length) S.TL = ['id']; S.domains = r[7].data || [];
  if (useTenantLang && (S.T.admin_default_lang === 'en' || S.T.admin_default_lang === 'id') && S.T.admin_default_lang !== lang.value) applyLang(S.T.admin_default_lang);
  if (S.tab === 'akun' && can.accounts()) await loadMembers();
  if (S.tab === 'tables') await loadTables();
}
export async function loadMembers() {
  const { data, error } = await sb.rpc('list_tenant_members', { p_tenant: S.tid });
  if (error) { S.members = []; return toast(t('Gagal memuat akun: {0}', error.message)); } S.members = data || [];
}
export async function loadTables() {
  const { data } = await sb.from('restaurant_tables').select('*').eq('tenant_id', S.tid); S.tables = (data || []).sort(bySort);
}
export async function setTab(tab: string) { S.tab = tab; if (tab === 'akun') await loadMembers(); if (tab === 'tables') await loadTables(); }
export const run = async (p: Promise<any>, ok = '') => { const { error } = await p; if (error) return toast(error.message); if (ok) toast(ok); await load(); };
