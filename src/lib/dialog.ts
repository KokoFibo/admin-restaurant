import { reactive } from 'vue';

/**
 * Dialog konfirmasi / isian KUSTOM (pengganti confirm() & prompt() bawaan browser). Dipakai: `if (!(await askConfirm('…', { danger: true }))) return;`
 * dan `const alasan = await askPrompt('…'); if (alasan === null) return;`. Dirender oleh <DialogHost /> (satu di App.vue).
 * Beberapa panggilan serempak diantrekan (satu dialog pada satu waktu).
 */
export type DialogOpts = { title?: string; ok?: string; cancel?: string; danger?: boolean };
export type PromptOpts = DialogOpts & { placeholder?: string; value?: string };

export const dlg = reactive({ open: false, kind: 'confirm' as 'confirm' | 'prompt', message: '', title: '', ok: '', cancel: '', danger: false, placeholder: '', input: '' });
let resolver: ((v: any) => void) | null = null;
let chain: Promise<unknown> = Promise.resolve();

function show(kind: 'confirm' | 'prompt', message: string, o: PromptOpts = {}): Promise<any> {
  const run = () => new Promise<any>(resolve => {
    resolver = resolve;
    Object.assign(dlg, { open: true, kind, message, title: o.title ?? '', ok: o.ok ?? '', cancel: o.cancel ?? '', danger: !!o.danger, placeholder: o.placeholder ?? '', input: o.value ?? '' });
  });
  const p = chain.then(run, run);
  chain = p.catch(() => {});
  return p;
}
/** true = lanjut, false = batal (Esc / klik di luar / tombol Batal). */
export const askConfirm = (message: string, o?: DialogOpts): Promise<boolean> => show('confirm', message, o);
/** Teks isian (boleh kosong), atau null bila dibatalkan. */
export const askPrompt = (message: string, o?: PromptOpts): Promise<string | null> => show('prompt', message, o);

/** Dipanggil <DialogHost />: menutup dialog dan menyelesaikan janji. */
export function settleDialog(accepted: boolean) {
  const r = resolver; resolver = null;
  const value = dlg.kind === 'prompt' ? (accepted ? dlg.input : null) : accepted;
  dlg.open = false;
  r?.(value);
}
