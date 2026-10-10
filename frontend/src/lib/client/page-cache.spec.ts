import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MemoryStore, readCache, rememberScope, writeCache } from './device-cache';
import { invalidatesForPath } from './invalidation';
import { CachedRead, invalidate, resetPageCache } from './page-cache.svelte';

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

describe('invalidatesForPath (Blueprint 20 B6)', () => {
	it.each([
		['/api/income', ['balances', 'history', 'wallets', 'offices']],
		['/api/queue/abc/approve', ['balances', 'history', 'wallets', 'offices']],
		['/api/transfers/abc/approve', ['balances', 'history', 'wallets', 'offices']],
		['/api/evidence-reviews/abc/decision', ['balances', 'history', 'wallets', 'offices']],
		['/api/org/offices/abc/close', ['offices', 'members']],
		['/api/org/members/abc/suspend', ['offices', 'members']],
		['/api/invitations', ['offices', 'members']],
		['/api/settings', ['settings']],
		['/api/payout-accounts/lookup', []],
		['/api/notifications/read', []],
		['/api/reports', []]
	])('%s', (path, kinds) => {
		expect(invalidatesForPath(path)).toEqual(kinds);
	});
});
