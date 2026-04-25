---
name: svelte-core
description: >
  Pre-loaded Svelte 5 core knowledge for the developer-svelte agent. Covers
  the component model, runes ($state, $derived, $effect, $props, $bindable),
  basic markup, control flow, snippets, bindings, scoped styles, lifecycle,
  and context. Load this skill before writing or editing any .svelte,
  .svelte.ts, or .svelte.js file. Trigger phrases include "svelte core",
  "svelte runes", "svelte 5 component", "svelte state", "svelte derived",
  "svelte effect", "svelte props", "svelte bind".
version: 1.0.0
---

# Svelte 5 — Core Knowledge

Authoritative reference for writing modern Svelte 5 components and reactive modules. Read this in full before touching any `.svelte` / `.svelte.ts` / `.svelte.js` file.

## File Types

- `.svelte` — a component. Has `<script>`, markup, and `<style>` blocks.
- `.svelte.ts` / `.svelte.js` — a reactive module. The compiler transforms runes here too. Use these for shared reactive state and reusable reactive logic.
- `.ts` / `.js` — plain modules. Runes are NOT transformed here. Don't use `$state` etc. in plain `.ts` files; rename to `.svelte.ts` if you need reactivity.

## Component Anatomy

```svelte
<script lang="ts">
  // imports, props, state, derived, effects, functions
  let { name = 'world' }: { name?: string } = $props();
  let count = $state(0);
  let doubled = $derived(count * 2);
</script>

<h1>Hello {name}</h1>
<button onclick={() => count++}>{doubled}</button>

<style>
  h1 { color: tomato; }
</style>
```

A component is its file. Each `.svelte` file exports one component as the default export. To export named values, use `<script module>`:

```svelte
<script module lang="ts">
  export const VERSION = '1.0';
</script>
<script lang="ts">
  // instance script
</script>
```

`<script module>` runs once when the module is first evaluated. The instance `<script>` runs per component instance.

## Runes

Runes are compiler primitives. They look like functions but are syntax — don't import them. Always use parentheses (`$state(0)`, not `$state 0`).

### `$state`

Creates reactive state.

```svelte
<script>
  let count = $state(0);
  let todos = $state([{ done: false, text: 'add more todos' }]);
</script>
```

- Objects and arrays are made into deeply-reactive **proxies**. Mutating nested properties (`todos[0].done = true`) and array methods (`push`, `splice`) trigger updates.
- Class instances are NOT proxied. Use `$state` on class **fields** instead:
  ```ts
  class Todo {
    done = $state(false);
    text = $state('');
  }
  ```
- Destructuring loses reactivity: `let { done } = todos[0]` captures the value at that moment.
- `$state.raw(value)` — non-reactive container. Mutations are ignored; only reassignment triggers updates. Use for large arrays/objects you replace wholesale.
- `$state.snapshot(proxy)` — returns a plain (non-proxy) deep clone. Use when passing state to libraries that don't expect proxies (`structuredClone`, `JSON.stringify` works without it but some APIs choke).

### `$derived`

Computed reactive values.

```svelte
<script>
  let count = $state(0);
  let doubled = $derived(count * 2);
  let total = $derived.by(() => {
    let sum = 0;
    for (const n of items) sum += n;
    return sum;
  });
</script>
```

- Expression must be **side-effect-free**. Don't mutate state inside.
- Dependencies are auto-tracked: any state read synchronously inside the expression.
- Use `$derived.by(() => { ... })` when you need statements (loops, conditionals, multiple lines).
- Deriveds can be **temporarily overridden** by reassignment (Svelte 5.25+). Useful for optimistic UI:
  ```ts
  let likes = $derived(post.likes);
  async function like() {
    likes += 1;            // optimistic
    try { await api.like(); } catch { likes -= 1; }
  }
  ```
- Push-pull reactivity: deriveds re-evaluate lazily when read; downstream updates skip if the result is referentially identical.

### `$effect`

Side effects that run after the DOM updates.

```svelte
<script>
  let canvas = $state();
  let color = $state('red');

  $effect(() => {
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = color;
    ctx.fillRect(0, 0, 100, 100);

    return () => ctx.clearRect(0, 0, 100, 100); // optional cleanup
  });
</script>
```

- Tracks any state read synchronously inside the function.
- Re-runs on dependency change. Cleanup function runs before next run and on destroy.
- `$effect.pre(...)` — runs **before** DOM updates. Useful for measuring layout pre-mutation.
- `$effect.tracking()` — boolean, true if currently inside a tracked context.
- `$effect.root(() => { ... })` — escape the parent effect's lifecycle; returns a manual disposer.
- **Don't** use `$effect` to derive state. If you find yourself doing `$effect(() => { other = base * 2 })`, use `$derived` instead.
- Effects are component-scoped. Top-level `$effect` outside a component or `.svelte.*` module errors.

