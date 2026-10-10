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
//   Masked values (`…Masked`, `…Last4`) pass only when they show 4 digits or
//   fewer (Blueprint 23).
// - Blueprint 23: every /app page that reads data has a kind of its own.

export const CACHE_KINDS = [
	'workspace',
	'balances',
	'history',
	'offices',
	'members',
	'wallets',
	'settings',
	// Blueprint 23: the rest of the app's reads.
	'withdrawals',
	'payout-accounts',
	'notifications',
	'queue',
	'transfers',
	'evidence',
	'statements',
	'reports',
	'invitations',
	'split',
	'audit',
	'billing',
	'nin-reviews',
	'access',
	'account',
	'entries',
	'vault'
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
	/(account_?number|accountNo|nuban|iban|bvn|nin\b|token|secret|password|^pin$|pinConfirm|evidence|receipt|authorization|cookie|session_?id|recipientAccount|(upload|download|signed)Url)/i;

/**
 * Blueprint 23: a masked bank or NIN value (`accountNumberMasked`,
 * `accountLast4`, `ninLast4`) may be kept, but only while it shows 4 digits or
 * fewer; a full number under such a name is still refused.
 */
const MASKED_FIELD = /(Masked|Last4)$/;
const isMasked = (value: unknown) =>
	typeof value === 'string' && (value.match(/[0-9]/g) ?? []).length <= 4;

/** Throws if a payload carries a field that must never be cached. */
export function assertCacheable(value: unknown, path = ''): void {
	if (Array.isArray(value)) {
		value.forEach((item, i) => assertCacheable(item, `${path}[${i}]`));
		return;
	}
	if (value !== null && typeof value === 'object') {
		for (const [key, inner] of Object.entries(value)) {
			if (MASKED_FIELD.test(key)) {
				if (!isMasked(inner)) {
					throw new Error(`device cache refused an unmasked value at ${path}.${key}`);
				}
				continue;
			}
			// Blueprint 23: an empty (null) forbidden field holds nothing, so a
			// page may keep a projection with such fields set to null.
			if (FORBIDDEN_FIELD.test(key) && inner !== null) {
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
	/** A sub-entry of a kind (e.g. `overview` under `wallets`, or a record id). */
	readonly part?: string;
}

// Blueprint 23: long enough for a record id (uuid) or a short filter key.
const PART_PATTERN = /^[a-z0-9-]{1,64}$/;

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
		if (options.part !== undefined) trimParts(store, scope, kind, options.part);
	} catch {
		// Quota or privacy mode: caching is best-effort, never required.
	}
}

/**
 * Blueprint 23: at most this many record parts of one family (e.g. opened
 * members, or `seg-<id>` pockets) per kind and scope.
 */
export const MAX_PARTS = 20;

/** The family of a part: its text without a trailing record id. */
const partFamily = (part: string) =>
	part.replace(/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/, '#');

/** Keeps the newest MAX_PARTS parts of a family; detail pages would otherwise pile up. */
function trimParts(store: KeyValueStore, scope: CacheScope, kind: CacheKind, part: string): void {
	const family = partFamily(part);
	if (family === part) return; // a fixed sub-key (e.g. `overview`), not a record
	const prefix = `${keyFor(scope, kind)}:`;
	const parts = store
		.keys()
		.filter((key) => key.startsWith(prefix) && partFamily(key.slice(prefix.length)) === family)
		.map((key) => {
			try {
				const saved = (JSON.parse(store.getItem(key) ?? '') as { savedAt?: unknown }).savedAt;
				return { key, savedAt: typeof saved === 'number' ? saved : 0 };
			} catch {
				return { key, savedAt: 0 };
			}
		});
	if (parts.length <= MAX_PARTS) return;
	parts.sort((a, b) => b.savedAt - a.savedAt);
	for (const { key } of parts.slice(MAX_PARTS)) store.removeItem(key);
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
