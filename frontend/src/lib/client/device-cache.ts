// Device cache for the PWA shell (decision 36a, amended by Blueprint 20 B6:
// signed-in pages open from it, then refresh in the background).
//
// - Only last-loaded READ-ONLY data of approved kinds (balances, history,
//   offices, members, wallets, settings, and the workspace summary the shell
//   needs to label it).
// - Scoped per user + workspace; an entry is never returned for another pair.
// - Guarded by the readable `ew_who` cookie (a keyed hash of user + workspace
//   set by the server): an entry is returned only while its `who` matches the
//   cookie, so sign-out or another sign-in never shows the previous data.
// - Maximum age 7 days; older entries are deleted when read or swept.
// - Erased on sign-out (and whenever the sign-in page is shown).
// - Never: bank/account numbers, evidence files, tokens, auth responses. A
//   forbidden-field guard refuses such payloads even if a caller tries.

export const CACHE_KINDS = [
	'workspace',
	'balances',
	'history',
	'offices',
	'members',
	'wallets',
	'settings'
] as const;
export type CacheKind = (typeof CACHE_KINDS)[number];

export const MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

const PREFIX = 'ew:cache:v1:';
/** Blueprint 20 B6: the server-set cache guard (#lib/server/who.ts). */
export const WHO_COOKIE = 'ew_who';
export const SCOPE_KEY = 'ew:scope:v1';
const LAST_SCOPE_KEY = SCOPE_KEY;

export interface CacheScope {
	/** Permanent UID of the signed-in person (not a secret). */
	readonly uid: string;
	/** Selected membership (workspace) id. */
	readonly workspaceId: string;
}

export interface CachedEntry<T> {
	readonly data: T;
	readonly savedAt: number;
}

/** Minimal synchronous key/value store (localStorage in the browser). */
export interface KeyValueStore {
	getItem(key: string): string | null;
	setItem(key: string, value: string): void;
	removeItem(key: string): void;
	keys(): string[];
}

const FORBIDDEN_FIELD =
	/(account_?number|accountNo|nuban|iban|bvn|nin\b|token|secret|password|^pin$|pinConfirm|evidence|receipt|authorization|cookie|session_?id)/i;

/** Throws if a payload carries a field that must never be cached. */
export function assertCacheable(value: unknown, path = ''): void {
	if (Array.isArray(value)) {
		value.forEach((item, i) => assertCacheable(item, `${path}[${i}]`));
		return;
	}
	if (value !== null && typeof value === 'object') {
		for (const [key, inner] of Object.entries(value)) {
			if (FORBIDDEN_FIELD.test(key)) {
				throw new Error(`device cache refused a forbidden field at ${path}.${key}`);
			}
			assertCacheable(inner, `${path}.${key}`);
		}
	}
}

const isKind = (kind: string): kind is CacheKind =>
	(CACHE_KINDS as readonly string[]).includes(kind);

/** The current `ew_who` value, or null (no cookie, or outside the browser). */
export function currentWho(
	cookie: string = typeof document === 'undefined' ? '' : document.cookie
): string | null {
	for (const part of cookie.split(';')) {
		const [name, ...rest] = part.trim().split('=');
		if (name === WHO_COOKIE) {
			const value = rest.join('=');
			return /^[A-Za-z0-9_-]{16,64}$/.test(value) ? value : null;
		}
	}
	return null;
}

export interface CacheOptions {
	readonly now?: number;
	/** The cache guard; defaults to the `ew_who` cookie. */
	readonly who?: string | null;
	/** A sub-entry of a kind (e.g. `overview` under `wallets`). */
	readonly part?: string;
}

const PART_PATTERN = /^[a-z0-9-]{1,32}$/;

const keyFor = (scope: CacheScope, kind: CacheKind, part?: string) =>
	`${PREFIX}${encodeURIComponent(scope.uid)}:${encodeURIComponent(scope.workspaceId)}:${kind}${
		part ? `:${part}` : ''
	}`;

/** Stores an entry; skipped without a `who` (it could never be read back). */
export function writeCache<T>(
	store: KeyValueStore,
	scope: CacheScope,
	kind: CacheKind,
	data: T,
	options: CacheOptions = {}
): void {
	if (!isKind(kind)) throw new Error(`device cache refused kind ${String(kind)}`);
	if (options.part !== undefined && !PART_PATTERN.test(options.part)) {
		throw new Error(`device cache refused part ${options.part}`);
	}
	assertCacheable(data);
	const who = options.who === undefined ? currentWho() : options.who;
	if (!who) return;
	const now = options.now ?? Date.now();
	const entry = { uid: scope.uid, workspaceId: scope.workspaceId, who, savedAt: now, data };
	try {
		store.setItem(keyFor(scope, kind, options.part), JSON.stringify(entry));
	} catch {
		// Quota or privacy mode: caching is best-effort, never required.
	}
}

/**
 * The entry for this scope and kind, only while its `who` equals the current
 * `ew_who` cookie. Without a cookie nothing is returned (and nothing deleted:
 * the next session reply sets it again).
 */
