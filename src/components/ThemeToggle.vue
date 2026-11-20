<script setup lang="ts">
import { computed } from 'vue';
import { t } from '../lib/i18n';
import { themePref, resolvedTheme, setTheme } from '../lib/theme';
/** Tombol cepat terang/gelap (selalu terlihat). Pilihan "Otomatis (ikuti perangkat)" tetap ada di menu avatar. */
const dark = computed(() => (themePref.value, resolvedTheme() === 'dark'));
const label = computed(() => (dark.value ? t('Mode terang') : t('Mode gelap')));
const toggle = () => setTheme(dark.value ? 'light' : 'dark');
</script>
<template>
  <button type="button" class="themebtn" :aria-label="label" :title="label" :aria-pressed="dark" @click="toggle">
    <svg v-if="!dark" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z" /></svg>
    <svg v-else viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" /></svg>
  </button>
</template>
