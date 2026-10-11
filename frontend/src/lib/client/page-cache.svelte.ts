// Blueprint 20 B6: signed-in pages show cached data first, then refresh.
//
//   const read = new CachedRead<HomeView>('balances');
//   read.show();                    // memory, else device cache (ew_who must match)
//   const ticket = read.begin();    // the ew_who the request is sent under
//   ...fetch at once, without waiting for the shell...
//   if (!read.current(ticket)) return load(); // another tab switched workspace
//   read.fresh(value, shell.scope, ticket);   // shown at once; kept once the scope is known
//   $effect(() => { if (shell.scope) read.confirm(shell.scope); });
//   onMount(() => read.watch(refetch)); // a command cleared this kind
//
// A small module-level memory store makes back-navigation instant; the
// device cache (36a) covers reloads. Both are keyed by kind and guarded by
// the `ew_who` cookie. Commands are never answered from here.

import { onMount, untrack } from 'svelte';
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

/** The `ew_who` a request was sent under (Greptile P1 on PR #57). */
export interface ReadTicket {
	readonly who: string | null;
}

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

/**
 * Blueprint 25: runs `refetch` whenever a command invalidates one of `kinds`
 * (the bell's task counts follow approvals this way). Returns the stop function.
 */
export function onInvalidate(kinds: readonly CacheKind[], refetch: () => void): () => void {
	const added = kinds.map((kind) => ({ kind, refetch }));
	for (const watcher of added) watchers.add(watcher);
	return () => {
		for (const watcher of added) watchers.delete(watcher);
	};
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
	#refetch: (() => void) | null = null;
	#shownScope: CacheScope | null = null;
	#pending: { readonly data: T; readonly who: string | null } | null = null;

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

	/** Call before each request: remembers which person and workspace it is for. */
	begin(): ReadTicket {
		return { who: currentWho() };
	}

	/**
	 * False when the person or workspace changed while the request ran (e.g.
	 * another tab switched workspace): the reply belongs to the old one and
	 * must be neither shown nor kept.
	 */
	current(ticket: ReadTicket): boolean {
		return ticket.who === currentWho();
	}

	/**
	 * Fresh server data: shown at once, kept once the session has named the
	 * scope. A reply for a person or workspace that is no longer current is
	 * dropped instead (returns false).
	 */
	fresh(data: T, scope: CacheScope | null, ticket: ReadTicket, kept: T = data): boolean {
		if (!this.current(ticket)) {
			this.clear();
			return false;
		}
		this.data = data;
		this.savedAt = null;
		this.#shownScope = scope;
		// Blueprint 23: `kept` may leave out what only the fresh view needs.
		if (scope) this.#keep(kept, scope, ticket.who);
		else this.#pending = { data: kept, who: ticket.who };
		return true;
	}

	/**
	 * The session reply named this user and workspace: cached data shown for
	 * another pair is dropped; fresh data waiting for the scope is kept.
	 */
	confirm(scope: CacheScope): void {
		// Cached or fresh: data shown for another pair is never relabelled; it is
		// dropped and fetched again for the confirmed pair.
		if (this.#shownScope && !sameScope(this.#shownScope, scope)) {
			this.clear();
			this.#refetch?.();
			return;
		}
		const pending = this.#pending;
		if (pending) {
			this.#pending = null;
			if (pending.who !== currentWho()) {
				this.clear();
				this.#refetch?.();
				return;
			}
			this.#shownScope = scope;
			this.#keep(pending.data, scope, pending.who);
		}
	}

	/**
	 * A command changed what is shown (Greptile on PR #60): label it as a saved
	 * copy ("Updating…") until the replacement arrives, so actions that need
	 * fresh data wait for it.
	 */
	markStale(now = Date.now()): void {
		if (this.data !== null && this.savedAt === null) this.savedAt = now;
	}

	/** Shown, but not to be kept when the scope is confirmed. */
	forget(): void {
		this.#pending = null;
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
		this.#refetch = refetch;
		watchers.add(watcher);
		return () => {
			watchers.delete(watcher);
			if (this.#refetch === refetch) this.#refetch = null;
		};
	}

	#showCached(data: T, savedAt: number, scope: CacheScope): void {
		this.data = data;
		this.savedAt = savedAt;
		this.#shownScope = scope;
	}

	#keep(data: T, scope: CacheScope, who: string | null): void {
		// Only under the ew_who the request was sent with, and only if still current.
		if (!who || who !== currentWho()) return;
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

/** What a page read answers: the value, or the text to show (org.svelte.ts `Loaded`). */
export type PageLoaded<T> =
	| { readonly ok: true; readonly value: T }
	| { readonly ok: false; readonly text: string; readonly status: number | null };

/** The shell parts a cached page follows (#lib/client/shell.svelte.ts). */
export interface PageShell {
	readonly readable: boolean;
	readonly scope: CacheScope | null;
}

export interface CachedPageOptions<T> {
	readonly kind: CacheKind;
	/**
	 * A sub-entry (a record id, lower case); the page reads again when it
	 * changes. With `part`, undefined means "no record yet": nothing is shown
	 * from or kept in the cache.
	 */
	readonly part?: () => string | undefined;
	readonly load: () => Promise<PageLoaded<T>>;
	/**
	 * Blueprint 23: the value as kept on the device (e.g. without fields only
	 * the fresh view needs). The page still shows the full fresh value.
	 */
	readonly keep?: (value: T) => T;
	/** False: neither shown from nor kept in the cache (e.g. a filtered view). */
	readonly cacheable?: () => boolean;
	/** False: the page reads nothing yet. */
	readonly enabled?: () => boolean;
}

/**
 * Blueprint 23: the Blueprint 20 B6 CachedRead steps for a whole page. Shows
 * the memory or device copy at once (`savedAt` set: the CacheNote says
 * "Updating…"), reads at the same time as /api/session, keeps the fresh reply
 * once the session names the scope, drops what belongs to another person or
 * workspace, and refetches when a command invalidates the kind. Commands are
 * never answered from here.
 */
export class CachedPage<T> {
	error: string | null = $state(null);
	errorStatus: number | null = $state(null);
	/** A fresh reply arrived (cached data alone does not count). */
	fresh = $state(false);
	#read: CachedRead<T> = $state.raw(null as unknown as CachedRead<T>);
	#part: string | undefined;
	#seq = 0;
	#unwatch: (() => void) | null = null;
	readonly #shell: PageShell;
	readonly #o: CachedPageOptions<T>;
	readonly #store: KeyValueStore | null;

	constructor(shell: PageShell, options: CachedPageOptions<T>, store = browserStore()) {
		this.#shell = shell;
		this.#o = options;
		this.#store = store;
		this.#part = options.part?.();
		this.#read = new CachedRead<T>(options.kind, this.#part, store);
	}

	/** Shown data: fresh, else the cached copy, else null. */
	get data(): T | null {
		return this.#read.data;
	}
	/** When the shown copy was saved; null while fresh data (or nothing) is shown. */
	get savedAt(): number | null {
		return this.#read.savedAt;
	}

	/** Shows the cached copy and follows invalidation. Returns the cleanup. */
	mount(): () => void {
		if (this.#cacheable()) this.#read.show();
		this.#watch();
		return () => {
			this.#unwatch?.();
			this.#unwatch = null;
			this.#seq++;
		};
	}

	/** The session named the scope: keep or drop. */
	confirm(scope: CacheScope): void {
		this.#read.confirm(scope);
	}

	/**
	 * Follows `part`: another record shows its own cached copy at once (also
	 * offline). Called by reload() and by cachedPage() when the part changes.
	 */
	follow(): void {
		const part = this.#o.part?.();
		if (part === this.#part) return;
		this.#seq++; // a read for the previous record no longer applies
		this.#part = part;
		this.#read = new CachedRead<T>(this.#o.kind, part, this.#store);
		this.fresh = false;
		this.error = null;
		this.errorStatus = null;
		if (this.#unwatch) this.#watch();
		if (this.#cacheable()) this.#read.show();
	}

	/** Reads now; the latest call wins. */
	async reload(): Promise<void> {
		this.follow();
		const mine = ++this.#seq;
		if (this.#o.enabled && !this.#o.enabled()) return;
		const read = this.#read;
		const ticket = read.begin();
		const result = await this.#o.load();
		if (mine !== this.#seq) return;
		// Another tab switched workspace while this ran: the reply is not ours.
		if (!read.current(ticket)) {
			read.clear();
			return this.reload();
		}
		if (!result.ok) {
			// Not allowed any more, or gone: the cached copy must not stay up.
			if (result.status === 403 || result.status === 404) read.clear();
			this.error = result.text;
			this.errorStatus = result.status;
			return;
		}
		this.error = null;
		this.errorStatus = null;
		this.fresh = true;
		if (this.#cacheable()) {
			const kept = this.#o.keep ? this.#o.keep(result.value) : result.value;
			read.fresh(result.value, this.#shell.scope, ticket, kept);
		} else {
			// Shown, never kept (a filtered view).
			read.fresh(result.value, null, ticket);
			read.forget();
		}
	}

	/** Forget what is shown (e.g. the person lost access). */
	clear(): void {
		this.#read.clear();
	}

	#watch(): void {
		this.#unwatch?.();
		const read = this.#read;
		this.#unwatch = read.watch(() => {
			read.markStale();
			this.fresh = false;
			void this.reload();
		});
	}

	#cacheable(): boolean {
		if (this.#o.part && this.#part === undefined) return false;
		return !this.#o.cacheable || this.#o.cacheable();
	}
}

/**
 * Creates a CachedPage during component setup and wires it: cached copy on
 * mount, a read with /api/session and again when back online, and the scope
 * check once the session answers.
 *
 *   const view = cachedPage(shell, { kind: 'audit', load: () => loadView(path, AuditEvents) });
 *   view.data · view.savedAt · view.error · view.reload()
 */
export function cachedPage<T>(shell: PageShell, options: CachedPageOptions<T>): CachedPage<T> {
	const page = new CachedPage<T>(shell, options);
	onMount(() => page.mount());
	// Starts with /api/session, not after it, again when back online, and when
	// the record (`part`, e.g. a route param) changes.
	$effect(() => {
		options.part?.();
		const readable = shell.readable;
		untrack(() => {
			page.follow();
			if (readable) void page.reload();
		});
	});
	$effect(() => {
		if (shell.scope) page.confirm(shell.scope);
	});
	return page;
}

/** A cursor-paged list (`{ items, nextCursor }`). */
export interface Paged<I> {
	readonly items: readonly I[];
	readonly nextCursor: string | null;
}

/**
 * Blueprint 23: "Load more" on top of a cached first page. Only the first page
 * is cached; pages loaded after it belong to the first page they followed and
 * are dropped when that page is replaced (fresh data, another workspace).
 */
export class MorePages<I> {
	loading = $state(false);
	error: string | null = $state(null);
	#extra: {
		readonly base: Paged<I>;
		readonly items: readonly I[];
		readonly cursor: string | null;
	} | null = $state.raw(null);
	readonly #first: () => Paged<I> | null;

	constructor(first: () => Paged<I> | null) {
		this.#first = first;
	}

	get items(): readonly I[] {
		const base = this.#first();
		if (!base) return [];
		const extra = this.#extra;
		return extra && extra.base === base ? [...base.items, ...extra.items] : base.items;
	}

	get nextCursor(): string | null {
		const base = this.#first();
		if (!base) return null;
		const extra = this.#extra;
		return extra && extra.base === base ? extra.cursor : base.nextCursor;
	}

	/** Loads the page after the last one shown. */
	async more(load: (cursor: string) => Promise<PageLoaded<Paged<I>>>): Promise<void> {
		const base = this.#first();
		const cursor = this.nextCursor;
		if (!base || !cursor || this.loading) return;
		this.loading = true;
		this.error = null;
		const result = await load(cursor);
		this.loading = false;
		if (this.#first() !== base) return; // replaced while loading
		if (!result.ok) {
			this.error = result.text;
			return;
		}
		const before = this.#extra && this.#extra.base === base ? this.#extra.items : [];
		this.#extra = {
			base,
			items: [...before, ...result.value.items],
			cursor: result.value.nextCursor
		};
	}
}
