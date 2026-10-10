// Quick search (⌘K, Blueprint 17, P-06; Paper K01/K02): pure helpers for the
// palette. The backend decides what the workspace can see; these only group,
// label and link what came back, and match the pages the layout offers.
// Results never widen authority: every destination is a page that runs its
// own authorization again.

import type { Component } from 'svelte';
import { ROLE_LABELS } from '#lib/labels.js';
import { OFFICE_TYPE_LABELS } from '#lib/org.js';
import type {
	SearchOffice,
	SearchPerson,
	SearchRecord,
	SearchResults
} from '#lib/contract/settings.js';

/** The backend accepts 2–80 characters after trimming (GET /api/search?q=). */
export const MIN_QUERY = 2;
export const MAX_QUERY = 80;
export const MAX_PAGES = 5;
export const DEBOUNCE_MS = 200;

export interface SearchPage {
	readonly label: string;
	readonly href: string;
	readonly keywords?: string;
	/** Optional Lucide icon for the row (Paper K01 draws one per page). */
	readonly icon?: Component<{ size?: number | string; strokeWidth?: number | string }>;
}

export type GroupKey = 'people' | 'offices' | 'records' | 'pages';

export type SearchItem =
	| {
			readonly kind: 'person';
			readonly id: string;
			readonly href: string;
			readonly person: SearchPerson;
	  }
	| {
			readonly kind: 'office';
			readonly id: string;
			readonly href: string;
			readonly office: SearchOffice;
	  }
	| {
			readonly kind: 'record';
			readonly id: string;
			readonly href: string;
			readonly record: SearchRecord;
	  }
	| {
			readonly kind: 'page';
			readonly id: string;
			readonly href: string;
			readonly page: SearchPage;
	  };

export interface SearchGroup {
	readonly key: GroupKey;
	readonly label: string;
	readonly items: readonly SearchItem[];
}

export const GROUP_LABELS: Record<GroupKey, string> = {
	people: 'People',
	offices: 'Offices',
	records: 'Transactions',
	pages: 'Pages'
};

/** The trimmed query when it may be sent, otherwise null. */
export function searchableQuery(raw: string): string | null {
	const q = raw.trim();
	return q.length >= MIN_QUERY && q.length <= MAX_QUERY ? q : null;
}

export const searchPath = (q: string) => `/api/search?q=${encodeURIComponent(q)}`;

/** Apple platforms use ⌘; everything else Ctrl. */
export function isMacPlatform(): boolean {
	if (typeof navigator === 'undefined') return false;
	const platform =
		(navigator as Navigator & { userAgentData?: { platform?: string } }).userAgentData?.platform ??
		navigator.platform ??
		'';
	return /mac|iphone|ipad|ipod/i.test(platform);
}

/** ⌘K on Mac, Ctrl+K elsewhere; works everywhere, including inside inputs. */
export function isSearchShortcut(
	event: Pick<KeyboardEvent, 'key' | 'metaKey' | 'ctrlKey' | 'altKey' | 'shiftKey'>,
	mac: boolean = isMacPlatform()
): boolean {
	if (event.altKey || event.shiftKey || event.key.toLowerCase() !== 'k') return false;
	return mac ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey;
}

/** ⌘↵ on Mac, Ctrl+↵ elsewhere opens the active row in a new tab. */
export function isNewTabModifier(
	event: Pick<KeyboardEvent, 'metaKey' | 'ctrlKey'>,
	mac: boolean = isMacPlatform()
): boolean {
	return mac ? event.metaKey : event.ctrlKey;
}

// ── Destinations (existing routes only) ──

export const personHref = (p: SearchPerson) =>
	p.self ? '/app/account' : `/app/members/${encodeURIComponent(p.membershipId)}`;

export const officeHref = (o: SearchOffice) => `/app/offices/${encodeURIComponent(o.officeId)}`;

