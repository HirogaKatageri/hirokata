---
name: svelte-build-deploy
description: >
  Pre-loaded SvelteKit knowledge for the developer-svelte agent. Covers
  project structure, file-based routing (+page, +layout, +server, +error),
  load functions (universal vs server), form actions, page options
  (prerender / ssr / csr), building for production, and deployment via
  adapters (auto, node, static, vercel, cloudflare, netlify). Load this
  skill before working on any SvelteKit route, server module, or build
  configuration. Trigger phrases include "sveltekit routing", "+page",
  "+server", "load function", "form actions", "sveltekit adapter",
  "svelte deploy".
version: 1.0.0
---

# SvelteKit — Build & Deploy

Authoritative reference for working in SvelteKit projects: project layout, routing, data loading, mutations, and getting an app to production.

## Project Structure

```
my-app/
├─ src/
│  ├─ lib/                   # $lib alias — shared modules
│  │  └─ server/             # $lib/server — server-only code
│  ├─ params/                # custom param matchers
│  ├─ routes/                # filesystem routes (root)
│  ├─ app.html               # HTML shell
│  ├─ error.html             # static fallback error page
│  ├─ hooks.server.ts        # server hooks
│  ├─ hooks.client.ts        # client hooks
│  └─ hooks.ts               # shared (universal) hooks
├─ static/                   # served verbatim at /
├─ tests/
├─ svelte.config.js          # Kit + adapter config
├─ vite.config.ts
├─ tsconfig.json
└─ package.json
```

Key path aliases:
- `$lib` → `src/lib`
- `$lib/server/*` → server-only; importing from client code is a build error
- `$app/*` → SvelteKit runtime modules
- `$env/static/private`, `$env/static/public`, `$env/dynamic/*` → environment variables

## File-based Routing

Inside `src/routes/`, each directory is a URL segment. Files prefixed with `+` are route files:

| File | Role |
|------|------|
| `+page.svelte` | Page UI |
| `+page.ts` | Universal `load` (runs server + client) |
| `+page.server.ts` | Server `load` and form `actions` |
| `+layout.svelte` | Wraps child pages; renders `{@render children()}` |
| `+layout.ts` / `+layout.server.ts` | Layout-level `load` |
| `+error.svelte` | Error boundary |
| `+server.ts` | API endpoint (HTTP method exports) |

Dynamic segments use brackets:
- `[slug]` — required parameter
- `[[slug]]` — optional parameter
- `[...rest]` — catch-all
- `[id=int]` — parameter matcher (custom validator in `src/params/int.ts`)

**Rule of thumb:**
- All files run on the server. All run on the client too, except `+server.ts`.
- `+layout` and `+error` apply to their directory and all subdirectories.

### `+page.svelte`

```svelte
<script lang="ts">
  import type { PageProps } from './$types';
  let { data, form }: PageProps = $props();
</script>

<h1>{data.title}</h1>
```

`PageProps` (since 2.16) packages `data`, `form`, and route `params` into one type. Use it instead of typing fields individually.

### `+layout.svelte`

```svelte
<script lang="ts">
  import type { LayoutProps } from './$types';
  let { data, children }: LayoutProps = $props();
</script>

<nav>...</nav>
{@render children()}
```

The layout MUST render `children` somewhere, or pages won't appear.

### `+error.svelte`

```svelte
<script>
  import { page } from '$app/state';
</script>

<h1>{page.status}</h1>
<p>{page.error?.message}</p>
```

SvelteKit walks up the tree to find the closest `+error.svelte`. Errors thrown from the root layout's `load` are caught by the static `src/error.html` fallback.

### `+server.ts` (API endpoints)

```ts
import { json, error } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = ({ url }) => {
  return json({ now: Date.now() });
};

export const POST: RequestHandler = async ({ request }) => {
  const body = await request.json();
  return json({ received: body });
};

// catch-all for unhandled methods
export const fallback: RequestHandler = ({ request }) =>
  new Response(`No handler for ${request.method}`, { status: 405 });
```

`+server.ts` files are NOT wrapped by `+layout` files. To run logic before every request, use `hooks.server.ts`.

## `load` Functions

Two flavors:

| File | Type | Runs on |
|------|------|---------|
| `+page.ts`, `+layout.ts` | Universal | Server (SSR + during prerender) AND client (after hydration) |
| `+page.server.ts`, `+layout.server.ts` | Server-only | Server only — return value is serialized to the client |

```ts
// +page.server.ts
import { error } from '@sveltejs/kit';
import * as db from '$lib/server/database';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params, locals }) => {
  if (!locals.user) error(401, 'login required');
  const post = await db.getPost(params.slug);
  if (!post) error(404, 'not found');
  return { post };
};
```

