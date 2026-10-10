// Networks and accounts screens of the platform Admin app (Blueprint 18,
// Paper A17/A07v2/A18/A09): pure labels for plans, periods, seats, switches,
// pockets and hero summaries. Client-safe: no secrets, no server imports.

import type { NetworkRow, Switch, SwitchKey } from '#lib/contract/admin.js';
import type { AllocationVersion } from '#lib/contract/ledger.js';
import type { AccountStatus } from '#lib/contract/common.js';
import { lastDayLabel } from '#lib/billing.js';

const n = (value: number) => value.toLocaleString('en-GB');

/** "3 active · 1 on trial · 1 paused · 1 waiting for payment" (zero states left out). */
export function networkSummary(counts: Readonly<Record<string, number>>): string {
	const parts: Array<[string, string]> = [
		['active', 'active'],
		['trial', 'on trial'],
		['paused', 'paused'],
		['pending_payment', 'waiting for payment'],
		['deactivated', 'deactivated']
	];
	return parts
		.filter(([key]) => (counts[key] ?? 0) > 0)
		.map(([key, label]) => `${n(counts[key] ?? 0)} ${label}`)
		.join(' · ');
}

/** "352 active · 9 restricted · 5 suspended · 2 deactivated" (zero states left out). */
export function accountSummary(counts: Readonly<Record<string, number>>): string {
	const keys: AccountStatus[] = ['active', 'restricted', 'suspended', 'deactivated'];
	return keys
		.filter((key) => (counts[key] ?? 0) > 0)
		.map((key) => `${n(counts[key] ?? 0)} ${key}`)
		.join(' · ');
}

/** "6 networks", "1 account". */
export const plural = (count: number, one: string, many = `${one}s`): string =>
	`${n(count)} ${count === 1 ? one : many}`;

const band = (cap: number | null | undefined) =>
	cap === null || cap === undefined ? '1,001+' : `Up to ${n(cap)}`;

/** List column: "Up to 400 · yearly", "Up to 400 · trial", "Complimentary", "—". */
export function planLabel(row: Pick<NetworkRow, 'state' | 'kind' | 'plan'>): string {
	if (row.state === 'pending_payment' || !row.kind) return '—';
	if (row.kind === 'complimentary') return 'Complimentary';
	if (row.kind === 'development') return 'Development exception';
	if (!row.plan) return '—';
	return `${band(row.plan.seatCap)} · ${row.kind === 'trial' ? 'trial' : 'yearly'}`;
}

/** Detail row: "Yearly · up to 400 people", "Trial · up to 400 people", "Complimentary · …". */
export function planDetail(row: Pick<NetworkRow, 'state' | 'kind' | 'plan'>): string {
	if (row.state === 'pending_payment' || !row.kind) return 'No plan yet';
	const people = row.plan
		? row.plan.seatCap === null
			? '1,001+ people'
			: `up to ${n(row.plan.seatCap)} people`
		: null;
	const lead = {
		paid: 'Yearly',
		trial: 'Trial',
		complimentary: 'Complimentary',
		development: 'Development exception'
	}[row.kind];
	return people ? `${lead} · ${people}` : lead;
}

/**
 * Ends column: the last day of the period (the stored end is exclusive).
 * A past end reads "Ended 30 Sep 2026"; the development exception has none.
 */
export function endsLabel(
	row: Pick<NetworkRow, 'state' | 'kind' | 'periodEnd'>,
	now = new Date()
): { text: string; past: boolean } {
	if (row.state === 'pending_payment') return { text: '—', past: false };
	if (row.kind === 'development') return { text: 'No end date', past: false };
	if (!row.periodEnd) return { text: '—', past: false };
	const past = Date.parse(row.periodEnd) <= now.getTime();
	const last = lastDayLabel(row.periodEnd);
	return { text: past ? `Ended ${last}` : last, past };
}

/** "204 / 400", "412 / 1,000", "18 / ∞"; "—" while waiting for payment. */
export function seatsLabel(row: Pick<NetworkRow, 'state' | 'seats'>): string {
	if (row.state === 'pending_payment') return '—';
	return `${n(row.seats.used)} / ${row.seats.cap === null ? '∞' : n(row.seats.cap)}`;
}

