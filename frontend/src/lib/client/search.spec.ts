import { describe, expect, it } from 'vitest';
import type { SearchPerson, SearchRecord, SearchResults } from '#lib/contract/settings.js';
import {
	buildGroups,
	flatten,
	isNewTabModifier,
	isSearchShortcut,
	matchPages,
	moveIndex,
	officeHref,
	personDetail,
	personHref,
	recordAmount,
	recordHref,
	searchableQuery,
	searchNote,
	searchPath
} from './search.js';

// Synthetic data only.
const ID = {
	membership: '6b0f8f3e-2a4c-4b8e-9d55-0c7a1d2e3f40',
	office: '9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d',
	record: '1f2e3d4c-5b6a-4978-8a9b-0c1d2e3f4a5b',
	withdrawal: '2a3b4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d',
	wallet: '3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f'
};

const person = (over: Partial<SearchPerson> = {}): SearchPerson => ({
	membershipId: ID.membership,
	person: { uid: 'EW-40117', name: 'Tunde B.' },
	role: 'team_leader',
	status: 'active',
	officeName: 'Lagos office',
	emailMasked: 't•••••@example.test',
	phoneMasked: '+234 •• •••• 2210',
	self: false,
	...over
});

const record = (over: Partial<SearchRecord> = {}): SearchRecord => ({
	kind: 'withdrawal',
	id: ID.record,
	reference: 'WDR-3J8Q-1142',
	status: 'approved',
	amount: { amount: '48000.00', currency: 'NGN' },
	person: { uid: 'EW-48213', name: 'Adaeze Nwosu' },
	officeName: 'Lagos office',
	at: '2026-10-01T09:00:00Z',
	own: false,
	...over
});

const results: SearchResults = {
	query: 'Lagos',
	people: [person(), person({ membershipId: ID.wallet, person: { uid: 'EW-48213', name: 'A' } })],
	offices: [
		{
			officeId: ID.office,
			name: 'Lagos office',
			officeType: 'team_leader',
			status: 'active',
			parentName: 'South-West Directorate',
			memberCount: 24
		}
	],
	records: [record()]
};

const key = (k: string, mods: Partial<KeyboardEvent> = {}) => ({
	key: k,
	metaKey: false,
	ctrlKey: false,
	altKey: false,
	shiftKey: false,
	...mods
});

describe('quick search destinations', () => {
	it('opens your own account, or the member page for others', () => {
		expect(personHref(person({ self: true }))).toBe('/app/account');
		expect(personHref(person())).toBe(`/app/members/${ID.membership}`);
	});

	it('opens the office page', () => {
		expect(officeHref(results.offices[0]!)).toBe(`/app/offices/${ID.office}`);
	});

	it('routes records to what the workspace can open', () => {
		const approver = ['approve_withdrawal', 'approve_pocket_transfer', 'record_returned_funds'];
		const wallet = '00000000-0000-0000-0000-0000000000c9';
		expect(recordHref(record({ own: true }))).toBe('/app/withdrawals');
		expect(recordHref(record(), approver)).toBe(`/app/queue?withdrawal=${ID.record}`);
		expect(recordHref(record({ walletId: wallet }), ['view_managed_wallets'])).toBe(
			`/app/wallets?wallet=${wallet}&view=activity`
		);
		expect(recordHref(record({ kind: 'transfer', own: true }))).toBe('/app/split');
		expect(recordHref(record({ kind: 'transfer' }), approver)).toBe('/app/transfers');
		expect(recordHref(record({ kind: 'transfer' }))).toBe('/app/wallets');
		expect(
			recordHref(record({ kind: 'returned_funds', withdrawalId: ID.withdrawal }), approver)
		).toBe(`/app/queue/returns?withdrawal=${ID.withdrawal}`);
		expect(recordHref(record({ kind: 'returned_funds', withdrawalId: null }), approver)).toBe(
			'/app/queue/returns'
		);
		// A member's own returned funds open their history, never the leaders' queue.
		expect(recordHref(record({ kind: 'returned_funds', own: true }))).toBe('/app/activity');
	});

	it('opens a transaction in your activity or the member wallet activity', () => {
		const tx = record({ kind: 'transaction', amount: undefined, status: undefined });
		expect(recordHref({ ...tx, own: true })).toBe(`/app/activity?tx=${ID.record}`);
		expect(recordHref({ ...tx, walletId: ID.wallet })).toBe(
			`/app/wallets?wallet=${ID.wallet}&view=activity&tx=${ID.record}`
		);
		expect(recordHref({ ...tx, walletId: null })).toBe('/app/wallets');
	});
});

describe('quick search pages', () => {
	const pages = [
		{ label: 'Overview', href: '/app' },
		{ label: 'Members', href: '/app/members', keywords: 'people team uid' },
		{ label: 'Reports & exports', href: '/app/reports', keywords: 'statements csv' },
		{ label: 'Member wallets', href: '/app/wallets' },
		{ label: 'Roles & access', href: '/app/access', keywords: 'members permissions' }
	];

	it('matches label and keywords case-insensitively, label prefix first', () => {
		expect(matchPages(pages, 'MEM').map((p) => p.href)).toEqual([
			'/app/members',
			'/app/wallets',
			'/app/access'
		]);
		expect(matchPages(pages, 'csv').map((p) => p.href)).toEqual(['/app/reports']);
		expect(matchPages(pages, 'member wal').map((p) => p.href)).toEqual(['/app/wallets']);
	});

	it('returns nothing for a blank query and caps the list', () => {
		expect(matchPages(pages, '   ')).toEqual([]);
		const many = Array.from({ length: 9 }, (_, i) => ({ label: `Page ${i}`, href: `/p/${i}` }));
		expect(matchPages(many, 'page')).toHaveLength(5);
	});
});

