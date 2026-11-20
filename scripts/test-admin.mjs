// Uji logika admin tanpa browser: dialog kustom, sub-tab Pengaturan per peran, tak ada dialog bawaan browser, kelengkapan terjemahan EN.
import { build } from 'esbuild';
import { readFileSync, readdirSync, statSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
let pass = 0, fail = 0; const ok = (n, c, x = '') => { c ? pass++ : fail++; console.log(c ? '  ✔' : '  ✘', n, c ? '' : x); };
const bundle = async f => { const d = mkdtempSync(join(tmpdir(), 'ta-')), o = join(d, 'm.mjs'); writeFileSync(o, (await build({ entryPoints: [f], bundle: true, format: 'esm', write: false, target: 'es2022', external: ['vue'] })).outputFiles[0].text.replace(/from "vue"/g, `from "${pathToFileURL(join(process.cwd(), 'node_modules/vue/index.mjs')).href}"`)); return import(pathToFileURL(o).href); };
const walk = d => readdirSync(d).flatMap(f => { const p = join(d, f); return statSync(p).isDirectory() ? walk(p) : [p]; });
const src = walk('src').filter(f => /\.(vue|ts)$/.test(f));

console.log('\n[1] tidak ada dialog bawaan browser');
{
  const bad = [];
  const noComments = t => t.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|\s)\/\/.*$/gm, '$1');   // komentar boleh menyebut confirm()/prompt()
  for (const f of src) { const s = noComments(readFileSync(f, 'utf8')); for (const m of s.matchAll(/(^|[^.\w])(confirm|prompt|alert)\(/g)) bad.push(f + ': ' + m[2] + '('); for (const m of s.matchAll(/window\.(confirm|prompt|alert)\(/g)) bad.push(f + ': window.' + m[1]); }
  ok('tidak ada confirm()/prompt()/alert() di src (e.prompt() milik PWA install dikecualikan)', bad.length === 0, bad.join(', '));
  ok('DialogHost terpasang di App.vue', /<DialogHost\s*\/>/.test(readFileSync('src/App.vue', 'utf8')));
}

console.log('\n[2] dialog kustom (lib/dialog.ts)');
{
  const { askConfirm, askPrompt, settleDialog, dlg } = await bundle('src/lib/dialog.ts');
  const tick = () => new Promise(r => setTimeout(r, 0));
  let p = askConfirm('Hapus?', { danger: true, title: 'Konfirmasi', ok: 'Hapus' }); await tick();
  ok('confirm: dialog terbuka dengan pesan, judul, tombol, mode bahaya', dlg.open && dlg.kind === 'confirm' && dlg.message === 'Hapus?' && dlg.danger && dlg.ok === 'Hapus');
  settleDialog(true); ok('OK → true, dialog tertutup', (await p) === true && !dlg.open);
  p = askConfirm('Lanjut?'); await tick(); settleDialog(false); ok('Batal/Esc → false', (await p) === false && !dlg.open);
  p = askPrompt('Alasan?', { placeholder: 'opsional', value: 'awal' }); await tick();
  ok('prompt: isian awal & placeholder', dlg.kind === 'prompt' && dlg.input === 'awal' && dlg.placeholder === 'opsional');
  dlg.input = 'stok habis'; settleDialog(true); ok('prompt OK → teks isian', (await p) === 'stok habis');
  p = askPrompt('Alasan?'); await tick(); settleDialog(true); ok('prompt OK tanpa isi → string kosong (bukan null: "tanpa alasan" tetap lanjut)', (await p) === '');
  p = askPrompt('Alasan?'); await tick(); dlg.input = 'abaikan'; settleDialog(false); ok('prompt batal → null', (await p) === null);
  // antrean: dua panggilan serempak tidak saling menimpa
  const a = askConfirm('A'), b = askConfirm('B'); await tick();
  ok('antrean: yang kedua menunggu', dlg.message === 'A'); settleDialog(true); await tick();
  ok('antrean: setelah yang pertama selesai, yang kedua tampil', dlg.open && dlg.message === 'B' && (await a) === true); settleDialog(false); ok('antrean: jawaban masing-masing benar', (await b) === false);
  ok('opsi bawaan dibersihkan antar-dialog (danger tidak "menempel")', (askConfirm('C'), await tick(), dlg.danger === false)); settleDialog(false);
}

console.log('\n[3] sub-tab Pengaturan per peran (lib/settings.ts)');
{
  const { settingsFor } = await bundle('src/lib/settings.ts');
  const OWNER = ['profil', 'situs', 'menu', 'istilah', 'pajak', 'online', 'konfig', 'perangkat', 'banner'];
  ok('Owner: urutan persis seperti permintaan (tanpa Hapus Data Tenant)', JSON.stringify(settingsFor('owner', false)) === JSON.stringify(OWNER), settingsFor('owner', false).join(','));
  ok('Super Admin: sama + Hapus Data Tenant paling akhir', JSON.stringify(settingsFor('super_admin', true)) === JSON.stringify([...OWNER, 'hapus']), settingsFor('super_admin', true).join(','));
  ok('Konfigurasi Restoran tersedia untuk Owner (bukan hanya Super Admin)', settingsFor('owner', false).includes('konfig'));
  ok('Manager: Perangkat Ini dan Banner saja', JSON.stringify(settingsFor('manager', false)) === JSON.stringify(['perangkat', 'banner']));
  for (const r of ['cashier', 'kitchen', 'service']) ok(`${r}: hanya Perangkat Ini`, JSON.stringify(settingsFor(r, false)) === JSON.stringify(['perangkat']));
  ok('Hapus Data Tenant tidak muncul untuk Owner biasa', !settingsFor('owner', false).includes('hapus'));
  ok('Tampilan Website & Banner tidak lagi tab utama (Shell)', !/\['site',|\['banner',/.test(readFileSync('src/components/Shell.vue', 'utf8')));
}

console.log('\n[4] terjemahan EN lengkap');
{
  const en = readFileSync('src/lib/admin-en.ts', 'utf8'), have = new Set();
  for (const m of en.matchAll(/^\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)')\s*:/gm)) have.add((m[1] ?? m[2]).replace(/\\"/g, '"').replace(/\\'/g, "'").replace(/\\\\/g, '\\'));
  const miss = new Set();
  for (const f of src) { if (f.endsWith('admin-en.ts')) continue; for (const m of readFileSync(f, 'utf8').matchAll(/\bt\(\s*'((?:[^'\\]|\\.)*)'/g)) { const k = m[1].replace(/\\'/g, "'").replace(/\\\\/g, '\\'); if (!have.has(k) && !k.includes('&quot;')) miss.add(k); } }
  ok('semua teks t() punya terjemahan Inggris', miss.size === 0, [...miss].slice(0, 5).join(' | '));
}
console.log(`\nHasil: ${pass} lulus, ${fail} gagal`); process.exit(fail ? 1 : 0);
