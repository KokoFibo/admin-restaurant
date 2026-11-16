<script setup lang="ts">
import { nextTick, ref, shallowRef } from 'vue';
import { t } from '../lib/i18n';
import { sb } from '../lib/supabase';
import { uploadAvatar, deleteAvatar } from '../lib/api';
import { drawPreview, toWebp } from '../lib/image';
import { S, toast } from '../store';
import Modal from './Modal.vue';

const m = ref<any>(), cv = ref<HTMLCanvasElement>(), px = ref(50), py = ref(50), msg = ref(''), busy = ref(false);
const img = shallowRef<HTMLImageElement | null>(null);
defineExpose({ open() { img.value = null; px.value = py.value = 50; msg.value = ''; m.value.open(); } });
function pick(ev: Event) {
  const f = (ev.target as HTMLInputElement).files?.[0]; if (!f) return;
  if (!/^image\//.test(f.type)) return (msg.value = t('Pilih berkas gambar.'));
  const i = new Image(), url = URL.createObjectURL(f);
  i.onload = async () => { URL.revokeObjectURL(url); img.value = i; msg.value = ''; await nextTick(); draw(); };
  i.onerror = () => { URL.revokeObjectURL(url); msg.value = t('Gambar tidak bisa dibaca.'); }; i.src = url;
}
const draw = () => { if (img.value && cv.value) drawPreview(img.value, cv.value, px.value, py.value, 1); };
async function save() {
  if (!img.value) return (msg.value = t('Pilih foto dulu.'));
  busy.value = true; msg.value = t('Menyimpan…');
  try {
    const old = S.avatar, key = await uploadAvatar(await toWebp(img.value, px.value, py.value, { ratio: 1, width: 256, maxBytes: 40 * 1024 }));
    const { error } = await sb.auth.updateUser({ data: { avatar_key: key } }); if (error) throw error;
    S.avatar = key; if (old) deleteAvatar(old); m.value.close(); toast(t('Foto profil diperbarui'));
  } catch (e: any) { msg.value = e.message || t('Gagal mengunggah foto'); } finally { busy.value = false; }
}
async function remove() {
  busy.value = true; msg.value = t('Menyimpan…');
  try { const old = S.avatar, { error } = await sb.auth.updateUser({ data: { avatar_key: null } }); if (error) throw error; S.avatar = ''; if (old) deleteAvatar(old); m.value.close(); toast(t('Foto profil dihapus')); }
  catch (e: any) { msg.value = e.message || t('Gagal menghapus foto'); } finally { busy.value = false; }
}
</script>
<template>
  <Modal ref="m"><form @submit.prevent="save">
    <h3>{{ t('Ubah foto profil') }}</h3>
    <label>{{ t('Pilih foto') }}<input type="file" accept="image/*" @change="pick" /></label>
    <div v-if="img" class="avprev"><canvas ref="cv" width="256" height="256" />
      <div style="display:grid;gap:.5rem;flex:1;min-width:10rem"><label>{{ t('Geser kiri–kanan') }}<input v-model.number="px" type="range" min="0" max="100" @input="draw" /></label><label>{{ t('Geser atas–bawah') }}<input v-model.number="py" type="range" min="0" max="100" @input="draw" /></label></div></div>
    <p class="hint">{{ t('Foto dipotong persegi dan dikecilkan otomatis. Foto profil hanya untuk akun Anda.') }}</p>
    <p class="err" role="status">{{ msg }}</p>
    <div class="row"><button v-if="S.avatar" type="button" class="btn ghost" :disabled="busy" @click="remove">{{ t('Hapus foto') }}</button><button type="button" class="btn ghost" @click="m.close()">{{ t('Batal') }}</button><button type="submit" class="btn vm" :disabled="busy || !img">{{ t('Simpan') }}</button></div>
  </form></Modal>
</template>