export function readCache<T>(
	store: KeyValueStore,
	scope: CacheScope,
	kind: CacheKind,
	options: CacheOptions = {}
): CachedEntry<T> | null {
	const who = options.who === undefined ? currentWho() : options.who;
	const now = options.now ?? Date.now();
	if (!who) return null;
	const key = keyFor(scope, kind, options.part);
	const raw = store.getItem(key);
	if (!raw) return null;
	try {
		const entry = JSON.parse(raw) as {
			uid?: unknown;
			workspaceId?: unknown;
			who?: unknown;
			savedAt?: unknown;
			data?: unknown;
		};
		const fresh =
			typeof entry.savedAt === 'number' &&
			entry.savedAt <= now &&
			now - entry.savedAt <= MAX_AGE_MS;
		// Belt and braces: the stored scope and guard must match, not just the key.
		if (
			!fresh ||
			entry.uid !== scope.uid ||
			entry.workspaceId !== scope.workspaceId ||
			entry.who !== who
		) {
			store.removeItem(key);
			return null;
		}
		return { data: entry.data as T, savedAt: entry.savedAt as number };
	} catch {
		store.removeItem(key);
		return null;
	}
}

/** Deletes expired entries and anything unreadable. */
export function sweepExpired(store: KeyValueStore, now: number = Date.now()): void {
	for (const key of store.keys()) {
		if (!key.startsWith(PREFIX)) continue;
		try {
			const entry = JSON.parse(store.getItem(key) ?? '') as { savedAt?: unknown };
			if (typeof entry.savedAt !== 'number' || now - entry.savedAt > MAX_AGE_MS) {
				store.removeItem(key);
			}
		} catch {
			store.removeItem(key);
		}
	}
}

/** Blueprint 20 B6: a command changed these kinds; drop them for every scope. */
export function clearKinds(store: KeyValueStore, kinds: readonly CacheKind[]): void {
	if (kinds.length === 0) return;
	for (const key of store.keys()) {
		if (!key.startsWith(PREFIX)) continue;
		// Key: prefix + uid : workspace : kind [: part]; uid and workspace are URI-encoded.
		const kind = key.slice(PREFIX.length).split(':')[2];
		if (kind && (kinds as readonly string[]).includes(kind)) store.removeItem(key);
	}
}

/** Removes every cached entry and the remembered scope (sign-out). */
export function purgeAll(store: KeyValueStore): void {
	for (const key of store.keys()) {
		// Pending command attempts (ew:attempt:, #lib/recovery) are NOT erased here:
		// owner decision 2026-10-09, an unknown outcome may stay on the device for
		// up to 24 hours after sign-out (scoped per person; no secrets stored).
		if (key.startsWith(PREFIX) || key === LAST_SCOPE_KEY) store.removeItem(key);
	}
}

/** Remembers which user+workspace the shell last showed, to label offline data. */
export function rememberScope(store: KeyValueStore, scope: CacheScope): void {
	try {
		store.setItem(
			LAST_SCOPE_KEY,
			JSON.stringify({ uid: scope.uid, workspaceId: scope.workspaceId })
		);
	} catch {
		// best-effort
	}
}

export function lastScope(store: KeyValueStore): CacheScope | null {
	try {
		const value = JSON.parse(store.getItem(LAST_SCOPE_KEY) ?? 'null') as Partial<CacheScope> | null;
		return value && typeof value.uid === 'string' && typeof value.workspaceId === 'string'
			? { uid: value.uid, workspaceId: value.workspaceId }
			: null;
	} catch {
		return null;
	}
}

/** localStorage adapter; null outside the browser or when storage is blocked. */
export function browserStore(): KeyValueStore | null {
	try {
		if (typeof window === 'undefined' || !window.localStorage) return null;
		const ls = window.localStorage;
		return {
			getItem: (k) => ls.getItem(k),
			setItem: (k, v) => ls.setItem(k, v),
			removeItem: (k) => ls.removeItem(k),
			keys: () =>
				Array.from({ length: ls.length }, (_, i) => ls.key(i)).filter(
					(k): k is string => k !== null
				)
		};
	} catch {
		return null;
	}
}

/** Sign-out / signed-out pages: erase all cached wallet data on this device. */
export function purgeAllDeviceData(): void {
	const store = browserStore();
	if (store) purgeAll(store);
}

/** "Last updated 14:05 · offline" (decision 36a). */
export function staleLabel(savedAt: number, offline: boolean, locale?: string): string {
	const time = new Intl.DateTimeFormat(locale, { hour: '2-digit', minute: '2-digit' }).format(
		new Date(savedAt)
	);
	return `Last updated ${time}${offline ? ' · offline' : ''}`;
}

export class MemoryStore implements KeyValueStore {
	private readonly map = new Map<string, string>();
	getItem(key: string) {
		return this.map.get(key) ?? null;
	}
	setItem(key: string, value: string) {
		this.map.set(key, value);
	}
	removeItem(key: string) {
		this.map.delete(key);
	}
	keys() {
		return [...this.map.keys()];
	}
}
