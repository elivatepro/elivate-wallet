import { describe, expect, it } from 'vitest';
import type { NotificationItem } from '#lib/contract/notifications.js';
import { present, safePath, when } from './notifications';

const item = (kind: string, params: Record<string, string>, read = false): NotificationItem => ({
	id: '00000000-0000-4000-8000-000000000001',
	kind,
	open: kind.startsWith('task.'),
	subject: { type: 'withdrawal', id: '00000000-0000-4000-8000-000000000002' },
	params,
	read,
	createdAt: '2026-10-09T09:20:00.000000Z'
});

describe('bell wording (Paper NB01/S01)', () => {
	it('approval task: member, amount, bank •• last 4', () => {
		const entry = present(
			item('task.withdrawal_approve', {
				member: 'Chinedu Okafor',
				amount: '30000.00',
				currency: 'NGN',
				bank: 'GTBank',
				last4: '1124',
				path: '/app/queue?withdrawal=00000000-0000-4000-8000-000000000002'
			})
		);
		expect(entry.title).toBe('Withdrawal to approve');
		expect(entry.line).toBe('Chinedu Okafor · ₦30,000.00 to GTBank •• 1124');
		expect(entry.tone).toBe('warning');
		expect(entry.href).toBe('/app/queue?withdrawal=00000000-0000-4000-8000-000000000002');
	});

	it('payout to record and income posted', () => {
		expect(
			present(
				item('task.payout_record', { member: 'Adaeze Nwosu', amount: '48000.00', currency: 'NGN' })
			).line
		).toBe('Adaeze Nwosu · ₦48,000.00 to pay out');
		const income = present(
			item('money.income_posted', { amount: '180000.00', currency: 'NGN', path: '/app/activity' })
		);
		expect([income.title, income.line, income.icon]).toEqual([
			'Income posted',
			'₦180,000.00, split across your pockets',
			'down'
		]);
	});

	it('hide amounts masks every figure', () => {
		const entry = present(
			item('money.conversion_posted', {
				amount: '180000.00',
				currency: 'NGN',
				destinationAmount: '120.00',
				destinationCurrency: 'USD'
			}),
			true
		);
		expect(entry.line).toBe('₦•••••• → $••••••');
		expect(entry.line).not.toMatch(/\d/);
	});

	it('adjustments are signed; returns and reversals name their references', () => {
		expect(
			present(
				item('money.adjustment_posted', { amount: '50.00', currency: 'NGN', direction: 'debit' })
			).line
		).toBe('−₦50.00 debit from your pockets');
		expect(
			present(
				item('money.transaction_reversed', {
					amount: '100.00',
					currency: 'NGN',
					reverses: 'PTR-4B8Q-2210'
				})
			).line
		).toBe('PTR-4B8Q-2210 · ₦100.00');
		expect(
			present(
				item('money.entry_not_posted', {
					subject: 'returned_funds',
					amount: '1.00',
					currency: 'NGN'
				})
			).title
		).toBe('Returned funds not posted');
	});

	it('statements and reports: ready opens the files page; failures say so', () => {
		const ready = present(
			item('export.statement_ready', {
				title: 'September 2026',
				currency: 'NGN',
				format: 'PDF statement',
				reference: 'STM-4V9B-0412',
				path: '/app/statements',
				what: 'statement'
			})
		);
		expect(ready).toMatchObject({
			title: 'Statement ready',
			line: 'September 2026 · NGN',
			href: '/app/statements'
		});
		const report = present(
			item('export.report_ready', {
				title: 'Q3 2026',
				currency: 'USD',
				format: 'Office report PDF',
				path: '/app/reports'
			})
		);
		expect(report.line).toBe('Q3 2026 · USD · Office report PDF');
		const failed = present(
			item('export.failed', {
				title: 'Q3 2026',
				currency: 'USD',
				what: 'report',
				path: '/app/reports'
			})
		);
		expect(failed).toMatchObject({ title: 'Couldn’t finish your report', tone: 'danger' });
	});

	it('older person emails get readable items', () => {
		expect(
			present(item('payout_account.alert', { action: 'name_mismatch', bankName: 'GTBank' })).tone
		).toBe('danger');
		expect(present(item('identity.nin_review_decided', { decision: 'approved' })).title).toBe(
			'Identity confirmed'
		);
		expect(present(item('something.new', {})).title).toBe('Update');
	});

	it('links stay inside the app', () => {
		expect(safePath('/app/evidence')).toBe('/app/evidence');
		expect(safePath('https://evil.example/app')).toBe('/app');
		expect(safePath('//evil.example')).toBe('/app');
		expect(safePath('/app/../admin')).toBe('/app');
		expect(safePath('/app?next=x')).toBe('/app');
		expect(safePath(undefined)).toBe('/app');
	});

	it('opens one of my withdrawals (Blueprint 45)', () => {
		const id = '0b0e7b5c-6d3a-4f4e-9a52-6c2f1f7e8a10';
		expect(safePath(`/app/withdrawals/${id}`)).toBe(`/app/withdrawals/${id}`);
		expect(safePath(`/app/withdrawals/${id.toUpperCase()}`)).toBe('/app');
		expect(safePath(`/app/withdrawals/${id}/cancel`)).toBe('/app');
		expect(safePath(`/app/withdrawals/${id}?next=//evil.example`)).toBe('/app');
		expect(safePath(`/app/withdrawals/${id}?withdrawal=${id}`)).toBe('/app');
		expect(safePath(`/app/withdrawals/${id.slice(0, -1)}`)).toBe('/app');
		expect(safePath('/app/withdrawals')).toBe('/app/withdrawals');
		const entry = present(
			item('money.withdrawal_approved', {
				amount: '5000.00',
				currency: 'NGN',
				path: `/app/withdrawals/${id}`
			})
		);
		expect(entry.href).toBe(`/app/withdrawals/${id}`);
	});

	it('times read like Paper', () => {
		const now = new Date(2026, 9, 9, 18, 0);
		expect(when(new Date(2026, 9, 9, 9, 20).toISOString(), now)).toBe('Today · 09:20');
		expect(when(new Date(2026, 9, 8, 16, 40).toISOString(), now)).toBe('Yesterday · 16:40');
		expect(when(new Date(2026, 9, 2, 14, 12).toISOString(), now)).toBe('2 Oct · 14:12');
		expect(when(new Date(2025, 8, 22, 18, 31).toISOString(), now)).toBe('22 Sept 2025 · 18:31');
	});
});

describe('security items (Blueprint 14)', () => {
	it('A06/A08 are personal warnings that open Profile & security', () => {
		const pw = present(
			item('security.password_changed', { at: '2026-10-09T10:00:00Z', path: '/app/account' })
		);
		expect(pw.title).toBe('Password changed');
		expect(pw.href).toBe('/app/account');
		expect(pw.icon).toBe('lock');
		expect(present(item('security.pin_changed', { path: '/app/account' })).title).toBe(
			'PIN changed'
		);
	});

	it('A07 shows the device and place, never an IP', () => {
		const entry = present(
			item('security.new_sign_in', {
				device: 'Windows · Edge',
				city: 'Abuja',
				country: 'NG',
				reason: 'new_location',
				path: '/app/account/devices'
			})
		);
		expect(entry.title).toBe('Sign-in from a new place');
		expect(entry.line).toBe('Windows · Edge · Abuja (approx.)');
		expect(entry.href).toBe('/app/account/devices');
		expect(
			present(item('security.new_sign_in', { device: 'Mac · Chrome', reason: 'new_device' })).title
		).toBe('New sign-in');
	});
});
