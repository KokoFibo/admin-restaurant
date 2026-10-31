<script setup lang="ts">
import { ref } from 'vue';
import { t } from '../lib/i18n';
import { sb } from '../lib/supabase';
import { endRecovery, toast } from '../store';
const p1 = ref(''), p2 = ref(''), msg = ref('');
async function submit() {
  if (p1.value !== p2.value) return (msg.value = t('Kedua kata sandi tidak sama.'));
  const { error } = await sb.auth.updateUser({ password: p1.value }); if (error) return (msg.value = error.message);
  toast(t('Kata sandi diubah')); endRecovery();
}
</script>
<template>
  <section class="panel box"><h2>{{ t('Buat kata sandi baru') }}</h2>
    <form @submit.prevent="submit">
      <label>{{ t('Kata sandi baru (8–72 karakter)') }}<input v-model="p1" type="password" minlength="8" maxlength="72" required autocomplete="new-password" /></label>
      <label>{{ t('Ulangi kata sandi') }}<input v-model="p2" type="password" minlength="8" maxlength="72" required autocomplete="new-password" /></label>
      <p class="err">{{ msg }}</p><button class="btn" type="submit">{{ t('Simpan') }}</button></form></section>
</template>
