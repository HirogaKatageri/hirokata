---
name: svelte-best-practices
description: >
  Pre-loaded Svelte 5 / SvelteKit best practices for the developer-svelte
  agent. Covers state management strategies, performance optimization,
  accessibility, SEO, TypeScript usage, testing (vitest + playwright),
  and error handling. Load alongside the other svelte-* skills before
  implementing anything non-trivial. Trigger phrases include "svelte best
  practices", "svelte performance", "svelte accessibility", "svelte
  typescript", "svelte testing", "sveltekit seo", "sveltekit error
  handling".
version: 1.0.0
---

# Svelte 5 / SvelteKit — Best Practices

Cross-cutting guidance: how to choose the right primitives, keep apps fast and accessible, and write code that doesn't break in production.

## State Management Strategy

Pick the smallest scope that works:

1. **Component-local** — `let x = $state(0)` inside a `.svelte` file. Default for anything not shared.
2. **Per-feature module** — `.svelte.ts` exporting an object with mutable fields (`export const counter = $state({ value: 0 })`). Default for cross-component state in a feature.
3. **Context** — `setContext` / `getContext` for tree-scoped state where multiple components need a per-instance shared object (e.g., a form, a dropdown). Pair context with a reactive `$state` object so the value can update.
4. **URL** — for state that should survive reloads, deep-link, or affect SSR (filters, pagination, tabs). Read via `page.url.searchParams`, write via `goto('?x=1', { replaceState: true, keepFocus: true, noScroll: true })`.
5. **Cookies / DB** — for state that crosses sessions or needs server enforcement. Set in form actions / `+server` / hooks; read in server `load`.

**Avoid:**
- Global module-level singletons that get reassigned (the rune transform breaks across module boundaries — see `svelte-core` "Sharing State Across Modules").
- Putting per-request server state in module scope — SvelteKit reuses module instances across requests, so anything you write to a module-level variable from a load function leaks between users.
- Mixing legacy `writable` stores with runes in the same feature unless you have a migration reason.

## Server-Only Modules

Three rules:

1. Anything in `$lib/server/**` is server-only — importing it from a `+page.svelte` or any `*.client.*` is a build error.
2. `+page.server.ts`, `+layout.server.ts`, `+server.ts`, `hooks.server.ts` are server-only.
3. `$env/static/private` and `$env/dynamic/private` are server-only.

When unsure, check whether a secret could leak. If it could, it goes server-side.

## Performance

### Loading

- **Streaming**: Return promises (not awaited) from server `load` for non-critical data. Wrap in `{#await}` blocks. Keeps TTFB low.
- **Parallel loads**: Sibling load functions run in parallel automatically. Avoid `await parent()` unless you actually need parent data; placement of `await parent()` controls whether you cause a waterfall.
- **`fetch` in load**: Always use the load event's `fetch` (not the global). It coalesces SSR + hydration responses and forwards cookies.
- **Preload**: `data-sveltekit-preload-data="hover"` on `<a>` (or an ancestor like `<body>`) starts the load on hover. Use `"tap"` for mobile-heavy apps.
- **Code-split**: Routes are auto code-split. For large feature components, prefer dynamic `import()` inside an `{#await}` block.

### Rendering

- Prefer `prerender = true` for pages whose content is build-time stable. This produces zero-JS-by-default pages (when `csr` is also false) or hydration-only pages.
- `prerender = 'auto'` is a useful fallback during incremental adoption.
- Use `csr = false` for static content pages (docs, marketing) — eliminates the JS bundle.
- Use `ssr = false` only for routes that genuinely can't render server-side (auth-walled dashboards backed by client-only APIs). The cost is a flash of empty content.

### Reactivity

- `$derived` is lazy and skips downstream updates when the value is referentially identical. Don't try to manually memoize; let the compiler do it.
- `$state.raw` for large arrays/objects you replace wholesale. Avoids the proxy cost.
- Avoid `$effect` for things that should be `$derived`. Effects run on every dependency change with all the cleanup overhead; deriveds are pull-based.
- Keep effects narrow — read only what you need so dependency tracking stays accurate.

### Bundle

- Run `vite build --mode=analyze` (with `rollup-plugin-visualizer`) to inspect chunks.
- Avoid importing large libraries at the route level when only one page uses them; dynamic-import them inside the page component.
- Use `precompress: true` on adapters that support it.

## Accessibility

The Svelte compiler emits a11y warnings — **treat them as errors**. They catch real issues:

- `a11y_click_events_have_key_events`, `a11y_no_static_element_interactions`: if you put `onclick` on a non-button, you must also handle keyboard.
- `a11y_label_has_associated_control`: pair every `<label>` with `for` or wrap.
- `a11y_missing_attribute`: `<img>` needs `alt`, `<a>` needs `href`.
- `a11y_autofocus`: don't auto-focus — disorients screen reader users.

### Routing & focus

SvelteKit doesn't move focus on client-side navigation by default — set `data-sveltekit-keepfocus` carefully and consider a "skip to content" link plus an `<h1>` per page that focus moves to. Use `afterNavigate` to manage focus deliberately on SPA-style pages.

### `aria-current="page"`

For nav links pointing at the current route:

```svelte
<a href="/" aria-current={page.url.pathname === '/' ? 'page' : undefined}>Home</a>
```

For preserving the highlight during a slow navigation, `$state.eager(page.url.pathname)` reflects user intent immediately.

### Reduced motion