describe('quick search grouping', () => {
	it('flattens in the drawn order: people, offices, transactions, pages', () => {
		const groups = buildGroups(
			results,
			[{ label: 'Members', href: '/app/members' }],
			['approve_withdrawal']
		);
		expect(groups.map((g) => g.label)).toEqual(['People', 'Offices', 'Transactions', 'Pages']);
		expect(flatten(groups).map((i) => i.kind)).toEqual([
			'person',
			'person',
			'office',
			'record',
			'page'
		]);
		expect(flatten(groups).map((i) => i.href)[3]).toBe(`/app/queue?withdrawal=${ID.record}`);
	});

	it('drops empty groups and keeps pages without remote results', () => {
		const groups = buildGroups(null, [{ label: 'Members', href: '/app/members' }]);
		expect(groups.map((g) => g.key)).toEqual(['pages']);
		expect(buildGroups({ ...results, people: [], records: [] }, []).map((g) => g.key)).toEqual([
			'offices'
		]);
	});

	it('gives every item a unique id', () => {
		const items = flatten(buildGroups(results, [{ label: 'A', href: '/a' }]));
		expect(new Set(items.map((i) => i.id)).size).toBe(items.length);
	});
});

describe('quick search keyboard', () => {
	it('wraps arrow movement', () => {
		expect(moveIndex(0, 1, 3)).toBe(1);
		expect(moveIndex(2, 1, 3)).toBe(0);
		expect(moveIndex(0, -1, 3)).toBe(2);
		expect(moveIndex(-1, 1, 3)).toBe(0);
		expect(moveIndex(-1, -1, 3)).toBe(2);
		expect(moveIndex(0, 1, 0)).toBe(-1);
	});

	it('opens on ⌘K (Mac) or Ctrl+K (elsewhere) only', () => {
		expect(isSearchShortcut(key('k', { metaKey: true }), true)).toBe(true);
		expect(isSearchShortcut(key('K', { metaKey: true }), true)).toBe(true);
		expect(isSearchShortcut(key('k', { ctrlKey: true }), true)).toBe(false);
		expect(isSearchShortcut(key('k', { ctrlKey: true }), false)).toBe(true);
		expect(isSearchShortcut(key('k', { metaKey: true }), false)).toBe(false);
		expect(isSearchShortcut(key('k', { metaKey: true, shiftKey: true }), true)).toBe(false);
		expect(isSearchShortcut(key('j', { metaKey: true }), true)).toBe(false);
	});

	it('opens in a new tab with ⌘↵ or Ctrl+↵', () => {
		expect(isNewTabModifier({ metaKey: true, ctrlKey: false }, true)).toBe(true);
		expect(isNewTabModifier({ metaKey: false, ctrlKey: true }, false)).toBe(true);
		expect(isNewTabModifier({ metaKey: false, ctrlKey: false }, true)).toBe(false);
	});
});

describe('quick search text', () => {
	it('sends 2–80 trimmed characters, encoded', () => {
		expect(searchableQuery(' a ')).toBeNull();
		expect(searchableQuery('x'.repeat(81))).toBeNull();
		expect(searchableQuery('  Lagos ')).toBe('Lagos');
		expect(searchPath('a&b c')).toBe('/api/search?q=a%26b%20c');
	});

	it('shows masked contact details only when the query looks like one', () => {
		expect(personDetail(person(), 'Lagos')).toBe('Team Leader · Lagos office · EW-40117');
		expect(personDetail(person(), 'Lagos', true)).toBe('Team Leader · EW-40117');
		expect(personDetail(person(), 't@ex')).toContain('t•••••@example.test');
		expect(personDetail(person(), '0801 234')).toContain('+234 •• •••• 2210');
	});

	it('signs withdrawals negative', () => {
		expect(recordAmount(record())).toEqual({ amount: '-48000.00', signed: true });
		expect(recordAmount(record({ kind: 'transaction', amount: undefined }))).toBeNull();
	});
});

describe('search note (Blueprint 41)', () => {
	const none: SearchResults = { query: 'tu', people: [], offices: [], records: [] };
	const some: SearchResults = { query: 'tu', people: [person()], offices: [], records: [] };

	it('says "Searching…" only while a request runs and nothing is shown', () => {
		expect(searchNote('loading', null)).toBe('searching');
		expect(searchNote('loading', some)).toBe(null);
		expect(searchNote('idle', null)).toBe(null);
	});

	it('keeps "No matches" steady while the next request runs', () => {
		expect(searchNote('ready', none)).toBe('empty');
		expect(searchNote('idle', none)).toBe('empty');
		expect(searchNote('loading', none)).toBe('empty');
		expect(searchNote('ready', some)).toBe(null);
	});

	it('offline and errors win', () => {
		expect(searchNote('offline', some)).toBe('offline');
		expect(searchNote('error', null)).toBe('error');
	});
});
