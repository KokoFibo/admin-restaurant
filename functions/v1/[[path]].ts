import { json } from '../../server/v1';
/** Semua alamat /v1/* lain → 404 JSON (supaya tidak jatuh ke halaman admin). */
export const onRequest = () => json({ error: 'not_found' }, 404);
