<script setup lang="ts">
import { ref } from 'vue';
import { t, applyLang, lang } from '../lib/i18n';
import { forgotApi } from '../lib/api';
import { login } from '../store';
const email = ref(''), pw = ref(''), msg = ref(''), busy = ref(false), forgot = ref(false), sent = ref(false);
async function submit() { msg.value = ''; busy.value = true; const { error } = await login(email.value, pw.value); busy.value = false; if (error) msg.value = t('Email atau kata sandi salah.'); }
async function sendReset() { busy.value = true; msg.value = ''; await forgotApi(email.value.trim()).catch(() => {}); busy.value = false; sent.value = true; }
</script>
<template>
  <section class="panel box">
    <div class="row" style="justify-content:space-between"><h2>{{ t('Admin Menu') }}</h2>
      <span class="langsw"><button type="button" :class="{ on: lang === 'id' }" @click="applyLang('id')">ID</button><button type="button" :class="{ on: lang === 'en' }" @click="applyLang('en')">EN</button></span></div>
    <template v-if="!forgot">
      <p class="muted">{{ t('Masuk untuk mengelola menu restoran.') }}</p>
      <form @submit.prevent="submit">
        <label><span>Email</span><input v-model="email" type="email" required autocomplete="username" /></label>
        <label><span>{{ t('Kata sandi') }}</span><input v-model="pw" type="password" required autocomplete="current-password" /></label>
        <button class="btn" type="submit" :disabled="busy">{{ t('Masuk') }}</button><p class="err">{{ msg }}</p>
      </form>
      <p class="muted"><a href="#" @click.prevent="forgot = true; sent = false">{{ t('Lupa kata sandi? (khusus Owner)') }}</a></p>
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