### `$props`

Reads component inputs.

```svelte
<script lang="ts">
  let { adjective = 'cool', children, ...rest }: {
    adjective?: string;
    children?: import('svelte').Snippet;
  } = $props();
</script>
```

- Always destructure with defaults inline. Renaming works (`{ super: trouper } = $props()`).
- Rest props (`...rest`) capture everything else.
- **Don't mutate props.** Pass callback props for changes, or use `$bindable` for shared state.
- `$props.id()` — stable ID unique per component instance, SSR-safe. Use for `for`/`aria-labelledby`.

### `$bindable`

Marks a prop as two-way bindable from the parent.

```svelte
<!-- Input.svelte -->
<script lang="ts">
  let { value = $bindable('') }: { value?: string } = $props();
</script>
<input bind:value />
```

```svelte
<!-- Parent.svelte -->
<script>
  let name = $state('');
</script>
<Input bind:value={name} />
```

Only mark props bindable when two-way binding is genuinely needed; default to one-way + callbacks.

### `$inspect`

Dev-time debugging — logs when tracked values change.

```ts
$inspect(count);                     // logs on every change
$inspect(count).with(console.trace); // custom logger
```

Stripped from production builds.

### `$host`

Inside a custom element, returns the host element. Use for dispatching `CustomEvent`s in Svelte custom elements.

## Sharing State Across Modules

In `.svelte.ts` / `.svelte.js`:

```ts
// counter.svelte.ts — DON'T export reassigned state
export let count = $state(0);   // wrong — reads on the importing side won't be reactive
```

Two correct patterns:

```ts
// 1. Export an object whose properties you mutate
export const counter = $state({ count: 0 });
export function increment() { counter.count += 1; }
```

```ts
// 2. Export getters/functions, keep state private
let count = $state(0);
export function getCount() { return count; }
export function increment() { count += 1; }
```

Pass-by-value also applies inside the same module — passing `count` to a function passes the current value, not a live reference. For "pass a live state", pass a getter `() => count` or an object whose property you read.

## Markup

### Text expressions

```svelte
<p>Hello {name}!</p>
<p>{a + b} = {a} + {b}</p>
```

### Attributes

```svelte
<button disabled={busy} class={['btn', { active: isActive }]}>Go</button>
<input {value} />                 <!-- shorthand: same as value={value} -->
<div {...attrs}></div>            <!-- spread -->
```

### Events

Use **HTML event attributes**, not the legacy `on:` directive:

```svelte
<button onclick={handleClick}>Click</button>
<input oninput={(e) => value = e.currentTarget.value} />
```

There are no event modifiers in runes mode. Implement `preventDefault`, `stopPropagation`, `once` etc. inside the handler:

```svelte
<form onsubmit={(e) => { e.preventDefault(); save(); }}>
```

For capture phase, suffix the attribute: `onclickcapture`.

### Control flow

```svelte
{#if user}
  <p>Hi {user.name}</p>
{:else if guest}
  <p>Welcome guest</p>
{:else}
  <p>Sign in</p>
{/if}

{#each items as item, i (item.id)}
  <li>{i}: {item.text}</li>
{:else}
  <li>Empty</li>
{/each}

{#await promise}
  <p>Loading…</p>
{:then value}
  <p>{value}</p>
{:catch err}
  <p>Error: {err.message}</p>
{/await}

{#key id}
  <Component />          <!-- destroyed and re-created when `id` changes -->
{/key}
```

The keyed each (`(item.id)`) is important — without a key, Svelte uses index-based diffing, which animations and transitions need to track identity.

### Snippets and `{@render}`

Snippets are reusable markup chunks. They replace slots in Svelte 5.

```svelte
<!-- Define -->
{#snippet row(item)}
  <tr><td>{item.name}</td><td>{item.price}</td></tr>
{/snippet}

<!-- Render -->
<table>
  {#each items as item}
    {@render row(item)}
  {/each}
</table>
```

Children of a component become a snippet named `children`:

```svelte
<!-- Card.svelte -->
<script>
  let { children } = $props();
</script>
<div class="card">{@render children?.()}</div>

<!-- Usage -->
<Card>Hello</Card>
```

Pass named snippet props by writing them as children with `#snippet`:

```svelte
<DataTable {items}>
  {#snippet header()}<tr><th>Name</th></tr>{/snippet}
  {#snippet row(item)}<tr><td>{item.name}</td></tr>{/snippet}
</DataTable>
```

