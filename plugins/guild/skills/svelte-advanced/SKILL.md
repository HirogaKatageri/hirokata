---
name: svelte-advanced
description: >
  Pre-loaded advanced Svelte 5 / SvelteKit techniques for the developer-svelte
  agent. Covers attachments ({@attach}), actions (use:), transitions and
  animations, the motion module, custom elements, packaging libraries, server
  hooks, remote functions, service workers, shallow routing, and view
  transitions. Load when the task involves animation, dom integration, library
  packaging, advanced data flow, or pwa features. Trigger phrases include
  "svelte transition", "svelte animation", "svelte attachment", "svelte
  action", "remote function", "shallow routing", "service worker", "custom
  element".
version: 1.0.0
---

# Svelte 5 — Advanced Techniques

For tasks that go beyond standard component work: animation, DOM integration, packaging, advanced server flows, and PWA features.

## Transitions

Apply enter/exit animations to elements that conditionally render.

```svelte
<script>
  import { fade, fly, slide, scale, blur, draw, crossfade } from 'svelte/transition';
  let visible = $state(true);
</script>

{#if visible}
  <div transition:fade={{ duration: 300 }}>fades both in and out</div>
{/if}

{#if visible}
  <div in:fly={{ y: 20, duration: 200 }} out:fade>independent in/out</div>
{/if}
```

Built-ins: `fade`, `fly`, `slide`, `scale`, `blur`, `draw` (SVG path), `crossfade` (paired enter/exit between elements).

A custom transition is a function returning a config:

```ts
import { cubicOut } from 'svelte/easing';

export function spin(node: Element, { duration = 400 }) {
  return {
    duration,
    easing: cubicOut,
    css: (t) => `transform: rotate(${t * 360}deg); opacity: ${t}`
  };
}
```

`css` runs as a CSS keyframe animation (best perf). Use `tick(t, u)` for frame-by-frame JS work when CSS isn't enough.

