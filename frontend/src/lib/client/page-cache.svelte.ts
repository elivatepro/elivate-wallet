// Blueprint 20 B6: signed-in pages show cached data first, then refresh.
//
//   const read = new CachedRead<HomeView>('balances');
//   read.show();                    // memory, else device cache (ew_who must match)
//   ...fetch at once, without waiting for the shell...
//   read.fresh(value, shell.scope); // shown at once; kept once the scope is known
//   $effect(() => { if (shell.scope) read.confirm(shell.scope); });
//   onMount(() => read.watch(refetch)); // a command cleared this kind
//
// A small module-level memory store makes back-navigation instant; the
// device cache (36a) covers reloads. Both are keyed by kind and guarded by
// the `ew_who` cookie. Commands are never answered from here.

import {
	browserStore,
	clearKinds,
	currentWho,
	lastScope,
	readCache,
	writeCache,
	type CacheKind,
	type CacheScope,
	type KeyValueStore
} from './device-cache';

interface MemoryEntry {
	readonly who: string;
	readonly scope: CacheScope;
	readonly data: unknown;
	readonly savedAt: number;
}

// Plain (non-reactive) on purpose: pages read them once, on mount.
// eslint-disable-next-line svelte/prefer-svelte-reactivity
const memory = new Map<string, MemoryEntry>();
// eslint-disable-next-line svelte/prefer-svelte-reactivity
const watchers = new Set<{ readonly kind: CacheKind; readonly refetch: () => void }>();

const memoryKey = (kind: CacheKind, part?: string) => (part ? `${kind}:${part}` : kind);
const sameScope = (a: CacheScope, b: CacheScope) =>
	a.uid === b.uid && a.workspaceId === b.workspaceId;

/**
 * A successful command changed these kinds: forget them in memory and on the
 * device, and refetch them on any page that shows them.
 */
export function invalidate(kinds: readonly CacheKind[], store = browserStore()): void {
	if (kinds.length === 0) return;
	for (const key of [...memory.keys()]) {
		if ((kinds as readonly string[]).includes(key.split(':')[0] ?? '')) memory.delete(key);
	}
	if (store) clearKinds(store, kinds);
	for (const watcher of [...watchers]) if (kinds.includes(watcher.kind)) watcher.refetch();
}

/** Test seam: forget the memory store and every watcher. */
export function resetPageCache(): void {
	memory.clear();
	watchers.clear();
}

export class CachedRead<T> {
	/** What the page shows: cached first, then fresh. */
	data: T | null = $state.raw(null);
	/** When the shown data was saved; null once fresh data arrived. */
	savedAt: number | null = $state(null);
	readonly #kind: CacheKind;
	readonly #part: string | undefined;
	readonly #store: KeyValueStore | null;
	#shownScope: CacheScope | null = null;
	#pending: { readonly data: T } | null = null;

	constructor(kind: CacheKind, part?: string, store: KeyValueStore | null = browserStore()) {
		this.#kind = kind;
		this.#part = part;
		this.#store = store;
	}

	/** Memory first, else the device cache of the last scope. True when something is shown. */
	show(): boolean {
		const who = currentWho();
		if (!who) return false;
		const kept = memory.get(memoryKey(this.#kind, this.#part));
		if (kept && kept.who === who) {
			this.#showCached(kept.data as T, kept.savedAt, kept.scope);
			return true;
		}
		const scope = this.#store ? lastScope(this.#store) : null;
		if (!this.#store || !scope) return false;
		const cached = readCache<T>(this.#store, scope, this.#kind, { who, part: this.#part });
		if (!cached) return false;
		this.#showCached(cached.data, cached.savedAt, scope);
		return true;
	}

	/** Fresh server data: shown at once, kept once the session has named the scope. */
	fresh(data: T, scope: CacheScope | null): void {
		this.data = data;
		this.savedAt = null;
		this.#shownScope = scope;
		if (scope) this.#keep(data, scope);
		else this.#pending = { data };
	}

	/**
	 * The session reply named this user and workspace: cached data shown for
	 * another pair is dropped; fresh data waiting for the scope is kept.
	 */
	confirm(scope: CacheScope): void {
		if (this.savedAt !== null && this.#shownScope && !sameScope(this.#shownScope, scope)) {
			this.clear();
		}
		const pending = this.#pending;
		if (pending) {
			this.#pending = null;
			this.#shownScope = scope;
			this.#keep(pending.data, scope);
		}
	}

	/** Drops what is shown (not what is stored). */
	clear(): void {
		this.data = null;
		this.savedAt = null;
		this.#shownScope = null;
		this.#pending = null;
	}

	/** Calls `refetch` when a command invalidates this kind. Returns the unsubscribe. */
	watch(refetch: () => void): () => void {
		const watcher = { kind: this.#kind, refetch };
		watchers.add(watcher);
		return () => watchers.delete(watcher);
	}

	#showCached(data: T, savedAt: number, scope: CacheScope): void {
		this.data = data;
		this.savedAt = savedAt;
		this.#shownScope = scope;
	}

	#keep(data: T, scope: CacheScope): void {
		const who = currentWho();
		if (!who) return;
		const now = Date.now();
		try {
			if (this.#store) {
				writeCache(this.#store, scope, this.#kind, data, { who, now, part: this.#part });
			}
			memory.set(memoryKey(this.#kind, this.#part), { who, scope, data, savedAt: now });
		} catch {
			// The forbidden-field guard refused it: it is shown, never kept.
		}
	}
}
