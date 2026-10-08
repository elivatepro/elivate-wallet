import { describe, expect, it } from 'vitest';
import {
	assertCacheable,
	lastScope,
	MAX_AGE_MS,
	MemoryStore,
	purgeAll,
	readCache,
	rememberScope,
	staleLabel,
	sweepExpired,
	writeCache
} from './device-cache.js';

const alice = { uid: 'EW-10042', workspaceId: '6b0f8f3e-2a4c-4b8e-9d55-0c7a1d2e3f40' };
const aliceOther = { uid: 'EW-10042', workspaceId: '9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d' };
const bob = { uid: 'EW-10077', workspaceId: alice.workspaceId };
const now = Date.parse('2026-10-08T12:00:00Z');

describe('device cache (decision 36a)', () => {
	it('returns data only for the same user and workspace', () => {
		const store = new MemoryStore();
		writeCache(store, alice, 'offices', [{ name: 'Lagos' }], now);
		expect(readCache(store, alice, 'offices', now)?.data).toEqual([{ name: 'Lagos' }]);
		expect(readCache(store, aliceOther, 'offices', now)).toBeNull();
		expect(readCache(store, bob, 'offices', now)).toBeNull();
	});

	it('expires entries after 7 days and deletes them', () => {
		const store = new MemoryStore();
		writeCache(store, alice, 'members', [], now);
		expect(readCache(store, alice, 'members', now + MAX_AGE_MS)).not.toBeNull();
		expect(readCache(store, alice, 'members', now + MAX_AGE_MS + 1)).toBeNull();
		expect(store.keys()).toHaveLength(0);
	});

	it('sweeps expired and unreadable entries', () => {
		const store = new MemoryStore();
		writeCache(store, alice, 'history', [], now - MAX_AGE_MS - 10);
		writeCache(store, alice, 'balances', [], now);
		store.setItem('ew:cache:v1:broken', '{');
		sweepExpired(store, now);
		expect(store.keys()).toHaveLength(1);
	});

	it('erases everything, including the remembered scope, on sign-out', () => {
		const store = new MemoryStore();
		store.setItem('ew:pref:hide-amounts', '1');
		writeCache(store, alice, 'workspace', { tenantName: 'Sunrise' }, now);
		rememberScope(store, alice);
		expect(lastScope(store)).toEqual(alice);
		purgeAll(store);
		expect(lastScope(store)).toBeNull();
		expect(store.keys()).toEqual(['ew:pref:hide-amounts']);
	});

	it('refuses bank/account numbers, evidence, tokens and auth material', () => {
		expect(() => assertCacheable({ accountNumber: '0123456789' })).toThrow();
		expect(() => assertCacheable([{ payout: { account_number: 'x' } }])).toThrow();
		expect(() => assertCacheable({ evidenceUrl: 'x' })).toThrow();
		expect(() => assertCacheable({ access_token: 'x' })).toThrow();
		expect(() => assertCacheable({ refreshToken: 'x' })).toThrow();
		expect(() => assertCacheable({ pin: '1234' })).toThrow();
		const store = new MemoryStore();
		expect(() => writeCache(store, alice, 'balances', { receiptPath: 'x' }, now)).toThrow();
		expect(store.keys()).toHaveLength(0);
		expect(() => assertCacheable({ attemptsRemaining: 3, tenantName: 'Sunrise' })).not.toThrow();
	});

	it('refuses kinds outside the approved list', () => {
		const store = new MemoryStore();
		// @ts-expect-error not an approved kind
		expect(() => writeCache(store, alice, 'payoutAccounts', [], now)).toThrow();
	});

	it('labels stale data with the time and offline state', () => {
		const label = staleLabel(now, true, 'en-GB');
		expect(label).toMatch(/^Last updated \d{2}:\d{2} · offline$/);
	});
});