Transitions are **local** by default (don't play when a parent block toggles). Use `transition:fade|global` to opt in.

## Animations (`animate:`)

Smoothly reorder items inside a keyed `{#each}` block.

```svelte
<script>
  import { flip } from 'svelte/animate';
  let items = $state([...]);
</script>

{#each items as item (item.id)}
  <li animate:flip={{ duration: 300 }}>{item.text}</li>
{/each}
```

`flip` (First-Last-Invert-Play) is the standard. Required: the `(item.id)` key — otherwise Svelte can't track identity through reorders.

## Motion Module

`svelte/motion` provides spring and tween primitives:

```svelte
<script>
  import { Spring, Tween } from 'svelte/motion';

  const x = new Spring(0, { stiffness: 0.1, damping: 0.4 });
  const opacity = new Tween(1, { duration: 300 });
</script>

<button onclick={() => { x.target = 200; opacity.target = 0; }}>animate</button>
<div style:transform="translateX({x.current}px)" style:opacity={opacity.current}>...</div>
```

Use `prefers-reduced-motion` (`import { prefersReducedMotion } from 'svelte/motion'`) and respect it.

## Actions (`use:`)

Functions that run when an element mounts and (optionally) clean up on destroy.

```ts
// tooltip.ts
import type { Action } from 'svelte/action';

export const tooltip: Action<HTMLElement, string> = (node, text) => {
  const tip = document.createElement('div');
  tip.textContent = text ?? '';
  // ... attach, position, listen
  return {
    update: (newText) => { tip.textContent = newText ?? ''; },
    destroy: () => { tip.remove(); }
  };
};
```

```svelte
<button use:tooltip={'Hello'}>?</button>
```

For library code in Svelte 5, **prefer attachments** (next section) — they compose better with snippets and props spreading.

## Attachments (`{@attach}`)

Svelte 5's evolution of `use:`. An attachment is a function that runs on the element after mount.

```svelte
<script lang="ts">
  import type { Attachment } from 'svelte/attachments';

  const focusOnMount: Attachment = (element) => {
    (element as HTMLElement).focus();
    return () => { /* cleanup if needed */ };
  };
</script>

<input {@attach focusOnMount} />
```

Attachments can be passed as props and spread, unlike actions. They're the recommended pattern for library authors and any new DOM-integration code in Svelte 5.

## Custom Elements (Web Components)

Compile a Svelte component into a real custom element:

```svelte
<svelte:options customElement="my-counter" />

<script lang="ts">
  let { count = 0 }: { count?: number } = $props();
</script>

<button onclick={() => count++}>{count}</button>
```

Register globally by importing the file. Inside the element, use `$host()` to access the host element (useful for `dispatchEvent`).

For library mode, opt into custom-element output in `svelte.config.js` via `compilerOptions.customElement: true`, or use `<svelte:options customElement="..." />` per file.

## Packaging Libraries

`@sveltejs/package` produces a publishable package from `src/lib/`:

```bash
npm run package    # → outputs to /dist with .d.ts and svelte field
```

`package.json` should expose:

```json
{
  "exports": {
    ".": {
      "types": "./dist/index.d.ts",
      "svelte": "./dist/index.js"
    }
  },
  "files": ["dist"],
  "svelte": "./dist/index.js"
}
```

Don't bundle Svelte source when publishing — keep `.svelte` files intact so consumers' compilers can process them.

## SvelteKit Hooks (Deep Dive)

Hooks live in `src/hooks.server.ts`, `src/hooks.client.ts`, and `src/hooks.ts`.

### `handle` (server)

Wraps every request. Use for auth, locals population, response headers.

```ts
import { sequence } from '@sveltejs/kit/hooks';
import type { Handle } from '@sveltejs/kit';

const auth: Handle = async ({ event, resolve }) => {
  event.locals.user = await getUserFromCookie(event.cookies);
  return resolve(event);
};

const securityHeaders: Handle = async ({ event, resolve }) => {
  const response = await resolve(event);
  response.headers.set('content-security-policy', "default-src 'self'");
  return response;
};

export const handle = sequence(auth, securityHeaders);
```

`resolve(event, opts)` accepts:
- `transformPageChunk: ({ html }) => html.replace('%lang%', lang)` — mutate HTML chunks during streaming.
- `filterSerializedResponseHeaders: (name) => true` — control which fetch response headers get inlined into SSR HTML.
- `preload: ({ type, path }) => true` — control which assets get `<link rel="modulepreload">`.

### `handleError` (server + client)

Catches uncaught errors. Don't redirect or rethrow here — return a serializable error object that becomes `page.error`.

```ts
export const handleError: HandleServerError = ({ error, event, status }) => {
  console.error(error);
  return { message: 'Something went wrong', code: 'UNEXPECTED' };
};
```

### `handleFetch` (server)

Modifies the `fetch` provided to load functions.

```ts
export const handleFetch: HandleFetch = async ({ event, request, fetch }) => {
  if (request.url.startsWith('https://api.internal/')) {
    request.headers.set('cookie', event.request.headers.get('cookie') ?? '');
  }
  return fetch(request);
};
```

### `transport` (universal hook in `src/hooks.ts`)

Custom de/serialization for types beyond devalue's defaults — e.g., `Decimal`, custom domain classes — so they survive the server→client trip.

## Remote Functions

Type-safe RPC between client and server, defined once and callable from components:

```ts
// src/routes/posts.remote.ts
import { query, command, form } from '$app/server';
import * as v from 'valibot';
import * as db from '$lib/server/database';

export const getPost = query(v.string(), async (slug) => {
  return await db.getPost(slug);
});

export const likePost = command(v.string(), async (slug) => {
  await db.incrementLikes(slug);
  return { ok: true };
});

export const submitComment = form(
  v.object({ slug: v.string(), text: v.string() }),
  async ({ slug, text }) => {
    await db.addComment(slug, text);
  }
);
```

```svelte
<script lang="ts">
  import { getPost, likePost } from './posts.remote';
  let { params } = $props();
  const post = $derived(await getPost(params.slug));
</script>

<h1>{post.title}</h1>
<button onclick={() => likePost(params.slug)}>Like</button>
```

- `query()` — read; cached, dedupes, integrates with `await` in components.
- `command()` — write; invalidates affected queries.
- `form()` — `<form>`-driven mutation; works without JS.
- The validator (e.g. valibot, zod) gates all input.

Enable in `svelte.config.js`:

```js
kit: { experimental: { remoteFunctions: true } }
```

(Once stabilized, no flag needed — check the project's SvelteKit version.)

## Shallow Routing

Push history entries without changing the page — useful for modal dialogs, image lightboxes, drawer menus that should be back-button-friendly.

```svelte
<script lang="ts">
  import { pushState } from '$app/navigation';
  import { page } from '$app/state';
</script>

<a
  href="/photos/42"
  onclick={(e) => {
    if (innerWidth < 640) return;       // mobile: full nav
    e.preventDefault();
    pushState('', { showModal: true });
  }}
>
  View
</a>

{#if page.state.showModal}
  <Modal onclose={() => history.back()}>...</Modal>
{/if}
```

`pushState(href, state)` and `replaceState(href, state)` from `$app/navigation`. Read the state from `page.state` (typed via `App.PageState`).

## Service Workers

`src/service-worker.ts` is built and registered automatically. The `$service-worker` virtual module provides build assets:

```ts
/// <reference types="@sveltejs/kit" />
import { build, files, version } from '$service-worker';

const CACHE = `cache-${version}`;
const ASSETS = [...build, ...files];

self.addEventListener('install', (e) =>
  (e as ExtendableEvent).waitUntil(
    caches.open(CACHE).then((c) => c.addAll(ASSETS))
  )
);

self.addEventListener('activate', (e) =>
  (e as ExtendableEvent).waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    )
  )
);

self.addEventListener('fetch', (e) => {
  // strategy of choice (cache-first, network-first, stale-while-revalidate)
});
```

Disable via `kit.serviceWorker.register = false` in `svelte.config.js` if you want manual control.

## View Transitions

Use the View Transitions API for cross-page animations:

```ts
// hooks.client.ts
import { onNavigate } from '$app/navigation';

onNavigate((nav) => {
  if (!('startViewTransition' in document)) return;
  return new Promise((resolve) => {
    document.startViewTransition(async () => {
      resolve();
      await nav.complete;
    });
  });
});
```

CSS `view-transition-name: ...` per element controls the morph.

## `<svelte:boundary>`

Error and async boundaries inside a component:

```svelte
<svelte:boundary>
  <FlakyComponent />

  {#snippet failed(error, reset)}
    <p>Something broke: {error.message}</p>
    <button onclick={reset}>Try again</button>
  {/snippet}

  {#snippet pending()}
    <p>Loading…</p>
  {/snippet}
</svelte:boundary>
```

The `pending` snippet is shown while async work inside the boundary is unresolved (paired with `await` expressions in templates). The `failed` snippet renders on error and receives a `reset()` to re-run the children.

## Special Elements

- `<svelte:window>`, `<svelte:document>`, `<svelte:body>` — bind global events without manual `addEventListener`.
- `<svelte:head>` — inject into `<head>`.
- `<svelte:element this={tag}>` — render a tag chosen at runtime.
- `<svelte:options>` — per-component compiler options (`customElement`, `runes`, `accessors`, `namespace`).
- `<svelte:self>` — recursive component reference (e.g., for tree views).

## Reactive Built-ins

`svelte/reactivity` exports proxy-aware `Map`, `Set`, `Date`, `URL`, `URLSearchParams`. Use these instead of the native versions when you want their state mutations to be tracked:

```ts
import { SvelteMap, SvelteSet, SvelteDate, SvelteURL } from 'svelte/reactivity';

const selected = new SvelteSet<string>();
selected.add('foo');                 // triggers reactivity
```

`svelte/reactivity/window` exposes reactive window properties (`innerWidth`, `innerHeight`, `scrollX`, etc.) so you don't need to wire up listeners manually.