/**
 * Withdrawals: your own list, or the approval queue opened on it. Pocket
 * moves: your split page, or the transfers review. Returned funds: the
 * returns queue for the withdrawal. Ledger transactions: your activity with
 * the M03 detail (?tx=), or the member's wallet activity (Q05, ?wallet=
 * &view=activity&tx=) for leaders; the wallets list when no wallet came back.
 */
/**
 * Where a record opens, by what this workspace can open (Greptile on PR #53):
 * owners go to their own history; approvers to their queue; leaders who only
 * view wallets to that member's wallet activity.
 */
export function recordHref(r: SearchRecord, permissions: readonly string[] = []): string {
	const id = encodeURIComponent(r.id);
	const has = (key: string) => permissions.includes(key);
	const walletView = (tx?: string) =>
		r.walletId
			? `/app/wallets?wallet=${encodeURIComponent(r.walletId)}&view=activity${tx ? `&tx=${tx}` : ''}`
			: '/app/wallets';
	switch (r.kind) {
		case 'withdrawal':
			if (r.own) return '/app/withdrawals';
			return has('approve_withdrawal') ? `/app/queue?withdrawal=${id}` : walletView();
		case 'transfer':
			if (r.own) return '/app/split';
			return has('approve_pocket_transfer') ? '/app/transfers' : walletView();
		case 'returned_funds':
			if (r.own) return '/app/activity';
			if (has('record_returned_funds')) {
				return r.withdrawalId
					? `/app/queue/returns?withdrawal=${encodeURIComponent(r.withdrawalId)}`
					: '/app/queue/returns';
			}
			return walletView();
		case 'transaction':
			return r.own ? `/app/activity?tx=${id}` : walletView(id);
	}
}

/** Case-insensitive match on label and keywords; every word must appear. */
export function matchPages(
	pages: ReadonlyArray<SearchPage>,
	query: string,
	max: number = MAX_PAGES
): SearchPage[] {
	const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
	if (words.length === 0) return [];
	const scored: { page: SearchPage; score: number; index: number }[] = [];
	pages.forEach((page, index) => {
		const label = page.label.toLowerCase();
		const haystack = `${label} ${(page.keywords ?? '').toLowerCase()}`;
		if (!words.every((w) => haystack.includes(w))) return;
		// Label prefix first, then label contains, then keyword-only matches.
		const first = words[0] ?? '';
		const score = label.startsWith(first) ? 0 : words.every((w) => label.includes(w)) ? 1 : 2;
		scored.push({ page, score, index });
	});
	return scored
		.sort((a, b) => a.score - b.score || a.index - b.index)
		.slice(0, max)
		.map((s) => s.page);
}

/** Groups in the drawn order (People, Offices, Transactions, Pages); empty ones dropped. */
export function buildGroups(
	results: SearchResults | null,
	pages: readonly SearchPage[],
	permissions: readonly string[] = []
): SearchGroup[] {
	const groups: SearchGroup[] = [];
	if (results) {
		groups.push({
			key: 'people',
			label: GROUP_LABELS.people,
			items: results.people.map((person) => ({
				kind: 'person',
				id: `person-${person.membershipId}`,
				href: personHref(person),
				person
			}))
		});
		groups.push({
			key: 'offices',
			label: GROUP_LABELS.offices,
			items: results.offices.map((office) => ({
				kind: 'office',
				id: `office-${office.officeId}`,
				href: officeHref(office),
				office
			}))
		});
		groups.push({
			key: 'records',
			label: GROUP_LABELS.records,
			items: results.records.map((record) => ({
				kind: 'record',
				id: `${record.kind}-${record.id}`,
				href: recordHref(record, permissions),
				record
			}))
		});
	}
	groups.push({
		key: 'pages',
		label: GROUP_LABELS.pages,
		items: pages.map((page, i) => ({ kind: 'page', id: `page-${i}`, href: page.href, page }))
	});
	return groups.filter((g) => g.items.length > 0);
}

/** One list in visual order, for the arrow keys. */
export const flatten = (groups: readonly SearchGroup[]): SearchItem[] =>
	groups.flatMap((g) => g.items);

