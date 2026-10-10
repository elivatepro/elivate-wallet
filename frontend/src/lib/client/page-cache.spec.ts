import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MemoryStore, readCache, rememberScope, writeCache } from './device-cache';
import { invalidatesForPath } from './invalidation';
import { CachedPage, CachedRead, invalidate, MorePages, resetPageCache } from './page-cache.svelte';

const WHO = 'aGVsbG8td29ybGQtMTIzNA';
const alice = { uid: 'EW-10042', workspaceId: '6b0f8f3e-2a4c-4b8e-9d55-0c7a1d2e3f40' };
const bob = { uid: 'EW-10077', workspaceId: '9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d' };

let cookie = '';
beforeEach(() => {
	resetPageCache();
	cookie = `ew_who=${WHO}`;
	vi.stubGlobal('document', {
		get cookie() {
			return cookie;
		}
	});
});
afterEach(() => vi.unstubAllGlobals());

describe('CachedRead (Blueprint 20 B6)', () => {
	it('shows device-cache data for the last scope only while ew_who matches', () => {
		const store = new MemoryStore();
		rememberScope(store, alice);
		writeCache(store, alice, 'balances', { total: '5' }, { who: WHO });
		const read = new CachedRead<{ total: string }>('balances', undefined, store);
		expect(read.show()).toBe(true);
		expect(read.data).toEqual({ total: '5' });
		expect(read.savedAt).not.toBeNull();

		cookie = 'ew_who=b3RoZXItcGVyc29uLTEyMzQ';
		const other = new CachedRead('balances', undefined, store);
		expect(other.show()).toBe(false);
		expect(other.data).toBeNull();
	});

	it('shows nothing without the cookie (signed out)', () => {
		const store = new MemoryStore();
		rememberScope(store, alice);
		writeCache(store, alice, 'history', [], { who: WHO });
		cookie = '';
		expect(new CachedRead('history', undefined, store).show()).toBe(false);
	});

	it('keeps fresh data once the scope is known and serves it from memory', () => {
		const store = new MemoryStore();
		const read = new CachedRead<number>('wallets', undefined, store);
		read.fresh(7, null, read.begin());
		expect(read.data).toBe(7);
		expect(readCache(store, alice, 'wallets', { who: WHO })).toBeNull();
		read.confirm(alice);
		expect(readCache(store, alice, 'wallets', { who: WHO })?.data).toBe(7);
		// Back-navigation: memory, even with an empty device store.
		const again = new CachedRead<number>('wallets', undefined, new MemoryStore());
		expect(again.show()).toBe(true);
		expect(again.data).toBe(7);
	});

	it('drops cached data when the session names another user or workspace', () => {
		const store = new MemoryStore();
		rememberScope(store, alice);
		writeCache(store, alice, 'offices', ['Lagos'], { who: WHO });
		const read = new CachedRead<string[]>('offices', undefined, store);
		read.show();
		read.confirm(alice);
		expect(read.data).toEqual(['Lagos']);
		read.confirm(bob);
		expect(read.data).toBeNull();
		expect(read.savedAt).toBeNull();
	});

	it('drops a reply when another tab switched workspace while it ran (PR #57 P1)', () => {
		const store = new MemoryStore();
		const read = new CachedRead<number>('balances', undefined, store);
		const ticket = read.begin();
		cookie = 'ew_who=b3RoZXItcGVyc29uLTEyMzQ';
		expect(read.current(ticket)).toBe(false);
		expect(read.fresh(5, alice, ticket)).toBe(false);
		expect(read.data).toBeNull();
		expect(store.keys()).toHaveLength(0);
		expect(new CachedRead('balances', undefined, new MemoryStore()).show()).toBe(false);
	});

	it('never keeps a pending reply under a workspace confirmed after a switch', () => {
		const store = new MemoryStore();
		const read = new CachedRead<number>('balances', undefined, store);
		const refetched: number[] = [];
		read.watch(() => refetched.push(1));
		expect(read.fresh(5, null, read.begin())).toBe(true);
		cookie = 'ew_who=b3RoZXItcGVyc29uLTEyMzQ';
		read.confirm(bob);
		expect(read.data).toBeNull();
		expect(store.keys()).toHaveLength(0);
		expect(refetched).toEqual([1]);
	});

	it('drops fresh data shown for another workspace and fetches again', () => {
		const read = new CachedRead<number>('balances', undefined, new MemoryStore());
		const refetched: number[] = [];
		read.watch(() => refetched.push(1));
		read.fresh(5, alice, read.begin());
		read.confirm(bob);
		expect(read.data).toBeNull();
		expect(refetched).toEqual([1]);
	});

	it('invalidate clears memory and device entries of those kinds and refetches watchers', () => {
		const store = new MemoryStore();
		const balances = new CachedRead<number>('balances', undefined, store);
		const settings = new CachedRead<number>('settings', undefined, store);
		balances.fresh(1, alice, balances.begin());
		settings.fresh(2, alice, settings.begin());
		const refetched: string[] = [];
		const unwatch = balances.watch(() => refetched.push('balances'));
		settings.watch(() => refetched.push('settings'));
		invalidate(['balances', 'history', 'wallets'], store);
		expect(refetched).toEqual(['balances']);
		expect(readCache(store, alice, 'balances', { who: WHO })).toBeNull();
		expect(readCache(store, alice, 'settings', { who: WHO })?.data).toBe(2);
		expect(new CachedRead('balances', undefined, new MemoryStore()).show()).toBe(false);
		unwatch();
		invalidate(['balances'], store);
		expect(refetched).toEqual(['balances']);
	});

	it('never keeps a payload the forbidden-field guard refuses', () => {
		const store = new MemoryStore();
		const read = new CachedRead<object>('wallets', undefined, store);
		read.fresh({ accountNumber: '0123456789' }, alice, read.begin());
		expect(read.data).toEqual({ accountNumber: '0123456789' });
		expect(store.keys()).toHaveLength(0);
		expect(new CachedRead('wallets', undefined, new MemoryStore()).show()).toBe(false);
	});
});

