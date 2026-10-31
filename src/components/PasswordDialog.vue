<script setup lang="ts">
import { ref } from 'vue';
import { t } from '../lib/i18n';
import { sb } from '../lib/supabase';
import { usersApi } from '../lib/api';
import { S, toast } from '../store';
import Modal from './Modal.vue';
const m = ref<any>(), target = ref<{ user: string; label: string } | null>(null), p1 = ref(''), p2 = ref(''), msg = ref('');
defineExpose({ open(tg?: { user: string; label: string }) { target.value = tg || null; p1.value = p2.value = msg.value = ''; m.value.open(); } });
async function submit() {
  if (p1.value !== p2.value) return (msg.value = t('Kedua kata sandi tidak sama.'));
  msg.value = t('Menyimpan…');
  try {
    if (!target.value) { const { error } = await sb.auth.updateUser({ password: p1.value }); if (error) throw error; }
    else await usersApi({ action: 'password', tenant_id: S.tid, user_id: target.value.user, password: p1.value });
    m.value.close(); toast(t('Kata sandi diubah'));
  } catch (e: any) { msg.value = e.message || t('Gagal mengubah kata sandi'); }
}
</script>
<template>
  <Modal ref="m"><form @submit.prevent="submit">
    <h3>{{ target ? t('Ubah kata sandi') : t('Ubah kata sandi saya') }}</h3><p v-if="target" class="muted">{{ target.label }}</p>
    <label>{{ t('Kata sandi baru (8–72 karakter)') }}<input v-model="p1" type="password" minlength="8" maxlength="72" required autocomplete="new-password" /></label>
    <label>{{ t('Ulangi kata sandi') }}<input v-model="p2" type="password" minlength="8" maxlength="72" required autocomplete="new-password" /></label>
    <p class="err">{{ msg }}</p><div class="row"><button type="button" class="btn ghost" @click="m.close()">{{ t('Batal') }}</button><button type="submit" class="btn vm">{{ t('Simpan') }}</button></div>
  </form></Modal>
</template>
