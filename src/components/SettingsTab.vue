<script setup lang="ts">
import { computed, nextTick, watch } from 'vue';
import { t } from '../lib/i18n';
import { S, role, sub, openSettings } from '../store';
import { settingsFor } from '../lib/settings';
import RestaurantTab from './RestaurantTab.vue';
import SiteTab from './SiteTab.vue';
import BannersTab from './BannersTab.vue';
import DevicePanel from './DevicePanel.vue';
import PurgePanel from './PurgePanel.vue';
/** Halaman Pengaturan: sub-tab. Urutan tetap; setiap peran hanya melihat sub-tab yang boleh diaksesnya. */
const FORMS = ['profil', 'menu', 'istilah', 'pajak', 'online', 'konfig'];   // panel di RestaurantTab (props.section)
const NAMES = (): Record<string, string> => ({ profil: t('Profil Restoran'), situs: t('Tampilan Website'), menu: t('Tampilan Menu'), istilah: t('Kustomisasi Istilah & Tombol'), pajak: t('Pajak & Biaya Layanan'),
  online: t('Pesanan Online'), konfig: t('Konfigurasi Restoran'), perangkat: t('Perangkat Ini'), banner: t('Banner'), hapus: t('Hapus Data Tenant') });
const items = computed<[string, string][]>(() => settingsFor(role(), S.isMaster).map(k => [k, NAMES()[k]]));
// sub-tab yang tidak boleh diakses peran ini (atau tidak dikenal) → sub-tab pertama yang boleh
watch(items, list => { if (!list.some(x => x[0] === sub.value)) sub.value = list[0]?.[0] || 'perangkat'; }, { immediate: true });
const idx = computed(() => items.value.findIndex(x => x[0] === sub.value));
function onKey(e: KeyboardEvent) {
  const n = items.value.length; let to = -1;
  if (e.key === 'ArrowRight') to = (idx.value + 1) % n; else if (e.key === 'ArrowLeft') to = (idx.value - 1 + n) % n; else if (e.key === 'Home') to = 0; else if (e.key === 'End') to = n - 1;
  if (to < 0) return; e.preventDefault(); openSettings(items.value[to][0]);
  nextTick(() => (document.querySelector('.subtabs [aria-selected="true"]') as HTMLElement | null)?.focus());
}
watch(sub, () => nextTick(() => { const el = document.querySelector('.subtabs [aria-selected="true"]') as HTMLElement | null, c = el?.parentElement; if (el && c && c.scrollWidth > c.clientWidth) c.scrollTo({ left: el.offsetLeft - (c.clientWidth - el.offsetWidth) / 2, behavior: 'smooth' }); }));
</script>
<template>
  <div class="settings">
    <nav v-if="items.length > 1" class="subtabs" role="tablist" :aria-label="t('Pengaturan')" @keydown="onKey">
      <button v-for="x in items" :id="'st-' + x[0]" :key="x[0]" type="button" role="tab" :aria-selected="x[0] === sub" :aria-controls="'sp-' + x[0]" :tabindex="x[0] === sub ? 0 : -1" :class="{ on: x[0] === sub }" @click="openSettings(x[0])">{{ x[1] }}</button>
    </nav>
    <div :id="'sp-' + sub" role="tabpanel" :aria-labelledby="'st-' + sub">
      <RestaurantTab v-if="FORMS.includes(sub)" :key="S.tid + sub" :section="sub" />
      <SiteTab v-else-if="sub === 'situs'" :key="S.tid + 'situs'" />
      <DevicePanel v-else-if="sub === 'perangkat'" />
      <BannersTab v-else-if="sub === 'banner'" :key="S.tid + 'banner'" />
      <PurgePanel v-else-if="sub === 'hapus'" />
    </div>
  </div>
</template>
