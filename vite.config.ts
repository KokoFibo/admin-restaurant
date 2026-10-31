import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
// Hanya variabel berawalan PUBLIC_ yang masuk ke browser (kunci rahasia tidak berawalan PUBLIC_).
export default defineConfig({ plugins: [vue()], envPrefix: ['PUBLIC_'] });
