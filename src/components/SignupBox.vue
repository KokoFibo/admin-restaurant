<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { t, applyLang, lang } from '../lib/i18n';
import { slug as slugify } from '../lib/image';
import { sb, media, configured } from '../lib/supabase';
import { TYPES } from '../store';

const emit = defineEmits<{ (e: 'back'): void }>();
const BASE = (import.meta.env.PUBLIC_BASE_DOMAIN || '').replace(/^\./, ''), SITEKEY: string = import.meta.env.PUBLIC_TURNSTILE_SITEKEY || '';
// Tautan dari website pemasaran: admin.<domain>/?brand=Nama&template=aisin#daftar mengisi formulir otomatis.
const q = new URLSearchParams(location.search);
const brand = ref((q.get('brand') || '').slice(0, 80)), slug = ref(slugify(brand.value).slice(0, 40)), slugTouched = ref(false), type = ref('umum'), siteLang = ref('id'), email = ref(''), pw = ref(''), tpl = ref('');
const templates = ref<any[]>([]), msg = ref(''), busy = ref(false), done = ref<any>(null), cfToken = ref('');
const avail = ref<'idle' | 'checking' | 'ok' | 'taken' | 'bad'>('idle');
const preview = computed(() => `${slug.value || 'nama-restoran'}.${BASE || 'domain-anda.com'}`);

onMounted(async () => {
  if (!configured) return;
  const { data } = await sb.from('templates').select('id,name,description,preview_image,restaurant_types').eq('is_active', true).order('sort');
  templates.value = data || []; tpl.value = templates.value.find(x => x.id === q.get('template'))?.id || templates.value[0]?.id || '';
  if (SITEKEY) {                                  // Cloudflare Turnstile (opsional)
    (window as any).__tsDone = (tok: string) => (cfToken.value = tok);
    const s = document.createElement('script'); s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js'; s.async = true; document.head.appendChild(s);
  }
});

watch(brand, v => { if (!slugTouched.value) slug.value = slugify(v).slice(0, 40); });
let timer: any;
watch(slug, v => {
  clearTimeout(timer);
  if (!v) return (avail.value = 'idle');
  if (v.length < 3 || v.length > 40 || !/^[a-z0-9]+(-[a-z0-9]+)*$/.test(v)) return (avail.value = 'bad');
  avail.value = 'checking';
  timer = setTimeout(async () => { const { data, error } = await sb.rpc('slug_available', { p_slug: v }); if (slug.value === v) avail.value = error ? 'idle' : data ? 'ok' : 'taken'; }, 400);
}, { immediate: true });