/** Arrow-key movement that wraps; from "nothing active", ↓ goes first and ↑ last. */
export function moveIndex(current: number, delta: 1 | -1, length: number): number {
	if (length <= 0) return -1;
	if (current < 0 || current >= length) return delta > 0 ? 0 : length - 1;
	return (current + delta + length) % length;
}

// ── Row text ──

export const RECORD_KIND_LABELS: Record<SearchRecord['kind'], string> = {
	withdrawal: 'Withdrawal',
	transfer: 'Pocket move',
	returned_funds: 'Returned funds',
	transaction: 'Transaction'
};

/** "needs_review" → "Needs review". */
export const humanize = (value: string) =>
	value.charAt(0).toUpperCase() + value.slice(1).replaceAll('_', ' ');

export type StatusTone = 'success' | 'warning' | 'danger' | 'neutral';

export function statusTone(status: string): StatusTone {
	if (['completed', 'posted', 'paid', 'verified'].includes(status)) return 'success';
	if (['rejected', 'cancelled', 'failed', 'reversed'].includes(status)) return 'danger';
	if (['requested', 'approved', 'needs_review', 'pending', 'verifying'].includes(status))
		return 'warning';
	return 'neutral';
}

export const shortDay = (iso: string) =>
	new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short' }).format(new Date(iso));

export const personName = (p: SearchRecord['person']) => p?.name ?? p?.uid ?? 'Someone';

/**
 * "Team Leader · Lagos office · EW-40117" (K01) or, compact, "Team Leader ·
 * EW-40117" (K02). The masked email or phone joins only when the query looks
 * like one, so the person can see why the row matched; never unmasked.
 */
export function personDetail(p: SearchPerson, query: string, compact = false): string {
	const parts: string[] = [ROLE_LABELS[p.role] ?? humanize(p.role)];
	if (!compact && p.officeName) parts.push(p.officeName);
	if (p.person) parts.push(p.person.uid);
	if (p.status !== 'active') parts.push(humanize(p.status));
	if (query.includes('@') && p.emailMasked) parts.push(p.emailMasked);
	else if (/^[0-9\s+()-]{4,}$/.test(query.trim()) && p.phoneMasked) parts.push(p.phoneMasked);
	return parts.join(' · ');
}

/** "Team office · South-West Directorate" (K01) or "Team office · 24 members" (K02). */
export function officeDetail(o: SearchOffice, compact = false): string {
	const parts: string[] = [OFFICE_TYPE_LABELS[o.officeType] ?? humanize(o.officeType)];
	if (compact) parts.push(memberCount(o.memberCount));
	else if (o.parentName) parts.push(o.parentName);
	if (o.status !== 'active') parts.push(humanize(o.status));
	return parts.join(' · ');
}

export const memberCount = (n: number) => `${n} ${n === 1 ? 'member' : 'members'}`;

/** "Withdrawal · Adaeze Nwosu · Lagos office · 1 Oct" (K01) or "Adaeze Nwosu · 1 Oct" (K02). */
export function recordDetail(r: SearchRecord, compact = false): string {
	const who = r.own ? 'You' : personName(r.person);
	const kind = r.kind === 'transaction' && r.type ? humanize(r.type) : RECORD_KIND_LABELS[r.kind];
	const parts = compact ? [who] : [kind, who];
	if (!compact && r.officeName) parts.push(r.officeName);
	parts.push(shortDay(r.at));
	return parts.join(' · ');
}

/** Withdrawals leave the wallet, so they read negative (K01 "−₦48,000.00"). */
export function recordAmount(r: SearchRecord): { amount: string; signed: boolean } | null {
	if (!r.amount) return null;
	const { amount } = r.amount;
	if (r.kind === 'withdrawal' && !amount.startsWith('-'))
		return { amount: `-${amount}`, signed: true };
	return { amount, signed: r.kind === 'returned_funds' };
}
