// Billing presentation (Blueprint 16): plan labels, WAT dates and what the
// Billing page offers. Amounts stay exact decimal strings (formatMoney).

import type { BillingOverview, Payment, PlanOffer } from '#lib/contract/billing.js';
import { formatMoney } from './money';

const WAT = 'Africa/Lagos';

/** "15 Oct 2026" for an instant, in WAT. */
export function dayLabel(iso: string | null): string {
	if (!iso) return '';
	return new Intl.DateTimeFormat('en-GB', {
		day: 'numeric',
		month: 'short',
		year: 'numeric',
		timeZone: WAT
	}).format(new Date(iso));
}

/** "13 Mar 2027" for a WAT calendar date (YYYY-MM-DD). */
export function dateLabel(date: string | null): string {
	if (!date || !/^\d{4}-\d{2}-\d{2}$/.test(date)) return '';
	return new Intl.DateTimeFormat('en-GB', {
		day: 'numeric',
		month: 'short',
		year: 'numeric',
		timeZone: 'UTC'
	}).format(new Date(`${date}T00:00:00Z`));
}

/** The last day of a period that ends (exclusive) at `endIso`, as a label. */
export function lastDayLabel(endIso: string | null): string {
	if (!endIso) return '';
	return dayLabel(new Date(Date.parse(endIso) - 1).toISOString());
}

/** "14 Mar 2026 – 13 Mar 2027" (the end is exclusive). */
export function periodLabel(startIso: string | null, endIso: string | null): string {
	if (!startIso || !endIso) return '';
	return `${dayLabel(startIso)} – ${lastDayLabel(endIso)}`;
}

export const naira = (amount: string) => formatMoney(amount, 'NGN');

/** Paper PL02 shows people; the Billing page shows users. */
export function bandPeople(seatCap: number | null): string {
	return seatCap === null ? '1,001+ people' : `Up to ${seatCap.toLocaleString('en-GB')} people`;
}

export function statusChip(view: BillingOverview): {
	label: string;
	tone: 'trial' | 'active' | 'paused' | 'pending';
} {
	if (view.status === 'paused') return { label: 'Paused', tone: 'paused' };
	if (view.status === 'trial') return { label: 'Free trial', tone: 'trial' };
	if (view.status === 'pending') return { label: 'Awaiting payment', tone: 'pending' };
	if (view.kind === 'development') return { label: 'Active', tone: 'active' };
	return { label: 'Active', tone: 'active' };
}

/** "6 days left" (trial hero). */
export function daysLeftLabel(days: number | null): string {
	if (days === null) return '';
	return days === 1 ? '1 day left' : `${days} days left`;
}

/** The plan a year payment buys from the hero's Pay button. */
export function yearOffer(view: BillingOverview): PlanOffer | undefined {
	return view.plans.find((p) => p.key === view.plan.key);
}

/** Can the Pay button in the hero/payments card be used for a year? */
export function canPayYear(view: BillingOverview): boolean {
	if (view.status === 'pending' || view.status === 'paused' || view.status === 'trial') return true;
	if (view.kind === 'complimentary' || view.kind === 'development') return true;
	return view.kind === 'paid' && !view.renewsAutomatically;
}

export function seatsLeftLabel(used: number, cap: number | null): string {
	if (cap === null) return 'No seat limit';
	const left = Math.max(0, cap - used);
	return left === 0 ? 'No seats left' : `${left.toLocaleString('en-GB')} seats left`;
}

/** Upgrade dialog facts (Paper PL05): the next band up, until when, and what it costs now. */
export function upgradeFacts(view: BillingOverview, key?: string) {
	const offers = view.plans.filter(
		(p) => p.action === 'upgrade' || (view.status === 'trial' && p.action === 'choose')
	);
	const target = offers.find((p) => p.key === key) ?? offers[0];
	if (!target) return null;
	const kind: 'upgrade' | 'year' = target.action === 'upgrade' ? 'upgrade' : 'year';
	return {
		plan: target,
		kind,
		until: kind === 'upgrade' ? lastDayLabel(view.periodEnd) : null,
		amount: target.amount ?? target.price
	};
}

export const PAYMENT_PURPOSE: Record<Payment['purpose'], string> = {
	start: 'First year',
	renew: 'Yearly plan',
	upgrade: 'Upgrade',
	reactivate: 'Yearly plan',
	auto_renewal: 'Auto-renewal'
};

/** A first payment's year (W-19 Q3): from today to the day before next year's date. */
export function firstYearLabel(today: Date): string {
	const next = new Date(today.getTime());
	next.setFullYear(next.getFullYear() + 1);
	return `${dayLabel(today.toISOString())} – ${dayLabel(new Date(next.getTime() - 86_400_000).toISOString())}`;
}