const ERR: Record<string, string> = {
  slug_taken: 'Alamat itu sudah dipakai. Pilih yang lain.', invalid_slug: 'Alamat tidak valid atau dicadangkan sistem.', email_taken: 'Email ini sudah terdaftar. Silakan masuk.',
  invalid_email: 'Email tidak valid.', invalid_password: 'Kata sandi 8–72 karakter.', invalid_brand: 'Nama restoran 2–80 karakter.', captcha_failed: 'Verifikasi gagal. Muat ulang halaman dan coba lagi.',
  rate_limited: 'Terlalu banyak percobaan. Tunggu beberapa menit lalu coba lagi.', signup_disabled: 'Pendaftaran sedang ditutup.', invalid_template: 'Template tidak tersedia.',
};
async function submit() {
  msg.value = ''; busy.value = true;
  try {
    const r = await fetch('/api/signup', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: email.value.trim(), password: pw.value, brand: brand.value, slug: slug.value, template: tpl.value, type: type.value, lang: siteLang.value, cf_token: cfToken.value }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) msg.value = ERR[j.error] ? t(ERR[j.error]) : t('Pendaftaran gagal. Coba lagi beberapa saat lagi.');
    else done.value = j;
  } catch { msg.value = t('Tidak bisa menghubungi server. Periksa koneksi internet.'); }
  busy.value = false;
}
</script>
<template>
  <section class="panel box wide">
    <div class="row" style="justify-content:space-between"><h2>{{ t('Daftar restoran') }}</h2>
      <span class="langsw"><button type="button" :class="{ on: lang === 'id' }" @click="applyLang('id')">ID</button><button type="button" :class="{ on: lang === 'en' }" @click="applyLang('en')">EN</button></span></div>

    <template v-if="done">
      <p class="hint">{{ done.needs_confirmation ? t('Pendaftaran berhasil. Kami mengirim email konfirmasi; buka tautannya lalu masuk ke admin.') : t('Pendaftaran berhasil. Silakan masuk ke admin.') }}</p>
      <p class="muted">{{ t('Alamat website Anda:') }} <b>{{ done.site_url.replace('https://', '') }}</b></p>
      <button class="btn" type="button" @click="emit('back')">{{ t('Ke halaman masuk') }}</button>
    </template>

    <form v-else @submit.prevent="submit">
      <p class="muted">{{ t('Buat website restoran Anda. Pilih template, isi data dasar, dan mulai kelola menu.') }}</p>
      <p v-if="!configured" class="err">{{ t('Konfigurasi belum lengkap: PUBLIC_SUPABASE_URL / PUBLIC_SUPABASE_ANON_KEY tidak terbaca saat build. Isi di Cloudflare Pages lalu deploy ulang.') }}</p>

      <div v-if="templates.length"><span class="lbl">{{ t('Template') }}</span>
        <div class="tpl-grid"><label v-for="x in templates" :key="x.id" class="tpl" :class="{ on: tpl === x.id }">
          <input type="radio" v-model="tpl" :value="x.id" name="tpl" />
          <img v-if="x.preview_image" :src="media(x.preview_image)" alt="" loading="lazy" /><b>{{ x.name }}</b><small>{{ x.description }}</small>
        </label></div>
      </div>

      <label><span>{{ t('Nama restoran') }}</span><input v-model="brand" required maxlength="80" autocomplete="organization" /></label>
      <label><span>{{ t('Alamat website') }}</span><input v-model="slug" required minlength="3" maxlength="40" pattern="[a-z0-9]+(-[a-z0-9]+)*" autocapitalize="none" spellcheck="false" @input="slugTouched = true" /></label>
      <p class="hint">https://<b>{{ preview }}</b>
        <span v-if="avail === 'checking'"> · {{ t('memeriksa…') }}</span><span v-else-if="avail === 'ok'" class="okk"> · {{ t('tersedia') }}</span>
        <span v-else-if="avail === 'taken'" class="err"> · {{ t('sudah dipakai') }}</span><span v-else-if="avail === 'bad'" class="err"> · {{ t('3–40 huruf kecil, angka, atau tanda hubung') }}</span></p>

      <div class="grid2">
        <label><span>{{ t('Jenis restoran') }}</span><select v-model="type"><option v-for="(n, k) in TYPES" :key="k" :value="k">{{ n }}</option></select></label>
        <label><span>{{ t('Bahasa utama website') }}</span><select v-model="siteLang"><option value="id">Bahasa Indonesia</option><option value="en">English</option><option value="zh">简体中文</option></select></label>
      </div>
      <label><span>Email</span><input v-model="email" type="email" required autocomplete="username" /></label>
      <label><span>{{ t('Kata sandi') }}</span><input v-model="pw" type="password" required minlength="8" maxlength="72" autocomplete="new-password" /></label>
      <div v-if="SITEKEY" class="cf-turnstile" :data-sitekey="SITEKEY" data-callback="__tsDone"></div>
      <button class="btn" type="submit" :disabled="busy || avail === 'taken' || avail === 'bad' || !configured">{{ t('Daftar') }}</button><p class="err">{{ msg }}</p>
      <p class="muted"><a href="#" @click.prevent="emit('back')">{{ t('← Sudah punya akun? Masuk') }}</a></p>
    </form>
  </section>
</template>
<style scoped>
.wide { max-width: 40rem; margin-top: 5vh; }
.lbl { font-size: .8rem; font-weight: 600; color: var(--jade); display: block; margin-bottom: .4rem; }
.tpl-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(11rem, 1fr)); gap: .75rem; }
.tpl { display: grid; gap: .25rem; padding: .6rem; border: 1px solid var(--line); border-radius: 6px; cursor: pointer; font-weight: 400; color: var(--ink); }
.tpl.on { border-color: var(--jade); box-shadow: 0 0 0 2px var(--jade) inset; }
.tpl input { position: absolute; opacity: 0; pointer-events: none; }
.tpl img { width: 100%; aspect-ratio: 16/10; object-fit: cover; border-radius: 4px; }
.tpl small { color: var(--ink2); font-size: .75rem; }
.okk { color: var(--jade); }
</style>
