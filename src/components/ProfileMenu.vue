<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';
import { t } from '../lib/i18n';
import { media } from '../lib/supabase';
import { S, ROLE_LABEL, role, logout, toast, installEvt, isStandalone, isIOS } from '../store';
import { themePref, setTheme, type ThemePref } from '../lib/theme';

const emit = defineEmits<{ (e: 'password'): void; (e: 'avatar'): void }>();
const open = ref(false), root = ref<HTMLElement>(), btn = ref<HTMLButtonElement>();
const avatar = computed(() => (S.avatar ? media(S.avatar) : ''));
const initial = computed(() => (S.email || '?').trim().charAt(0).toUpperCase());
const canInstall = computed(() => !isStandalone() && (!!installEvt.value || isIOS()));
const THEMES = (): [ThemePref, string][] => [['system', t('Otomatis')], ['light', t('Terang')], ['dark', t('Gelap')]];
const close = (focus = false) => { open.value = false; if (focus) btn.value?.focus(); };
const pick = (fn: () => void) => { close(); fn(); };
async function install() {
  const e = installEvt.value; close();
  if (e) { e.prompt(); await e.userChoice.catch(() => {}); installEvt.value = null; }
  else toast(t('Di iPhone/iPad: ketuk tombol Bagikan, lalu pilih "Tambahkan ke Layar Utama".'));
}
const onDoc = (ev: Event) => { if (open.value && root.value && !root.value.contains(ev.target as Node)) close(); };
const onKey = (ev: KeyboardEvent) => { if (open.value && ev.key === 'Escape') close(true); };
onMounted(() => { document.addEventListener('click', onDoc); document.addEventListener('keydown', onKey); });
onBeforeUnmount(() => { document.removeEventListener('click', onDoc); document.removeEventListener('keydown', onKey); });
</script>
<template>
  <div ref="root" class="pm">
    <button ref="btn" type="button" class="pm-btn" :aria-expanded="open" aria-haspopup="menu" :aria-label="t('Menu profil')" @click="open = !open"><img v-if="avatar" :src="avatar" alt="" /><span v-else>{{ initial }}</span></button>
    <div v-if="open" class="pm-pop" role="menu" :aria-label="t('Menu profil')">
      <div class="pm-head"><span class="av"><img v-if="avatar" :src="avatar" alt="" /><span v-else>{{ initial }}</span></span>
        <div><b>{{ S.email }}</b><span v-if="S.T || S.isMaster" class="rolebadge">{{ ROLE_LABEL[role()] || t('Tanpa role') }}</span></div></div>
      <div class="pm-lbl" id="pm-theme">{{ t('Tampilan') }}</div>
      <div class="pm-seg" role="group" aria-labelledby="pm-theme"><button v-for="x in THEMES()" :key="x[0]" type="button" :class="{ on: themePref === x[0] }" :aria-pressed="themePref === x[0]" @click="setTheme(x[0])">{{ x[1] }}</button></div>
      <div class="pm-sep" />
      <button type="button" class="pm-item" role="menuitem" @click="pick(() => emit('avatar'))">{{ t('Ubah foto profil') }}</button>
      <button type="button" class="pm-item" role="menuitem" @click="pick(() => emit('password'))">{{ t('Ubah kata sandi') }}</button>
      <button v-if="canInstall" type="button" class="pm-item" role="menuitem" @click="install">{{ t('Pasang aplikasi') }}</button>
      <div class="pm-sep" />
      <button type="button" class="pm-item out" role="menuitem" @click="logout()">{{ t('Keluar') }}</button>
    </div>
  </div>
</template>
