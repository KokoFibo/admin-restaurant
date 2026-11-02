import { createClient } from '@supabase/supabase-js';
const SB_URL: string = import.meta.env.PUBLIC_SUPABASE_URL || '', SB_KEY: string = import.meta.env.PUBLIC_SUPABASE_ANON_KEY || '';
/** false = variabel PUBLIC_SUPABASE_* tidak ikut terbawa saat build (harus diisi SEBELUM build, lalu deploy ulang). */
export const configured = /^https?:\/\//.test(SB_URL) && SB_KEY.length > 20;
export const sb: any = createClient(configured ? SB_URL : 'http://localhost', configured ? SB_KEY : 'missing');
const MEDIA: string = import.meta.env.PUBLIC_MEDIA_URL || '';
export const media = (k?: string) => (!k ? '' : k.startsWith('/') || /^https?:/.test(k) ? k : MEDIA.replace(/\/$/, '') + '/' + k);
export const authHeader = async () => ({ authorization: 'Bearer ' + (await sb.auth.getSession()).data.session?.access_token });
