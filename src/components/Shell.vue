<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue';
import { t, applyLang, lang } from '../lib/i18n';
import { S, can, selectTenant, setTab, siteBase, toast, load, billReqs, loadBillReqs, online, updateReady, checkVersion } from '../store';
import { sb } from '../lib/supabase';
import OrdersTab from './OrdersTab.vue'; import BillsTab from './BillsTab.vue'; import MenuTab from './MenuTab.vue'; import CategoriesTab from './CategoriesTab.vue';
import SiteTab from './SiteTab.vue'; import BannersTab from './BannersTab.vue'; import TablesTab from './TablesTab.vue'; import RestaurantTab from './RestaurantTab.vue'; import AccountsTab from './AccountsTab.vue'; import PasswordDialog from './PasswordDialog.vue'; import ProfileMenu from './ProfileMenu.vue'; import AvatarDialog from './AvatarDialog.vue';
const pw = ref<any>(), av = ref<any>();
let reqTimer: any;
watch(() => S.tid, () => { billReqs.value = []; loadBillReqs(); }, { immediate: true });
/** Di HP tab bisa digeser: pastikan tab aktif terlihat di tengah. */
function centerTab() { nextTick(() => { const el = document.querySelector('.tabs button.on') as HTMLElement | null, c = el?.parentElement; if (el && c && c.scrollWidth > c.clientWidth) c.scrollTo({ left: el.offsetLeft - (c.clientWidth - el.offsetWidth) / 2, behavior: 'smooth' }); }); }
watch(() => S.tab, centerTab);
onMounted(() => { centerTab(); checkVersion(); reqTimer = setInterval(() => document.visibilityState === 'visible' && loadBillReqs(), 6000); }); onUnmounted(() => clearInterval(reqTimer));
const tabs = computed<[string, string][]>(() => ([['orders', t('Pesanan'), true], ['bills', t('Tagihan') + (billReqs.value.length ? ` 🔔${billReqs.value.length}` : ''), can.pay()], ['menu', t('Menu'), true], ['cats', t('Kategori'), can.edit()], ['tables', t('Meja'), can.edit()], ['resto', t('Pengaturan'), true], ['site', t('Tampilan Website'), can.site()], ['banner', t('Banner'), can.banner()], ['akun', t('Akun'), can.accounts()]] as [string, string, boolean][]).filter(x => x[2]).map(x => [x[0], x[1]]));
const view = { orders: OrdersTab, bills: BillsTab, menu: MenuTab, cats: CategoriesTab, tables: TablesTab, resto: RestaurantTab, site: SiteTab, banner: BannersTab, akun: AccountsTab } as any;
const name = computed(() => (S.tenTr.find((x: any) => x.lang === S.TL[0])?.brand_name || S.T?.slug || ''));
const site = computed(siteBase);
const location = window.location;
const paused = computed(() => !!S.T?.orders_paused);
async function togglePause() {
  const next = !paused.value; if (next && !confirm(t('Tutup pemesanan QR sementara? Pelanggan tidak bisa memesan sampai dibuka lagi.'))) return;
  const { error } = await sb.rpc('set_orders_paused', { p_tenant: S.tid, p_paused: next }); if (error) return toast(error.message);
  toast(next ? t('Pemesanan ditutup sementara') : t('Pemesanan dibuka kembali')); load();
}
function pick(l: 'id' | 'en') { applyLang(l); if (S.uid) sb.auth.updateUser({ data: { admin_lang: l } }).catch(() => {}); }
</script>
<template>
  <div class="adm-shell">
    <header class="ah"><b class="brand" :title="S.T ? name : 'Dapora'">{{ S.T ? name : 'Dapora' }}</b>
      <span class="ah-r">
        <select v-if="S.isMaster || S.tenants.length > 1" :aria-label="t('Restoran')" :value="S.tid" @change="selectTenant(($event.target as any).value)"><option v-for="x in S.tenants" :key="x.id" :value="x.id">{{ x.slug }}</option></select>
        <span class="langsw hd-lang"><button type="button" :class="{ on: lang === 'id' }" @click="pick('id')">ID</button><button type="button" :class="{ on: lang === 'en' }" @click="pick('en')">EN</button></span>
        <button v-if="S.T && can.banner()" class="btn ghost pausebtn" :class="{ on: paused }" @click="togglePause">{{ paused ? t('Pemesanan: DITUTUP — buka lagi') : t('Tutup sementara') }}</button>
        <a v-if="site" class="hd-site" :href="site" target="_blank" rel="noopener">{{ t('Lihat website ↗') }}</a>
        <ProfileMenu :site="site" @lang="pick" @password="pw.open()" @avatar="av.open()" /></span></header>
    <div v-if="!online" class="sbar" role="status">{{ t('Tidak ada koneksi internet. Pesanan dan tagihan tidak bisa disimpan sampai tersambung lagi.') }}</div>
    <div v-if="updateReady" class="sbar upd" role="status">{{ t('Versi baru tersedia.') }} <button type="button" @click="location.reload()">{{ t('Muat ulang') }}</button></div>
    <div class="wrap">
      <p v-if="S.noTenant" class="err">{{ t('Akun ini belum terhubung ke restoran mana pun, atau sedang dinonaktifkan. Hubungi Owner atau pengelola layanan.') }}</p>
      <template v-else-if="S.T">
        <div class="tabs" style="margin-bottom:1.5rem"><button v-for="x in tabs" :key="x[0]" :class="{ on: x[0] === S.tab }" @click="setTab(x[0])">{{ x[1] }}</button></div>
        <component :is="view[S.tab] || MenuTab" :key="S.tid + S.tab" />
      </template>
    </div>
    <PasswordDialog ref="pw" /><AvatarDialog ref="av" />
  </div>
</template>
