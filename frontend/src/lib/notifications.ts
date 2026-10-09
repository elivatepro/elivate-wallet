// Bell wording (Blueprint 13, Paper App v1 S01/S04 and v4 NB01): one title,
// one line and a time per item, from the kind and its safe params. Bank
// details appear only as the app already shows them (bank •• last 4). Links
// come from the event and are allowed only inside the app.

import type { Currency } from '#lib/contract/ledger.js';
import type { NotificationItem } from '#lib/contract/notifications.js';
import { ROLE_LABELS } from '#lib/labels.js';
import { placeLabel } from '#lib/devices.js';
import { formatMoney, hiddenMoney } from '#lib/money.js';

export type BellTone = 'warning' | 'success' | 'danger' | 'neutral';
export type BellIcon =
	'up' | 'down' | 'check' | 'x' | 'swap' | 'undo' | 'review' | 'person' | 'bank' | 'lock';

export interface BellEntry {
	readonly title: string;
	readonly line: string;
	readonly tone: BellTone;
	readonly icon: BellIcon;
	readonly href: string;
}

const PATH =
	/^\/app(\/[a-z][a-z-]*)*(\?withdrawal=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$/;

/** The item's in-app link, or Home when it is missing or not an app path. */
export function safePath(path: string | undefined): string {
	return path && PATH.test(path) ? path : '/app';
}

const isCurrency = (value: string | undefined): value is Currency =>
	value === 'NGN' || value === 'USD';

function money(
	params: Readonly<Record<string, string>>,
	hide: boolean,
	amount = 'amount',
	currency = 'currency'
): string {
	const c = params[currency];
	const a = params[amount];
	if (!isCurrency(c) || !a || !/^\d+\.\d{2}$/.test(a)) return '';
	return hide ? hiddenMoney(c) : formatMoney(a, c);
}

const KIND_NOUN: Record<string, string> = {
	conversion: 'Conversion',
	adjustment: 'Adjustment',
	returned_funds: 'Returned funds'
};

const ALERTS: Record<string, string> = {
	added: 'Payout account added',
	replaced: 'Payout account replaced',
	deactivated: 'Payout account removed',
	primary_changed: 'Main payout account changed',
	name_mismatch: 'Payout account needs attention'
};

const join = (...parts: (string | undefined)[]) =>
	parts.filter((p) => p && p.length > 0).join(' · ');

/** Title, line, tone and icon for one bell item. */
export function present(item: NotificationItem, hide = false): BellEntry {
	const p = item.params;
	const m = money(p, hide);
	const href = safePath(p.path);
	const entry = (title: string, line: string, tone: BellTone, icon: BellIcon): BellEntry => ({
		title,
		line,
		tone,
		icon,
		href
	});
	const bank = p.bank && p.last4 && /^\d{4}$/.test(p.last4) ? `${p.bank} •• ${p.last4}` : undefined;

	switch (item.kind) {
		case 'money.income_posted':
			return entry('Income posted', `${m}, split across your pockets`, 'success', 'down');
		case 'money.withdrawal_submitted':
			return entry('Withdrawal requested', join(m, p.reference), 'neutral', 'up');
		case 'money.withdrawal_approved':
			return entry('Withdrawal approved', `${m}. Payout is next.`, 'warning', 'check');
		case 'money.withdrawal_completed':
			return entry('Withdrawal completed', `Payout of ${m} confirmed.`, 'success', 'check');
		case 'money.withdrawal_not_approved':
			return entry('Withdrawal not approved', `${m} is back in your pocket.`, 'danger', 'x');
		case 'money.withdrawal_cancelled':
			return entry('Withdrawal cancelled', `${m} is back in your pocket.`, 'neutral', 'x');
		case 'money.payout_receipt_rejected':
			return entry('Payout receipt rejected', join(p.member, m, p.reference), 'danger', 'x');
		case 'money.pocket_move_done':
			return entry('Pocket move completed', `${m} from ${p.from} to ${p.to}.`, 'neutral', 'swap');
		case 'money.pocket_move_declined':
			return entry('Pocket move declined', `${m} stayed where it was.`, 'danger', 'swap');
		case 'money.adjustment_posted':
			return p.direction === 'debit'
				? entry(
						'Adjustment posted',
						`${hide ? m : `−${m}`} debit from your pockets`,
						'warning',
						'review'
					)
				: entry(
						'Adjustment posted',
						`${hide ? m : `+${m}`} credit to your pockets`,
						'success',
						'review'
					);
		case 'money.conversion_posted':
			return entry(
				'Conversion posted',
				`${m} → ${money(p, hide, 'destinationAmount', 'destinationCurrency')}`,
				'success',
				'swap'
			);
		case 'money.entry_not_posted':
			return entry(
				`${KIND_NOUN[p.subject ?? ''] ?? 'Entry'} not posted`,
				join(m, p.reference),
				'danger',
				'x'
			);
		case 'money.transaction_reversed':
			return entry('Transaction reversed', join(p.reverses, m), 'warning', 'undo');
		case 'money.returned_funds':
			return entry('Payout came back', `${m} is back in your pocket.`, 'success', 'down');
		case 'task.withdrawal_approve':
			return entry(
				'Withdrawal to approve',
				join(p.member, bank ? `${m} to ${bank}` : m),
				'warning',
				'up'
			);
		case 'task.payout_record':
			return entry('Payout to record', join(p.member, `${m} to pay out`), 'warning', 'check');
		case 'task.payout_fix':
			return entry('Payout record to fix', join(p.member, m, p.reference), 'warning', 'review');
		case 'task.payout_review':
			return entry('Payout to review', join(p.member, m, p.reference), 'warning', 'review');
		case 'task.entry_review':
			return entry(
				`${KIND_NOUN[p.subject ?? ''] ?? 'Evidence'} to review`,
				join(p.member, m, p.reference),
				'warning',
				'review'
			);
		case 'task.transfer_approve':
			return entry(
				'Pocket move to approve',
				join(p.member, `${m} from ${p.from} to ${p.to}`),
				'warning',
				'swap'
			);
		case 'task.nin_review':
			return entry('Identity to review', join(p.member, p.office), 'warning', 'person');
		case 'team.invitation_accepted':
			return entry(
				'Invitation accepted',
				`${p.member} joined ${p.office} as ${ROLE_LABELS[p.role as keyof typeof ROLE_LABELS] ?? 'a member'}.`,
				'success',
				'person'
			);
		case 'account.role_changed':
			return entry(
				'New role',
				`You’re now ${ROLE_LABELS[p.role as keyof typeof ROLE_LABELS] ?? 'in a new role'} for ${p.office}.`,
				'success',
				'person'
			);
		case 'account.membership_ended':
			return entry(
				'Membership ended',
				p.office ? `Your membership in ${p.office} ended.` : 'Your membership ended.',
				'neutral',
				'person'
			);
		case 'account.status_changed':
			return entry(
				'Account status changed',
				'Open your account to see what it means.',
				'warning',
				'person'
			);
		case 'identity.nin_review_decided':
			return p.decision === 'approved'
				? entry('Identity confirmed', 'Your name is now set for payouts.', 'success', 'person')
				: entry('Identity not confirmed', 'Check your details and ask again.', 'danger', 'person');
		case 'payout_account.alert':
			return entry(
				ALERTS[p.action ?? ''] ?? 'Payout account changed',
				p.bankName ?? '',
				p.action === 'name_mismatch' ? 'danger' : 'warning',
				'bank'
			);
		// Blueprint 14: A06–A08 as personal items. Never an IP.
		case 'security.password_changed':
			return entry('Password changed', 'Not you? Secure your account now.', 'warning', 'lock');
		case 'security.pin_changed':
			return entry('PIN changed', 'Not you? Reset your PIN now.', 'warning', 'lock');
		case 'security.new_sign_in':
			return entry(
				p.reason === 'new_location' ? 'Sign-in from a new place' : 'New sign-in',
				join(p.device, placeLabel(p.city ?? null, p.country ?? null, true) ?? undefined),
				'warning',
				'lock'
			);
		default:
			return entry('Update', '', 'neutral', 'check');
	}
}

const pad = (n: number) => String(n).padStart(2, '0');

/** "Today · 09:20", "Yesterday · 16:40", "2 Oct · 14:12" in the device's time zone. */
export function when(iso: string, now: Date = new Date()): string {
	const date = new Date(iso);
	const time = `${pad(date.getHours())}:${pad(date.getMinutes())}`;
	const day = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
	const diff = Math.round((day(now) - day(date)) / 86_400_000);
	if (diff === 0) return `Today · ${time}`;
	if (diff === 1) return `Yesterday · ${time}`;
	const label = date.toLocaleDateString('en-GB', {
		day: 'numeric',
		month: 'short',
		...(date.getFullYear() === now.getFullYear() ? {} : { year: 'numeric' })
	});
	return `${label} · ${time}`;
}