Type a snippet prop with `import type { Snippet } from 'svelte'`:

```ts
let { row }: { row: Snippet<[Item]> } = $props();
```

### Other markup tags

- `{@html string}` — inject raw HTML. Sanitize first; XSS risk.
- `{@const name = expr}` — declare a constant inside a block (e.g., inside `{#each}`).
- `{@debug var1, var2}` — pause in devtools when listed values change.
- `{@attach fn}` — attach an action-like function to an element (see `svelte-advanced`).

### Bindings

```svelte
<input bind:value={name} />
<input type="checkbox" bind:checked={agreed} />
<input type="number" bind:valueAsNumber={age} />
<input type="file" bind:files />
<select bind:value={selected}>...</select>
<textarea bind:value={text} />

<video bind:duration bind:currentTime bind:paused>...</video>

<div bind:clientWidth={w} bind:clientHeight={h}>...</div>
<div bind:this={el}>...</div>
```

Function bindings (Svelte 5):

```svelte
<input bind:value={() => name, (v) => name = v.toUpperCase()} />
```

### `class` and `style` directives

```svelte
<div class={['btn', { active, large: size === 'lg' }]}>...</div>
<div style:color={theme.primary} style:--gap="8px">...</div>
```

`class` accepts strings, arrays, or objects (truthy keys become classes) — same convention as `clsx`.

### `use:` actions and `{@attach}`

```svelte
<div use:tooltip={'Hello'}>...</div>
```

In Svelte 5, prefer attachments via `{@attach}` for new code (see `svelte-advanced`). Existing `use:` actions still work.

## Scoped Styles

Styles in `<style>` are scoped to the component — Svelte adds a hash class.

```svelte
<style>
  p { color: tomato; }            /* only this component's <p> */
  :global(body) { margin: 0; }    /* escape hatch */
  :global(.theme-dark) p { color: #ddd; }
</style>
```

- `:global(selector)` opts out of scoping.
- Custom CSS properties pass naturally through scoped styles, so they're the right tool for theming.
- Nested `<style>` rules (CSS nesting) work.
- Keyframes are scoped by default; use `-global-` prefix to expose: `@keyframes -global-spin {}`.

To pass styles into a component, use CSS custom properties:

```svelte
<!-- Slider.svelte -->
<style>
  .track { background: var(--slider-bg, #eee); }
</style>
<!-- Usage -->
<Slider --slider-bg="lightblue" />
```

## Lifecycle

In runes mode, the lifecycle is mostly expressed through `$effect`. The classic helpers from `svelte` still exist:

- `onMount(fn)` — runs once after first render (client-only). Returning a function gives a teardown that runs on destroy.
- `onDestroy(fn)` — runs when the component is destroyed (server and client).
- `tick()` — returns a promise that resolves once pending state changes have applied to the DOM.
- `untrack(fn)` — read state without registering it as a dependency.

Prefer `$effect(() => { ... return () => cleanup(); })` for new code; reach for `onMount` only when you need the "mounted exactly once on the client" semantics specifically.

## Context

For passing values down the component tree without prop-drilling.

```ts
import { setContext, getContext } from 'svelte';

// Parent
const theme = $state({ mode: 'dark' });
setContext('theme', theme);

// Child (any depth)
const theme = getContext<{ mode: string }>('theme');
```

Use a unique key (a `Symbol` is safest) for non-public contexts. Context is set at component init time — once set, it can't be changed by the same component (but the **value** can be a reactive object, which is the usual pattern for shared state).

## Stores (legacy)

Pre-runes stores from `svelte/store` (`writable`, `readable`, `derived`) still work and integrate with runes via the `$store` auto-subscription syntax. Use them when:
- The codebase already uses them and you're matching the pattern.
- You need RxJS-style observables or manual subscription control.

For new code in a Svelte 5 project, prefer `$state` in `.svelte.ts` modules over `writable`.

## Common Mistakes to Avoid

1. **Reassigning a class field decorated with `$state` from outside the class** — use methods instead.
2. **Using `$:` reactive statements in runes mode** — they're a Svelte 4 feature. Use `$derived` or `$effect`.
3. **Using `export let` in runes mode** — use `$props()`.
4. **Using `on:click` in runes mode** — use `onclick`.
5. **Mutating a non-`$state` object expecting reactivity** — only state declared with `$state` is reactive.
6. **Effects deriving state** — that's what `$derived` is for.
7. **Putting runes in `.ts` files** — rename to `.svelte.ts`.
8. **Destructuring reactive state and expecting the locals to update** — destructuring captures values; keep the access path (`obj.prop`) instead.
