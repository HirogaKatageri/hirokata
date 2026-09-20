# Adapter configuration detail

Per-adapter setup, once the overview table in the main skill has picked one.

## `adapter-node`

Outputs a standalone Node app:

```js
import adapter from '@sveltejs/adapter-node';
export default { kit: { adapter: adapter({ out: 'build' }) } };
```

Run with `node build`. Configurable env vars: `PORT`, `HOST`, `ORIGIN`, `BODY_SIZE_LIMIT`. Behind a reverse proxy, set `ORIGIN` to the public URL so SvelteKit knows the canonical host.

## `adapter-static`

Pure static output:

```js
import adapter from '@sveltejs/adapter-static';
export default {
  kit: {
    adapter: adapter({
      pages: 'build',
      assets: 'build',
      fallback: undefined,   // 'index.html' or '200.html' for SPA mode
      precompress: false
    })
  }
};
```

Every page must have `prerender = true` (or be reachable via prerendering). For SPA mode, set `fallback: '200.html'` and `ssr = false` at the root layout.

## Cloudflare / Vercel / Netlify

Each platform-specific adapter wires up the platform's serverless or edge runtime. For Cloudflare, server `event.platform.env` exposes bindings (KV, D1, R2). For Vercel, `export const config = { runtime: 'edge' }` opts a route into the edge runtime. For Netlify, edge functions are similar via the `edge: true` option.
