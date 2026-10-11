import { describe, expect, it } from 'vitest';
import {
	assertCacheable,
	clearKinds,
	currentWho,
	lastScope,
	MAX_AGE_MS,
	MAX_PARTS,
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
const WHO = 'aGVsbG8td29ybGQtMTIzNA';

describe('device cache (decision 36a)', () => {
	it('returns data only for the same user and workspace', () => {
		const store = new MemoryStore();
		writeCache(store, alice, 'offices', [{ name: 'Lagos' }], { now, who: WHO });
		expect(readCache(store, alice, 'offices', { now, who: WHO })?.data).toEqual([
			{ name: 'Lagos' }
		]);
		expect(readCache(store, aliceOther, 'offices', { now, who: WHO })).toBeNull();
		expect(readCache(store, bob, 'offices', { now, who: WHO })).toBeNull();
	});

	it('expires entries after 7 days and deletes them', () => {
		const store = new MemoryStore();
		writeCache(store, alice, 'members', [], { now, who: WHO });
		expect(readCache(store, alice, 'members', { now: now + MAX_AGE_MS, who: WHO })).not.toBeNull();
		expect(readCache(store, alice, 'members', { now: now + MAX_AGE_MS + 1, who: WHO })).toBeNull();
		expect(store.keys()).toHaveLength(0);
	});

	it('sweeps expired and unreadable entries', () => {
		const store = new MemoryStore();
		writeCache(store, alice, 'history', [], { now: now - MAX_AGE_MS - 10, who: WHO });
		writeCache(store, alice, 'balances', [], { now, who: WHO });
		store.setItem('ew:cache:v1:broken', '{');
		sweepExpired(store, now);
		expect(store.keys()).toHaveLength(1);
	});

	it('erases everything, including the remembered scope, on sign-out', () => {
		const store = new MemoryStore();
		store.setItem('ew:pref:hide-amounts', '1');
		writeCache(store, alice, 'workspace', { tenantName: 'Sunrise' }, { now, who: WHO });
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
		expect(() =>
			writeCache(store, alice, 'balances', { receiptPath: 'x' }, { now, who: WHO })
		).toThrow();
		expect(store.keys()).toHaveLength(0);
		expect(() => assertCacheable({ attemptsRemaining: 3, tenantName: 'Sunrise' })).not.toThrow();
	});

	it('refuses kinds outside the approved list', () => {
		const store = new MemoryStore();
		// @ts-expect-error not an approved kind
		expect(() => writeCache(store, alice, 'payoutAccounts', [], { now, who: WHO })).toThrow();
	});

	it('returns nothing when the ew_who guard does not match (Blueprint 20 B6)', () => {
		const store = new MemoryStore();
		writeCache(store, alice, 'balances', { total: '1' }, { now, who: WHO });
		expect(readCache(store, alice, 'balances', { now, who: WHO })?.data).toEqual({ total: '1' });
		// No cookie (signed out, or not yet set): nothing shown, entry kept.
		expect(readCache(store, alice, 'balances', { now, who: null })).toBeNull();
		expect(store.keys()).toHaveLength(1);
		// Another person or workspace signed in: nothing shown, entry deleted.
		expect(readCache(store, alice, 'balances', { now, who: 'b3RoZXItcGVyc29uLTEyMzQ' })).toBeNull();
		expect(store.keys()).toHaveLength(0);
		// Entries from before the guard (no who) are never returned.
		store.setItem(
			'ew:cache:v1:EW-10042:6b0f8f3e-2a4c-4b8e-9d55-0c7a1d2e3f40:balances',
			JSON.stringify({ ...alice, savedAt: now, data: {} })
		);
		expect(readCache(store, alice, 'balances', { now, who: WHO })).toBeNull();
	});

	it('writes nothing without a guard', () => {
		const store = new MemoryStore();
		writeCache(store, alice, 'balances', {}, { now, who: null });
		expect(store.keys()).toHaveLength(0);
	});

	it('reads the guard from the cookie string', () => {
		expect(currentWho(`ew_theme=ember; ew_who=${WHO}; other=1`)).toBe(WHO);
		expect(currentWho('ew_theme=ember')).toBeNull();
		expect(currentWho('ew_who=not%20valid')).toBeNull();
		expect(currentWho()).toBeNull(); // no document in this test runtime
	});

	it('caches wallets and settings, with parts, and clears kinds for every scope', () => {
		const store = new MemoryStore();
		writeCache(store, alice, 'wallets', [{ name: 'Kemi' }], { now, who: WHO });
		writeCache(store, alice, 'wallets', { members: 3 }, { now, who: WHO, part: 'overview' });
		writeCache(store, aliceOther, 'history', [], { now, who: WHO });
		writeCache(store, alice, 'settings', { theme: 'ember' }, { now, who: WHO });
		writeCache(store, alice, 'offices', [], { now, who: WHO });
		expect(readCache(store, alice, 'wallets', { now, who: WHO, part: 'overview' })?.data).toEqual({
			members: 3
		});
		clearKinds(store, ['wallets', 'history']);
		expect(store.keys().map((k) => k.split(':').slice(5).join(':'))).toEqual([
			'settings',
			'offices'
		]);
		expect(() => writeCache(store, alice, 'wallets', [], { who: WHO, part: 'Bad Part' })).toThrow();
	});

	it('applies the forbidden-field guard to the new kinds', () => {
		const store = new MemoryStore();
		expect(() =>
			writeCache(store, alice, 'wallets', [{ payout: { accountNumber: '0123456789' } }], {
				now,
				who: WHO
			})
		).toThrow();
		expect(() =>
			writeCache(store, alice, 'settings', { logoToken: 'x' }, { now, who: WHO })
		).toThrow();
		expect(store.keys()).toHaveLength(0);
	});

	it('keeps masked bank and NIN values, never full ones (Blueprint 23)', () => {
		expect(() =>
			assertCacheable({ accountNumberMasked: '******6789', accountLast4: '6789', ninLast4: '4321' })
		).not.toThrow();
		expect(() => assertCacheable({ accountNumberMasked: '0123456789' })).toThrow();
		expect(() => assertCacheable({ accountLast4: '0123456789' })).toThrow();
		expect(() => assertCacheable({ ninLast4: 12345678901 })).toThrow();
		expect(() => assertCacheable({ nin: '12345678901' })).toThrow();
	});

	it('refuses receipt facts, signed links and step-up material on the new kinds', () => {
		const store = new MemoryStore();
		const refused: [Parameters<typeof writeCache>[2], unknown][] = [
			['queue', { items: [{ payout: { revisions: [{ receipt: { name: 'r.pdf' } }] } }] }],
			['withdrawals', { facts: { recipientAccount: '0123456789' } }],
			['evidence', { items: [{ entry: { evidence: [{ name: 'r.pdf' }] } }] }],
			['billing', { authorizationUrl: 'https://checkout.example/x' }],
			['statements', { files: [{ downloadUrl: 'https://files.example/x' }] }],
			['account', { sessions: [{ sessionId: 'x' }] }],
			['account', { pinToken: 'x' }],
			['invitations', { items: [{ token: 'x' }] }],
			['payout-accounts', { items: [{ accountNumber: '0123456789' }] }]
		];
		for (const [kind, payload] of refused) {
			expect(() => writeCache(store, alice, kind, payload, { now, who: WHO })).toThrow();
		}
		expect(store.keys()).toHaveLength(0);
		// The list projections pages keep instead.
		writeCache(
			store,
			alice,
			'queue',
			{ items: [{ payout: { revisions: null } }] },
			{ now, who: WHO }
		);
		writeCache(
			store,
			alice,
			'billing',
			{ authorizationUrl: null, plan: 'yearly' },
			{ now, who: WHO }
		);
		writeCache(
			store,
			alice,
			'evidence',
			{ items: [{ entry: { evidence: [] } }] },
			{ now, who: WHO }
		);
		writeCache(
			store,
			alice,
			'account',
			{ security: { passwordChangedAt: '2026-10-01T09:30:00.123Z' } },
			{ now, who: WHO }
		);
		expect(store.keys()).toHaveLength(4);
		// A timestamp name never carries anything else.
		expect(() => assertCacheable({ passwordChangedAt: 'hunter2' })).toThrow();
		expect(() => assertCacheable({ resetTokenAt: '2026-10-01T09:30:00Z' })).not.toThrow();
		expect(() => assertCacheable({ evidence: [{ name: 'r.pdf' }] })).toThrow();
	});

	it('keeps a record id as a part and only the newest parts of a kind', () => {
		const store = new MemoryStore();
		const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
		for (let n = 0; n < MAX_PARTS + 3; n += 1) {
			writeCache(store, alice, 'members', { n }, { now: now + n, who: WHO, part: id(n) });
		}
		writeCache(store, alice, 'members', { list: true }, { now, who: WHO });
		writeCache(
			store,
			alice,
			'members',
			{ presidents: true },
			{ now, who: WHO, part: 'presidents' }
		);
		const parts = store.keys().filter((k) => k.includes(':members:') && /[0-9]{12}$/.test(k));
		expect(parts).toHaveLength(MAX_PARTS);
		// Fixed sub-keys and other families are never pushed out by records.
		expect(
			readCache(store, alice, 'members', { now, who: WHO, part: 'presidents' })
		).not.toBeNull();
		expect(readCache(store, alice, 'members', { now, who: WHO, part: id(0) })).toBeNull();
		expect(
			readCache(store, alice, 'members', { now: now + 30, who: WHO, part: id(MAX_PARTS + 2) })
		).not.toBeNull();
		// The list itself (no part) is not a part and stays.
		expect(readCache(store, alice, 'members', { now, who: WHO })?.data).toEqual({ list: true });
		expect(() =>
			writeCache(store, alice, 'members', {}, { who: WHO, part: 'A'.repeat(65) })
		).toThrow();
	});

	it('labels stale data with the time and offline state', () => {
		const label = staleLabel(now, true, 'en-GB');
		expect(label).toMatch(/^Last updated \d{2}:\d{2} · offline$/);
	});
});