**When to use which:**
- **Server `load`** when you need a database, private env vars, secrets, or `cookies` / `locals` access.
- **Universal `load`** when fetching from public APIs (avoids the proxy hop), or when you must return non-serializable values (component constructors, classes).
- Both can coexist on the same route — the server load runs first; its result is the universal load's `event.data`.

**Important `load` traits:**
- Server returns must be devalue-serializable (JSON + `BigInt`, `Date`, `Map`, `Set`, `RegExp`, repeated/cyclical refs).
- `fetch` provided in the load event — use it instead of global `fetch`. It inherits cookies, supports relative URLs server-side, short-circuits internal `+server.ts` calls, and inlines responses into the SSR HTML to avoid double-fetches on hydration.
- Promises in the return are streamed to the browser on platforms that support streaming. Always attach a `.catch(() => {})` to lazily-resolving promises so an unhandled rejection doesn't crash the server.
- `await parent()` lets a child load read its parent layout's data — but call it *after* anything independent to avoid waterfalls.
- Auth checks belong in `hooks.server.ts` (sets `locals.user`) and per-page `+page.server.ts` guards. Avoid relying on layout loads for auth, because layouts don't always rerun on client navigation.

**Re-running:** SvelteKit re-runs a load when:
- A `params` field it accessed changed
- A `url` property it accessed changed
- A `searchParams` key it accessed changed
- A parent it `await parent()`-ed re-ran
- A url it `fetch`ed or `depends()`-ed on was passed to `invalidate(url)`
- `invalidateAll()` was called

`depends('app:custom-key')` lets you create your own invalidation tokens.

### Errors and Redirects

```ts
import { error, redirect } from '@sveltejs/kit';

throw_unused; // ❌ NOT needed in v2 — calling error()/redirect() throws
error(404, 'not found');
redirect(303, '/login');
```

In SvelteKit 2, `error()` and `redirect()` throw on your behalf — don't `throw error(...)`. Don't call them inside a `try { } catch { }` block — the catch will swallow the redirect/error.

### `getRequestEvent`

Inside server code, `import { getRequestEvent } from '$app/server'` lets shared helpers (auth guards, logging) reach the current request without prop-drilling the event.

## Form Actions

Server-side mutations triggered by `<form>` submissions. Defined in `+page.server.ts`:

```ts
// +page.server.ts
import { fail, redirect } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => ({
  user: locals.user
});

export const actions: Actions = {
  default: async ({ request, cookies }) => {
    const data = await request.formData();
    const email = String(data.get('email') ?? '');
    if (!email) return fail(400, { email, missing: true });

    cookies.set('session', await login(email), { path: '/' });
    redirect(303, '/dashboard');
  },

  logout: async ({ cookies }) => {
    cookies.delete('session', { path: '/' });
    redirect(303, '/');
  }
};
```

```svelte
<!-- +page.svelte -->
<script lang="ts">
  import type { PageProps } from './$types';
  import { enhance } from '$app/forms';
  let { form }: PageProps = $props();
</script>

<form method="POST" use:enhance>
  <input name="email" value={form?.email ?? ''} />
  {#if form?.missing}<p>Email required</p>{/if}
  <button>Sign in</button>
</form>

<form method="POST" action="?/logout" use:enhance>
  <button>Log out</button>
</form>
```

- Use `fail(status, data)` for validation errors — keeps user input around as `form` prop.
- `redirect(303, ...)` after a successful POST follows PRG.
- `use:enhance` upgrades to fetch+JS but degrades gracefully without it.
- Named actions invoked via `action="?/name"`.

For type-safe RPC-style mutations, also see remote functions in `svelte-advanced`.

## Page Options

Exported from `+page.ts`, `+page.server.ts`, `+layout.ts`, or `+layout.server.ts`:

```ts
export const prerender = true;       // build-time HTML, served as static
export const ssr = false;             // disable server rendering (SPA)
export const csr = false;             // disable client hydration (no JS)
export const trailingSlash = 'never'; // 'never' | 'always' | 'ignore'
export const config = { /* adapter-specific */ };
```

- `prerender = true` requires the page's data to be deterministic. For dynamic routes, also export an `entries()` from `+page.server.ts` listing the params to pre-render.
- `prerender = 'auto'` prerenders if possible, falls back to SSR otherwise.
- `ssr = false` + `prerender = false` produces a true SPA (page only renders on the client).
- `csr = false` ships zero JS for that page — useful for static content pages.

## Hooks

Three files in `src/`:

