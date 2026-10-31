import { createClient } from '@supabase/supabase-js';
export const sb: any = createClient(import.meta.env.PUBLIC_SUPABASE_URL || 'http://localhost', import.meta.env.PUBLIC_SUPABASE_ANON_KEY || 'missing');
const MEDIA: string = import.meta.env.PUBLIC_MEDIA_URL || '';
export const media = (k?: string) => (!k ? '' : k.startsWith('/') || /^https?:/.test(k) ? k : MEDIA.replace(/\/$/, '') + '/' + k);
export const authHeader = async () => ({ authorization: 'Bearer ' + (await sb.auth.getSession()).data.session?.access_token });
