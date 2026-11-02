import { defineConfig } from 'astro/config';
import cloudflare from '@astrojs/cloudflare';

// SSR di Cloudflare Workers: restoran ditentukan dari hostname yang dibuka (tenant_domains), template dari site.template_id.
export default defineConfig({ output: 'server', adapter: cloudflare({ platformProxy: { enabled: true } }) });