const MONEY = [
	'balances',
	'history',
	'wallets',
	'offices',
	'withdrawals',
	'queue',
	'transfers',
	'evidence',
	'split',
	'entries',
	'reports',
	'statements'
];
const ORG = ['offices', 'members', 'access', 'invitations'];

describe('invalidatesForPath (Blueprint 20 B6, Blueprint 23 kinds)', () => {
	it.each([
		['/api/income', MONEY],
		['/api/queue/abc/approve', MONEY],
		['/api/transfers/abc/approve', MONEY],
		['/api/evidence-reviews/abc/decision', MONEY],
		['/api/withdrawals/abc/cancel', MONEY],
		['/api/org/offices/abc/close', [...ORG, 'audit']],
		['/api/org/members/abc/suspend', [...ORG, 'audit']],
		['/api/invitations', [...ORG, 'audit']],
		['/api/nin-reviews/abc/decide', ['nin-reviews', ...ORG]],
		['/api/settings', ['settings', 'vault']],
		['/api/backups', ['vault']],
		['/api/billing/auto-renew', ['billing']],
		['/api/payout-accounts/lookup', []],
		['/api/payout-accounts', ['payout-accounts', 'withdrawals']],
		['/api/payout-accounts/abc/primary', ['payout-accounts', 'withdrawals']],
		['/api/notifications/read', ['notifications']],
		['/api/reports', ['reports', 'statements']],
		['/api/statements', ['statements']],
		['/api/account/sessions', ['account']],
		['/api/support/chat', []],
		['/api/commands/outcome', []]
	])('%s', (path, kinds) => {
		expect(invalidatesForPath(path)).toEqual(kinds);
	});
});

type Rows = { items: { id: string; name: string }[]; nextCursor: string | null };
const rows = (...names: string[]): Rows => ({
	items: names.map((name) => ({ id: name.toLowerCase(), name })),
	nextCursor: null
});
const ok = <T>(value: T) => Promise.resolve({ ok: true as const, value });
const shellAt = (scope: typeof alice | null) => ({ readable: true, scope });

