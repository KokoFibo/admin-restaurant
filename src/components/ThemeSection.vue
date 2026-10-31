<script setup lang="ts">
import { computed, reactive, ref } from 'vue';
import { t } from '../lib/i18n';
import { sb } from '../lib/supabase';
import { PRESETS, OWNER_BGS, contrast, derive, isHex } from '../lib/themes';
import { S, toast, load } from '../store';
const T = S.T, cur = PRESETS.find(p => p.id === (T.theme === 'custom' ? 'giok' : T.theme)) || PRESETS[0];
const sel = ref<string>(T.theme || 'giok'), dark = ref<boolean>(!!T.theme_dark), msg = ref(''), saving = ref(false);
const c = reactive({ primary: T.theme_custom?.primary || cur.primary, accent: T.theme_custom?.accent || cur.accent, bg: T.theme_custom?.bg || cur.bg });
const preset = computed(() => PRESETS.find(p => p.id === sel.value));
const colors = computed(() => (sel.value === 'custom' ? derive(c.primary, c.accent, c.bg, dark.value) : { ...preset.value!, ink: '#1E2621' }));
const issue = computed(() => {
  if (sel.value !== 'custom') return '';
  if (![c.primary, c.accent, c.bg].every(isHex)) return t('Format warna harus #RRGGBB.');
  if (contrast(c.primary, c.bg) < 4.5) return t('Warna utama kurang kontras terhadap warna dasar (minimal 4,5:1).');
  if (contrast('#FFFFFF', c.accent) < 4.5) return t('Warna aksen terlalu terang untuk teks putih pada tombol (minimal 4,5:1).');
  return '';
});
const locked = !S.isMaster && !!T.theme_dark;   // latar gelap diatur Super Admin; Owner tidak bisa mengubah sampai Super Admin menonaktifkannya
function toggleDark() { sel.value = 'custom'; if (dark.value) { c.bg = '#14201A'; c.primary = '#E8D9A8'; } else { c.bg = cur.bg; c.primary = cur.primary; } }
async function save(reset = false) {
  saving.value = true; msg.value = '';
  const theme = reset ? 'giok' : sel.value, p: any = { p_tenant: S.tid, p_theme: theme, p_custom: theme === 'custom' ? { primary: c.primary.toUpperCase(), accent: c.accent.toUpperCase(), bg: c.bg.toUpperCase() } : null };
  if (S.isMaster) p.p_dark = reset ? false : theme === 'custom' ? dark.value : false;
  const { error } = await sb.rpc('set_tenant_theme', p); saving.value = false;
  if (error) return (msg.value = error.message);
  if (reset) { sel.value = 'giok'; dark.value = false; }
  toast(t('Warna disimpan')); load();
}
</script>
<template>
  <div class="panel">
    <h3>{{ t('Warna website') }}</h3>
    <p class="hint">{{ t('Pilih skema warna, atau atur warna sendiri. Warna lain dihitung otomatis, dan kombinasi yang membuat teks sulit dibaca ditolak.') }}</p>
    <div class="themes">
      <button v-for="p in PRESETS" :key="p.id" type="button" class="theme" :class="{ on: sel === p.id }" @click="sel = p.id; dark = false">
        <span class="tsw"><i :style="{ background: p.primary }" /><i :style="{ background: p.secondary }" /><i :style="{ background: p.accent }" /><i :style="{ background: p.bg }" /></span>{{ t(p.name) }}</button>
      <button type="button" class="theme" :class="{ on: sel === 'custom' }" @click="sel = 'custom'"><span class="tsw"><i :style="{ background: c.primary }" /><i :style="{ background: c.accent }" /><i :style="{ background: c.bg }" /></span>{{ t('Warna sendiri') }}</button>
    </div>
    <fieldset v-if="sel === 'custom'"><legend>{{ t('Warna sendiri') }}</legend>
      <div class="grid2">
        <label>{{ t('Warna utama (judul)') }}<span class="row"><input v-model="c.primary" type="color" style="width:3rem;padding:0" /><input v-model="c.primary" maxlength="7" /></span></label>
        <label>{{ t('Warna aksen (tombol)') }}<span class="row"><input v-model="c.accent" type="color" style="width:3rem;padding:0" /><input v-model="c.accent" maxlength="7" /></span></label>
      </div>
      <label v-if="S.isMaster">{{ t('Warna dasar (latar)') }}<span class="row"><input v-model="c.bg" type="color" style="width:3rem;padding:0" /><input v-model="c.bg" maxlength="7" /></span></label>
      <div v-else><span class="muted">{{ t('Warna dasar (latar)') }}</span>
        <div class="themes"><button v-for="b in OWNER_BGS" :key="b[1]" type="button" class="theme" :class="{ on: c.bg.toUpperCase() === b[1] }" @click="c.bg = b[1]"><span class="tsw"><i :style="{ background: b[1] }" /></span>{{ t(b[0]) }}</button></div></div>
      <label v-if="S.isMaster" class="checks" style="display:flex"><input v-model="dark" type="checkbox" @change="toggleDark" /> {{ t('Latar gelap (khusus Super Admin)') }}</label>
    </fieldset>
    <div class="tprev" :style="{ background: colors.bg, color: colors.ink }">
      <b :style="{ color: colors.primary, fontFamily: 'var(--serif)', fontSize: '1.15rem' }">{{ t('Pratinjau: Kembali ke kemurnian') }}</b>
      <span :style="{ color: colors.secondary, fontSize: '.8rem' }">{{ t('Nikmati hidangan nabati') }}</span>
      <span class="row"><span class="tbtn" :style="{ background: colors.accent }">{{ t('Pesan sekarang') }}</span><span class="tchip" :style="{ background: colors.bg2, color: colors.primary }">{{ t('100% vegetarian') }}</span></span>
    </div>
    <p v-if="locked" class="hint">{{ t('Website ini memakai latar gelap yang diatur Super Admin. Hubungi Super Admin untuk mengubah warna.') }}</p>
    <p class="err">{{ issue || msg }}</p>
    <div class="row"><button type="button" class="btn vm" :disabled="locked || saving || !!issue" @click="save()">{{ t('Simpan warna') }}</button><button type="button" class="btn ghost" :disabled="locked || saving" @click="save(true)">{{ t('Kembalikan ke bawaan') }}</button></div>
  </div>
</template>