/** Seat bar fill, 0–100 (no cap: 0). */
export function seatPercent(seats: NetworkRow['seats']): number {
	if (!seats.cap || seats.cap <= 0) return 0;
	return Math.max(0, Math.min(100, Math.round((seats.used / seats.cap) * 100)));
}

/** "Ifeoma Okeke" → "Ifeoma O." (the drafts' short person form). */
export function shortName(name: string | null | undefined): string {
	const words = (name ?? '').trim().split(/\s+/).filter(Boolean);
	if (words.length === 0) return '';
	if (words.length === 1) return words[0] ?? '';
	return `${words[0]} ${(words.at(-1) ?? '').charAt(0)}.`;
}

type Who = { uid: string; name: string | null } | null;

/** List subline: "9 offices · President Ifeoma O." or "Founder Kemi A. · no plan yet". */
export function networkSubline(
	row: Pick<NetworkRow, 'state' | 'officeCount' | 'presidents' | 'founder'>
): string {
	if (row.state === 'pending_payment') {
		const f = row.founder as Who;
		return `Founder ${f ? shortName(f.name) || f.uid : 'unknown'} · no plan yet`;
	}
	const p = row.presidents[0] as Who | undefined;
	const offices = plural(row.officeCount, 'office');
	return p ? `${offices} · President ${shortName(p.name) || p.uid}` : offices;
}

const monthYear = new Intl.DateTimeFormat('en-GB', {
	month: 'short',
	year: 'numeric',
	timeZone: 'Africa/Lagos'
});

/** "Mar 2025" (WAT). */
export const monthOf = (iso: string): string => monthYear.format(new Date(iso));

export type SwitchTile = {
	key: SwitchKey;
	/** Stopped for every network: the network toggle is disabled. */
	platformStopped: boolean;
	/** Stopped on this network only. */
	networkStopped: boolean;
};

/** One tile per switch for a network: platform stops win over network stops. */
export function switchTiles(
	order: readonly SwitchKey[],
	platform: readonly Switch[],
	network: readonly Pick<Switch, 'key' | 'tenantId' | 'stopped'>[],
	tenantId: string
): SwitchTile[] {
	return order.map((key) => ({
		key,
		platformStopped: platform.some((s) => s.key === key && s.stopped),
		networkStopped: network.some((s) => s.key === key && s.tenantId === tenantId && s.stopped)
	}));
}

/** Versions newest first; the first is current. */
export function sortedVersions(items: readonly AllocationVersion[]): AllocationVersion[] {
	return [...items].sort((a, b) => b.version - a.version);
}

/** "40%", "12.5%" from the API's fixed-point percent ("40.00"). */
export function percentLabel(percent: string): string {
	const value = Number(percent);
	if (!Number.isFinite(value)) return `${percent}%`;
	return `${Number.isInteger(value) ? value : Number(value.toFixed(2))}%`;
}

/** "set by the President Team" / "Elivate default". */
export const versionSource = (source: string): string =>
	source === 'president' ? 'set by the President Team' : 'Elivate default';

/** "Elivate Network +1". */
export function networksLabel(networks: readonly string[]): string {
	if (networks.length === 0) return '—';
	return networks.length === 1 ? (networks[0] ?? '') : `${networks[0]} +${networks.length - 1}`;
}

export const PIN_LABELS = { set: 'Set', locked: 'Locked', not_set: 'Not set' } as const;

/** Statuses an admin can move an account to (never the current one). */
export function statusChoices(current: AccountStatus): AccountStatus[] {
	return (['active', 'restricted', 'suspended', 'deactivated'] as const).filter(
		(s) => s !== current
	);
}

/** Dialog submit label per target status (danger tone for suspend/deactivate). */
export function statusAction(target: AccountStatus): { label: string; danger: boolean } {
	switch (target) {
		case 'active':
			return { label: 'Reactivate account', danger: false };
		case 'restricted':
			return { label: 'Restrict account', danger: false };
		case 'suspended':
			return { label: 'Suspend account', danger: true };
		case 'deactivated':
			return { label: 'Deactivate account', danger: true };
	}
}
