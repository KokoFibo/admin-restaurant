import { defineConfig, type Plugin } from 'vite';
import vue from '@vitejs/plugin-vue';

// Penanda versi build: dipakai halaman untuk mendeteksi versi baru (version.json) tanpa memuat ulang sendiri.
const BUILD_ID = ((process.env.CF_PAGES_COMMIT_SHA || process.env.WORKERS_CI_COMMIT_SHA || '').slice(0, 8) + '-' + Date.now().toString(36)).replace(/^-/, '');
const versionFile = (): Plugin => ({ name: 'version-file', generateBundle() { this.emitFile({ type: 'asset', fileName: 'version.json', source: JSON.stringify({ id: BUILD_ID }) }); } });

// Hanya variabel berawalan PUBLIC_ yang masuk ke browser (kunci rahasia tidak berawalan PUBLIC_).
export default defineConfig({ plugins: [vue(), versionFile()], envPrefix: ['PUBLIC_'], define: { __BUILD_ID__: JSON.stringify(BUILD_ID) } });