describe('CachedPage (Blueprint 23)', () => {
	it('shows the cached copy, then the fresh reply, and keeps it', async () => {
		const store = new MemoryStore();
		rememberScope(store, alice);
		writeCache(store, alice, 'audit', rows('Old'), { who: WHO });
		const page = new CachedPage<Rows>(
			shellAt(alice),
			{ kind: 'audit', load: () => ok(rows('New')) },
			store
		);
		page.mount();
		expect(page.data?.items[0]?.name).toBe('Old');
		expect(page.savedAt).not.toBeNull();
		await page.reload();
		expect(page.data?.items[0]?.name).toBe('New');
		expect(page.savedAt).toBeNull();
		expect(page.fresh).toBe(true);
		expect(readCache<Rows>(store, alice, 'audit', { who: WHO })?.data.items[0]?.name).toBe('New');
	});

	it('keeps showing the cached copy when the refresh fails', async () => {
		const store = new MemoryStore();
		rememberScope(store, alice);
		writeCache(store, alice, 'queue', rows('Kept'), { who: WHO });
		const page = new CachedPage<Rows>(
			shellAt(alice),
			{
				kind: 'queue',
				load: () => Promise.resolve({ ok: false, text: 'Try again.', status: 503 })
			},
			store
		);
		page.mount();
		await page.reload();
		expect(page.data?.items[0]?.name).toBe('Kept');
		expect(page.error).toBe('Try again.');
		expect(page.savedAt).not.toBeNull();
	});

	it('keeps the projection, shows the full reply', async () => {
		const store = new MemoryStore();
		type Payout = { id: string; revisions: { receipt: { name: string } }[] | null };
		const page = new CachedPage<Payout>(
			shellAt(alice),
			{
				kind: 'withdrawals',
				load: () => ok({ id: 'w1', revisions: [{ receipt: { name: 'r.pdf' } }] }),
				keep: (value) => ({ ...value, revisions: null })
			},
			store
		);
		await page.reload();
		expect(page.data?.revisions).toHaveLength(1);
		expect(readCache<Payout>(store, alice, 'withdrawals', { who: WHO })?.data).toEqual({
			id: 'w1',
			revisions: null
		});
	});

	it('neither shows nor keeps a view that is not cacheable (a search)', async () => {
		const store = new MemoryStore();
		rememberScope(store, alice);
		writeCache(store, alice, 'invitations', rows('Default'), { who: WHO });
		let searching = true;
		const page = new CachedPage<Rows>(
			shellAt(alice),
			{ kind: 'invitations', load: () => ok(rows('Found')), cacheable: () => !searching },
			store
		);
		page.mount();
		expect(page.data).toBeNull();
		await page.reload();
		expect(page.data?.items[0]?.name).toBe('Found');
		page.confirm(alice);
		expect(readCache<Rows>(store, alice, 'invitations', { who: WHO })?.data.items[0]?.name).toBe(
			'Default'
		);
		searching = false;
		await page.reload();
		expect(readCache<Rows>(store, alice, 'invitations', { who: WHO })?.data.items[0]?.name).toBe(
			'Found'
		);
	});

	it('keeps one copy per record and switches when the record changes', async () => {
		const store = new MemoryStore();
		rememberScope(store, alice);
		let id = 'a1';
		const page = new CachedPage<string>(
			shellAt(alice),
			{ kind: 'members', part: () => id, load: () => ok(`member ${id}`) },
			store
		);
		page.mount();
		await page.reload();
		id = 'b2';
		await page.reload();
		expect(page.data).toBe('member b2');
		expect(readCache(store, alice, 'members', { who: WHO, part: 'a1' })?.data).toBe('member a1');
		// Back to the first record: its copy shows at once.
		id = 'a1';
		const shown = page.reload();
		expect(page.data).toBe('member a1');
		expect(page.savedAt).not.toBeNull(); // labelled "Updating…" until the reply
		await shown;
		expect(page.savedAt).toBeNull();
	});

	it('drops a reply that belongs to another person or workspace', async () => {
		const store = new MemoryStore();
		let release: (value: { ok: true; value: string }) => void = () => undefined;
		const page = new CachedPage<string>(
			shellAt(alice),
			{
				kind: 'billing',
				load: () => new Promise((resolve) => (release = resolve))
			},
			store
		);
		const done = page.reload();
		// Another tab switched workspace while the read ran.
		cookie = 'ew_who=b3RoZXItcGVyc29uLTEyMzQ';
		release({ ok: true, value: 'old workspace' });
		await new Promise((resolve) => setTimeout(resolve, 0));
		expect(page.data).toBeNull();
		// It read again; that reply is for the current workspace.
		release({ ok: true, value: 'current workspace' });
		await done;
		expect(page.data).toBe('current workspace');
	});

	it('refetches when a command invalidates its kind', async () => {
		const store = new MemoryStore();
		let calls = 0;
		const page = new CachedPage<number>(
			shellAt(alice),
			{ kind: 'transfers', load: () => ok(++calls) },
			store
		);
		const stop = page.mount();
		await page.reload();
		invalidate(['transfers'], store);
		await Promise.resolve();
		await Promise.resolve();
		expect(calls).toBe(2);
		stop();
		invalidate(['transfers'], store);
		expect(calls).toBe(2);
	});
});

describe('MorePages (Blueprint 23)', () => {
	it('adds later pages to the first and drops them when the first is replaced', async () => {
		let first: Rows | null = { ...rows('A'), nextCursor: 'c1' };
		const more = new MorePages<{ id: string; name: string }>(() => first);
		expect(more.nextCursor).toBe('c1');
		await more.more((cursor) => {
			expect(cursor).toBe('c1');
			return ok(rows('B'));
		});
		expect(more.items.map((i) => i.name)).toEqual(['A', 'B']);
		expect(more.nextCursor).toBeNull();
		first = rows('Fresh');
		expect(more.items.map((i) => i.name)).toEqual(['Fresh']);
	});

	it('keeps the error and the first page when loading more fails', async () => {
		const first: Rows = { ...rows('A'), nextCursor: 'c1' };
		const more = new MorePages<{ id: string; name: string }>(() => first);
		await more.more(() => Promise.resolve({ ok: false, text: 'Offline.', status: null }));
		expect(more.error).toBe('Offline.');
		expect(more.items).toHaveLength(1);
		expect(more.nextCursor).toBe('c1');
	});
});