- `hooks.server.ts` — server lifecycle: `handle`, `handleError`, `handleFetch`, `init`
- `hooks.client.ts` — client lifecycle: `handleError`, `init`
- `hooks.ts` — universal `transport` (custom de/serialization for non-default types)

```ts
// hooks.server.ts
import type { Handle } from '@sveltejs/kit';

export const handle: Handle = async ({ event, resolve }) => {
  const session = event.cookies.get('session');
  event.locals.user = session ? await getUser(session) : null;

  const response = await resolve(event);
  response.headers.set('x-frame-options', 'DENY');
  return response;
};
```

Multiple handles compose with `sequence` from `@sveltejs/kit/hooks`.

## Building for Production

```bash
npm run build       # → vite build
npm run preview     # local preview of the production build
```

Build output goes to `.svelte-kit/output` (universal) and the **adapter** writes the deployment artifact.

## Adapters

Configured in `svelte.config.js`:

```js
// svelte.config.js
import adapter from '@sveltejs/adapter-auto';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

export default {
  preprocess: vitePreprocess(),
  kit: { adapter: adapter() }
};
```

| Adapter | Use when |
|---------|----------|
| `@sveltejs/adapter-auto` | Default; detects Vercel / Netlify / Cloudflare Pages from env. Fine for prototyping; pin a specific adapter for production. |
| `@sveltejs/adapter-node` | Self-hosted Node.js server (Docker, VPS). Outputs `build/index.js` runnable with `node build`. |
| `@sveltejs/adapter-static` | Pure static site (SSG). Requires every route to be prerenderable; set `fallback` for SPA mode. |
| `@sveltejs/adapter-vercel` | Vercel — supports edge functions, ISR, image optimization. |
| `@sveltejs/adapter-cloudflare` | Cloudflare Pages / Workers — edge runtime, KV / D1 via `platform.env`. |
| `@sveltejs/adapter-netlify` | Netlify — supports functions and edge functions. |

### `adapter-node`

Outputs a standalone Node app:

```js
import adapter from '@sveltejs/adapter-node';
export default { kit: { adapter: adapter({ out: 'build' }) } };
```

Run with `node build`. Configurable env vars: `PORT`, `HOST`, `ORIGIN`, `BODY_SIZE_LIMIT`. Behind a reverse proxy, set `ORIGIN` to the public URL so SvelteKit knows the canonical host.

### `adapter-static`

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

### Cloudflare / Vercel / Netlify

Each platform-specific adapter wires up the platform's serverless or edge runtime. For Cloudflare, server `event.platform.env` exposes bindings (KV, D1, R2). For Vercel, `export const config = { runtime: 'edge' }` opts a route into the edge runtime. For Netlify, edge functions are similar via the `edge: true` option.

## Environment Variables

Four imports — pick the right one:

| Module | Static (build-time) / Dynamic | Public / Private |
|--------|-------------------------------|------------------|
| `$env/static/private` | static | private (server only) |
| `$env/static/public` | static | public (must start with `PUBLIC_`) |
| `$env/dynamic/private` | dynamic (per-request) | private |
| `$env/dynamic/public` | dynamic | public |

Static imports inline values at build time and tree-shake unused ones. Dynamic imports read from `process.env` (or platform equivalent) at runtime — required when the same build runs in multiple environments.

## `app.html`

Edit `src/app.html` to customize the HTML shell. Required placeholders:

```html
<!DOCTYPE html>
<html lang="en">
  <head>
    %sveltekit.head%
  </head>
  <body data-sveltekit-preload-data="hover">
    <div style="display: contents">%sveltekit.body%</div>
  </body>
</html>
```

`data-sveltekit-preload-data` and `data-sveltekit-preload-code` attributes on `<a>` or any ancestor enable preloading.

## Common Mistakes

1. **Importing `$lib/server/*` from a client component** → build error. Move shared helpers out of `$lib/server`.
2. **Calling `redirect()` inside a `try`/`catch`** → catch swallows the redirect.
3. **`throw error(...)` (SvelteKit 1 syntax)** → in v2, just `error(...)` — it throws itself.
4. **Using global `fetch` in a load** → use the `fetch` from the load event for cookie-forwarding and SSR caching.
5. **Mixing prerender and dynamic data** → if `prerender = true`, the route's load must be deterministic at build time.
6. **Forgetting `entries()` for prerendered dynamic routes** → SvelteKit can't know the param values without it.
7. **Calling `invalidateAll()` constantly** → it re-runs *every* load. Prefer `invalidate(url)` or `depends()` tokens.
8. **Auth checks in layout loads only** → layouts don't always rerun on client nav. Pair with hooks or per-page guards.