```ts
import { prefersReducedMotion } from 'svelte/motion';
$: duration = prefersReducedMotion.current ? 0 : 300;
```

## SEO

- Set `<svelte:head>` per page (`<title>`, `<meta name="description">`, OG tags, canonical URL).
- Prefer SSR or prerendering for any public, indexable page.
- For sitemaps, expose `+server.ts` at `/sitemap.xml` returning XML with `Content-Type: application/xml`.
- Use semantic HTML (`<article>`, `<nav>`, `<main>`) — Svelte's a11y warnings nudge you toward this anyway.
- Avoid client-only rendering for marketing pages; crawlers vary in JS support.

## TypeScript

### Project setup

`sv create` with the TypeScript option scaffolds correct `tsconfig.json` (inherits from `.svelte-kit/tsconfig.json` which Kit generates). Don't override `paths` blindly — Kit relies on its aliases.

### Components

```svelte
<script lang="ts">
  import type { Snippet } from 'svelte';

  interface Props {
    title: string;
    count?: number;
    children?: Snippet;
    onsave?: (value: string) => void;
  }

  let { title, count = 0, children, onsave }: Props = $props();
</script>
```

### Generic components

```svelte
<script lang="ts" generics="T extends { id: string }">
  let { items, render }: { items: T[]; render: Snippet<[T]> } = $props();
</script>

{#each items as item (item.id)}
  {@render render(item)}
{/each}
```

### Routes

`PageProps`, `LayoutProps`, `PageServerLoad`, `PageLoad`, `LayoutServerLoad`, `LayoutLoad`, `RequestHandler`, `Actions` — all from `./$types`. Don't write them by hand; `svelte-kit sync` regenerates them.

### App-wide types

`src/app.d.ts`:

```ts
declare global {
  namespace App {
    interface Locals { user?: { id: string; email: string } }
    interface PageData {}
    interface PageState { showModal?: boolean }
    interface Platform {}
    interface Error { code?: string }
  }
}
export {};
```

`Locals` is the type of `event.locals`. `PageState` types `page.state` (shallow routing). `Platform` types `event.platform` (Cloudflare bindings, etc.).

## Testing

### `vitest` for unit/component tests

Use `@testing-library/svelte` plus `vitest`:

```ts
// counter.test.ts
import { render, fireEvent } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import Counter from './Counter.svelte';

test('increments', async () => {
  const { getByRole } = render(Counter, { props: { initial: 0 } });
  const button = getByRole('button');
  await fireEvent.click(button);
  expect(button.textContent).toContain('1');
});
```

For pure logic in `.svelte.ts` modules, vitest can import them directly — runes work in test mode when the vitest config includes the Svelte plugin.

### `playwright` for E2E

`tests/example.test.ts`:

```ts
import { expect, test } from '@playwright/test';

test('home page', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
});
```

Run via `npm run test` after `sv add playwright`. Playwright spins up the dev or preview server automatically.

### Test boundaries

- Test pure functions in plain modules with vitest.
- Test components with `@testing-library/svelte`.
- Test routes (load functions, form actions) by calling the exported functions directly with mock event objects, OR by E2E with playwright.
- Don't unit-test the framework — trust SvelteKit's primitives.

## Error Handling

### Expected vs. unexpected

- **Expected** (`error(404, '...')`, `fail(400, ...)`): user-facing, status-coded. Use them liberally.
- **Unexpected** (uncaught throw, runtime exceptions): logged via `handleError`. Never expose internals to the user.

### Patterns

```ts
// +page.server.ts
import { error } from '@sveltejs/kit';

export const load: PageServerLoad = async ({ params, locals }) => {
  const post = await db.getPost(params.slug);
  if (!post) error(404, { message: 'post not found' });   // typed message
  if (!locals.user && post.private) error(401, 'login required');
  return { post };
};
```

For typed errors, augment `App.Error` in `app.d.ts`:

```ts
namespace App {
  interface Error { message: string; code?: 'NOT_FOUND' | 'FORBIDDEN' }
}
```

### `+error.svelte`

Show the error from `page.error` and consider linking back home or to the previous page. Keep production messages generic; rely on logs for diagnostics.

### Form actions

Return validation problems with `fail(status, data)` instead of throwing — the form prop preserves user input.

```ts
if (!email) return fail(400, { email, missing: true });
```

### `<svelte:boundary>`

For component-level recovery (e.g., a flaky third-party widget), wrap it in a boundary with a `failed` snippet that includes a `reset()` button. Don't use boundaries to hide bugs — log via `onerror={(err) => report(err)}`.

## Migration & Compatibility

- Don't half-migrate within a single file. A file is either runes-mode (uses any rune) or legacy. Mixing breaks subtle assumptions.
- `<svelte:options runes={true} />` forces runes mode for that component when the project default is legacy.
- Use `sv migrate svelte-5` for codemods on incoming Svelte 4 code.

## Hygiene Checklist Before Marking a Task Done

- [ ] Compiler a11y warnings addressed (or explicitly suppressed with reason)
- [ ] No `console.log` left in production paths
- [ ] No server-only imports from client code (`pnpm check` / `npm run check` passes)
- [ ] All public-facing pages have `<svelte:head>` with title + description
- [ ] Form actions return `fail(...)` for validation, throw `error(...)` for unexpected
- [ ] All `{#each}` over reorderable lists are keyed
- [ ] All effects with subscriptions return a cleanup function
- [ ] Generated types (`./$types`) are imported, not hand-written
- [ ] `svelte-check` passes
