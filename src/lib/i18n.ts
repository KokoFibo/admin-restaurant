import { ref } from 'vue';
import { EN } from './admin-en';
/** Bahasa halaman admin: Indonesia (bawaan) & Inggris. */
export const lang = ref<'id' | 'en'>(localStorage.getItem('admin_lang') === 'en' ? 'en' : 'id');
export const t = (id: string, ...a: any[]) => {
  let s = lang.value === 'en' ? EN[id] ?? id : id;
  a.forEach((v, i) => (s = s.split('{' + i + '}').join(String(v))));
  return s;
};
export const applyLang = (l: 'id' | 'en') => { lang.value = l; localStorage.setItem('admin_lang', l); document.documentElement.lang = l; document.title = t('Admin'); };
export const rp = (n: number) => 'Rp ' + Number(n).toLocaleString('id-ID');
