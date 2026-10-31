<script setup lang="ts">
import { computed, ref } from 'vue';
import { t } from '../lib/i18n';
import { sb } from '../lib/supabase';
import { usersApi } from '../lib/api';
import { S, ROLE_LABEL, CREATE_ROLES, role, loadMembers, toast } from '../store';
import PasswordDialog from './PasswordDialog.vue';
const pw = ref<any>(), roles = computed(() => CREATE_ROLES[role()] || []);
const f = ref({ email: '', role: roles.value[0], pw: '', exist: false }), msg = ref('');
const call = (action: string, m: any, extra: any = {}) => usersApi({ action, tenant_id: S.tid, user_id: m.user_id, ...extra });
async function add() {
  msg.value = t('Menyimpan…');
  try {
    if (f.value.exist) { const { error } = await sb.rpc('master_link_member', { p_tenant: S.tid, p_email: f.value.email.trim(), p_role: f.value.role }); if (error) throw error; }
    else await usersApi({ action: 'create', tenant_id: S.tid, email: f.value.email.trim(), role: f.value.role, password: f.value.pw });
    toast(t('Akun ditambahkan')); msg.value = ''; f.value.email = f.value.pw = ''; await loadMembers();
  } catch (e: any) { msg.value = e.message; }
}
async function toggle(m: any) {
  const off = m.is_active;
  if (off && !confirm(t('Nonaktifkan {0}? Akun tidak bisa masuk lagi sampai diaktifkan kembali.', m.email) + (m.role === 'owner' ? '\n' + t('Berlaku untuk semua restoran milik akun ini.') : ''))) return;
  try { await call(off ? 'deactivate' : 'activate', m); toast(off ? t('Akun dinonaktifkan') : t('Akun diaktifkan')); loadMembers(); } catch (e: any) { toast(e.message); }
}
async function del(m: any) {
  try {
    let text = t('Hapus akun {0} secara permanen? Tidak bisa dibatalkan. Riwayat pesanan tetap ada.', m.email);
    if (m.role === 'owner') {
      const r = await call('impact', m);
      if (r.sole?.length) return toast(t('Tidak bisa dihapus: {0} satu-satunya owner aktif di {1}. Tambahkan owner pengganti dulu.', m.email, r.sole.join(', ')));
      if ((r.restaurants || []).length > 1) text += '\n' + t('Akun ini juga owner di: {0}.', r.restaurants.join(', '));
    }
    if (!confirm(text)) return;
    await call('delete', m); toast(t('Akun dihapus')); loadMembers();
  } catch (e: any) { toast(e.message); }
}
async function remove(m: any) {
  if (!confirm(t('Cabut akses {0} dari restoran ini? Akunnya tidak dihapus.', m.email))) return;
  const { error } = await sb.rpc('master_remove_member', { p_tenant: S.tid, p_user: m.user_id }); if (error) return toast(error.message); toast(t('Akses dicabut')); loadMembers();
}
</script>
<template>
  <div>
    <div class="panel"><h3>{{ t('Akun restoran') }}</h3>
      <table v-if="S.members.length" class="tbl"><thead><tr><th>Email</th><th>Role</th><th>{{ t('Status') }}</th><th /></tr></thead><tbody>
        <tr v-for="m in S.members" :key="m.user_id" :class="{ dim: !m.is_active }"><td>{{ m.email }}</td><td><span class="rolebadge">{{ ROLE_LABEL[m.role] || m.role }}</span></td>
          <td>{{ m.is_active ? t('Aktif') : t('Nonaktif') }}</td>
          <td style="text-align:right"><template v-if="m.can_reset"><button @click="pw.open({ user: m.user_id, label: m.email })">{{ t('Ubah kata sandi') }}</button> <button @click="toggle(m)">{{ m.is_active ? t('Nonaktifkan') : t('Aktifkan') }}</button> <button class="danger" @click="del(m)">{{ t('Hapus') }}</button> </template>
            <button v-if="S.isMaster" @click="remove(m)">{{ t('Cabut akses') }}</button></td></tr></tbody></table>
      <p v-else class="muted">{{ t('Belum ada akun.') }}</p>
      <p class="hint">{{ t('Hanya Owner yang mengelola akun staf (Manager, Cashier, Kitchen, Service); hanya Super Admin yang mengelola Owner. Kitchen dan Service boleh lebih dari satu orang. Staf hanya boleh di satu restoran.') }}</p></div>
    <form v-if="roles.length" class="panel" @submit.prevent="add"><h3>{{ t('Tambah akun') }}</h3>
      <div class="grid2"><label>Email<input v-model="f.email" type="email" required /></label><label>Role<select v-model="f.role"><option v-for="r in roles" :key="r" :value="r">{{ ROLE_LABEL[r] }}</option></select></label></div>
      <label>{{ t('Kata sandi awal (min. 8 karakter)') }}<input v-model="f.pw" type="text" minlength="8" maxlength="72" autocomplete="new-password" :disabled="f.exist" :required="!f.exist" /></label>
      <label v-if="S.isMaster" class="checks" style="display:flex"><input v-model="f.exist" type="checkbox" /> {{ t('Akun sudah ada (hanya tautkan ke restoran ini, tanpa kata sandi)') }}</label>
      <p class="hint">{{ t('Role yang bisa Anda buat: {0}.', roles.map(r => ROLE_LABEL[r]).join(', ')) }}</p>
      <p class="err">{{ msg }}</p><div class="row"><button class="btn vm" type="submit">{{ t('Tambah akun') }}</button></div></form>
    <PasswordDialog ref="pw" />
  </div>
</template>
