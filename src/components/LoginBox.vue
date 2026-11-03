<script setup lang="ts">
import { ref } from 'vue';
import { t, applyLang, lang } from '../lib/i18n';
import { forgotApi } from '../lib/api';
import { login } from '../store';
import { configured } from '../lib/supabase';
const email = ref(''), pw = ref(''), msg = ref(''), busy = ref(false), forgot = ref(false), sent = ref(false);
/** Pesan login menurut penyebab sebenarnya (kesalahan teknis tidak lagi disamarkan sebagai "kata sandi salah"). */
function reason(e: any): string {
  const code = String(e?.code || ''), m = String(e?.message || '');
  if (code === 'invalid_credentials' || /invalid login credentials/i.test(m)) return t('Email atau kata sandi salah.');
  if (code === 'email_not_confirmed') return t('Email belum dikonfirmasi. Minta Super Admin mengonfirmasi akun ini di Supabase.');
  if (code === 'user_banned' || /banned/i.test(m)) return t('Akun ini dinonaktifkan. Hubungi Owner atau pengelola layanan.');
  if (code === 'email_provider_disabled' || /provider.*disabled/i.test(m)) return t('Login email dinonaktifkan di Supabase (Authentication → Providers → Email).');
  if (e?.status === 429 || code === 'over_request_rate_limit') return t('Terlalu banyak percobaan. Tunggu beberapa menit lalu coba lagi.');
  if (e?.name === 'AuthRetryableFetchError' || /fetch|network/i.test(m)) return t('Tidak bisa menghubungi server login. Periksa PUBLIC_SUPABASE_URL dan koneksi internet.');
  if (/api key|apikey|jwt/i.test(m)) return t('Kunci Supabase (PUBLIC_SUPABASE_ANON_KEY) tidak valid. Gunakan anon/publishable key, bukan service_role.');
  return t('Gagal masuk: {0}', code || m || 'unknown');
}
async function submit() {
  msg.value = ''; if (!configured) return (msg.value = t('Konfigurasi belum lengkap: PUBLIC_SUPABASE_URL / PUBLIC_SUPABASE_ANON_KEY tidak terbaca saat build. Isi di Cloudflare Pages lalu deploy ulang.'));
  busy.value = true; const { error } = await login(email.value.trim(), pw.value); busy.value = false;
  if (error) { console.warn('[login]', error.status, error.code, error.message); msg.value = reason(error); }
}
async function sendReset() { busy.value = true; msg.value = ''; await forgotApi(email.value.trim()).catch(() => {}); busy.value = false; sent.value = true; }
</script>
<template>
  <section class="panel box">
    <div class="row" style="justify-content:space-between"><h2>{{ t('Admin Menu') }}</h2>
      <span class="langsw"><button type="button" :class="{ on: lang === 'id' }" @click="applyLang('id')">ID</button><button type="button" :class="{ on: lang === 'en' }" @click="applyLang('en')">EN</button></span></div>
    <template v-if="!forgot">
      <p class="muted">{{ t('Masuk untuk mengelola menu restoran.') }}</p>
      <p v-if="!configured" class="err">{{ t('Konfigurasi belum lengkap: PUBLIC_SUPABASE_URL / PUBLIC_SUPABASE_ANON_KEY tidak terbaca saat build. Isi di Cloudflare Pages lalu deploy ulang.') }}</p>
      <form @submit.prevent="submit">
        <label><span>Email</span><input v-model="email" type="email" required autocomplete="username" /></label>
        <label><span>{{ t('Kata sandi') }}</span><input v-model="pw" type="password" required autocomplete="current-password" /></label>
        <button class="btn" type="submit" :disabled="busy">{{ t('Masuk') }}</button><p class="err">{{ msg }}</p>
      </form>
      <p class="muted"><a href="#" @click.prevent="forgot = true; sent = false">{{ t('Lupa kata sandi? (khusus Owner)') }}</a></p>
      <p class="muted"><a href="#daftar">{{ t('Belum punya restoran? Daftar') }}</a></p>
    </template>
    <template v-else>
      <p class="muted">{{ t('Khusus Owner. Masukkan email Anda; jika terdaftar sebagai Owner, tautan untuk membuat kata sandi baru akan dikirim. Staf yang lupa kata sandi: minta Owner restoran untuk meresetnya.') }}</p>
      <form v-if="!sent" @submit.prevent="sendReset"><label><span>Email</span><input v-model="email" type="email" required autocomplete="username" /></label>
        <button class="btn" type="submit" :disabled="busy">{{ t('Kirim tautan') }}</button></form>
      <p v-else class="hint">{{ t('Jika email itu terdaftar sebagai Owner, tautan reset sudah dikirim. Periksa kotak masuk dan spam.') }}</p>
      <p class="muted"><a href="#" @click.prevent="forgot = false">{{ t('← Kembali masuk') }}</a></p>
    </template>
  </section>
</template>
