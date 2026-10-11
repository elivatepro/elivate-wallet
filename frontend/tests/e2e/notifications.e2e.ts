// Notifications (Blueprint 13): money events write bell items and emails in
// the same transaction; the worker delivers them through the fake Cloudflare
// into the local mail catcher (no real email); the President sees "Needs your
// action" tasks that clear when done. Screenshots: S01, S04, NB01 desktop and
// mobile, and a rendered sample of every notification email. Local stack only.

import { expect, test } from './fixtures';
import {
	createConfirmedAccount,
	expectAccessible,
	inviteMember,
	localSql,
	mailFor,
	recordIncome,
	runOutboxWorker,
	shot,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, joinAsNewMember, signInAs, asPresident } = walletPeople;
const MOBILE = { width: 390, height: 844 };
const DESKTOP = { width: 1440, height: 900 };

test.describe.configure({ mode: 'serial' });

test('money events reach the bell and the mail catcher; tasks clear when done', async ({
	page
}) => {
	const founder = { email: uniqueEmail('nb-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('nb-m');
	const { joinPath } = await inviteMember(founder, 'Bell Test Network', member);
	await joinAsNewMember(page, joinPath, member);
	await recordIncome(founder, member, '180000.00');
	// The member requests a withdrawal with their PIN (M06 → M07 → M08).
	await page.goto('/app/withdrawals/new');
	await page.getByRole('radio', { name: /Point Value/ }).click();
	await page.getByLabel('Amount').fill('48000');
	await page.getByRole('button', { name: 'Continue to review' }).click();
	await page.getByRole('button', { name: 'Submit request' }).click();
	const pin = page.getByRole('dialog', { name: 'Enter your transaction PIN' });
	await pin.getByLabel('Your PIN').fill(PIN);
	await pin.getByRole('button', { name: 'Submit request' }).click();
	const sent = page.getByText(/^Reference WDR-/);
	await expect(sent).toBeVisible();
	const reference = ((await sent.textContent()) ?? '').replace('Reference ', '').trim();
	expect(reference).toMatch(/^WDR-[0-9A-Z]{4}-[0-9A-Z]{4}$/);

	// Member, desktop S01: unread dot, popover with the two money items.
	await page.setViewportSize(DESKTOP);
	await page.goto('/app');
	// Income, the request and the onboarding payout-account alert (A09).
	const bell = page.getByRole('button', { name: /^Notifications, 3 unread$/ });
	await expect(bell).toBeVisible();
	await bell.click();
	const panel = page.locator('.popover.notifications');
	await expect(panel.getByText('Income posted')).toBeVisible();
	await expect(panel.getByText('₦180,000.00, split across your pockets')).toBeVisible();
	await expect(panel.getByText('Withdrawal requested')).toBeVisible();
	await expect(panel.getByText(`₦48,000.00 · ${reference}`)).toBeVisible();
	await expect(panel.getByText('Payout account added')).toBeVisible();
	await expect(panel.getByRole('button', { name: 'Unread · 3' })).toHaveAttribute(
		'aria-pressed',
		'true'
	);
	await expectAccessible(page);
	await shot(page, 'S01-bell-member');
	await panel.getByText('Withdrawal requested').click();
	await expect(page).toHaveURL(/\/app\/withdrawals$/);
	await expect(page.getByRole('button', { name: /^Notifications, 2 unread$/ })).toBeVisible();

	// Member, mobile S04.
	await page.setViewportSize(MOBILE);
	await page.goto('/app/notifications');
	await expect(page.getByText('New', { exact: true })).toBeVisible();
	await expect(page.getByText('Earlier', { exact: true })).toBeVisible();
	await expect(page.getByText('You’re all caught up.')).toBeVisible();
	await expectAccessible(page);
	await shot(page, 'S04-notifications-mobile');
	await page.getByRole('button', { name: 'Read all' }).click();
	await expect(page.getByRole('button', { name: 'Read all' })).toBeHidden();

	// A tab whose workspace is no longer the selected one gets nothing.
	const stale = await page.request.get('/api/notifications?view=all', {
		headers: { 'x-ew-workspace': '00000000-0000-4000-8000-000000000000' }
	});
	expect(stale.status()).toBe(403);
	expect(((await stale.json()) as { error: { code: string } }).error.code).toBe(
		'workspace_invalid'
	);

	// Emails reach the mail catcher, with amount and reference only.
	const submitted = await mailFor(member, /^Withdrawal requested$/);
	expect(submitted.HTML).toContain('₦48,000.00');
	expect(submitted.HTML).toContain(reference);
	expect(submitted.HTML).toContain('support@elivatewallet.com');
	expect(submitted.HTML).toContain('Bell Test Network');
	expect(submitted.HTML).not.toContain('0123456789');
	const income = await mailFor(member, /^Income is in your pockets$/);
	expect(income.HTML).toContain('₦180,000.00');
	const awaiting = await mailFor(founder.email, /^A withdrawal needs your approval$/);
	expect(awaiting.HTML).toContain('/app/queue?withdrawal=');
	expect(awaiting.HTML).not.toMatch(/0123456789|6789/);

	// President, desktop NB01: the task under Needs your action.
	await asPresident(page, founder.email, 'Bell Test Network');
	await page.setViewportSize(DESKTOP);
	await page.goto('/app');
	await page.getByRole('button', { name: /^Notifications/ }).click();
	const leaderPanel = page.locator('.popover.notifications');
	await expect(leaderPanel.getByText('Withdrawal to approve')).toBeVisible();
	await expect(leaderPanel.getByText(/₦48,000\.00 to .* •• 6789/)).toBeVisible();
	// The open panel covers the network home's currency switch (Blueprint 25),
	// which navigation.e2e.ts scans with nothing over it.
	await expectAccessible(page, ['.hero .switch']);
	await shot(page, 'NB01-bell-leader-desktop');
	await leaderPanel.getByText('Withdrawal to approve').click();
	await expect(page).toHaveURL(/\/app\/queue\?withdrawal=/);
	const queue = page.getByRole('region', { name: new RegExp(`Withdrawal ${reference}`) });
	await queue.getByRole('button', { name: 'Approve' }).click();
	await expect(page.getByText(/^Approved\./)).toBeVisible();

	// The approval task cleared; the approver now has a payout to record.
	await page.goto('/app');
	await page.getByRole('button', { name: /^Notifications/ }).click();
	const after = page.locator('.popover.notifications');
	await expect(after.getByText('Payout to record')).toBeVisible();
	await expect(after.getByText('Withdrawal to approve')).toBeHidden();

	await page.setViewportSize(MOBILE);
	await page.goto('/app/notifications');
	await expect(page.getByText('Needs your action')).toBeVisible();
	await expect(page.getByText('Payout to record')).toBeVisible();
	await shot(page, 'NB01-bell-leader-mobile');

	const approved = await mailFor(member, /^Your withdrawal is approved$/);
	expect(approved.HTML).toContain('Payout is next.');

	await signInAs(page, member);
	await page.goto('/app/notifications');
	await expect(page.getByText('Withdrawal approved')).toBeVisible();
});

// One sample of every Blueprint 13 email, through the real worker and the
// fake Cloudflare into Mailpit, then rendered in the browser for review.
const SAMPLES: ReadonlyArray<readonly [string, string, Record<string, string>]> = [
	[
		'M01',
		'money.income_posted',
		{ amount: '180000.00', reference: 'INC-7F2K-0931', path: '/app/activity' }
	],
	['M02', 'money.withdrawal_submitted', { path: '/app/withdrawals' }],
	[
		'M03',
		'money.withdrawal_awaiting_approval',
		{ member: 'Ada N.', office: 'Lagos office', path: '/app/queue' }
	],
	['M04', 'money.withdrawal_approved', { path: '/app/withdrawals' }],
	['M05', 'money.withdrawal_completed', { firstName: 'Ada', path: '/app/withdrawals' }],
	['M06', 'money.withdrawal_not_approved', { path: '/app/withdrawals' }],
	['M07', 'money.withdrawal_cancelled', { path: '/app/withdrawals' }],
	['M08', 'money.payout_correction_required', { path: '/app/queue' }],
	['M09', 'money.evidence_review_assigned', { subject: 'payout', path: '/app/evidence' }],
	[
		'M10',
		'money.pocket_move_done',
		{ amount: '20000.00', reference: 'PTR-4B8Q-2210', from: 'Savings', to: 'Upkeep', path: '/app' }
	],
	[
		'M11',
		'money.pocket_move_declined',
		{ amount: '20000.00', reference: 'PTR-4B8Q-2210', path: '/app' }
	],
	[
		'M12',
		'money.adjustment_posted',
		{
			amount: '12500.00',
			reference: 'ADJ-2M6T-0412',
			direction: 'credit',
			actor: 'Ifeoma O.',
			path: '/app/activity'
		}
	],
	[
		'M13',
		'money.transaction_reversed',
		{
			amount: '180000.00',
			reference: 'REV-3K8D-1140',
			reverses: 'INC-7F2K-0931',
			path: '/app/activity'
		}
	],
	[
		'M14',
		'money.returned_funds',
		{ reference: 'RTN-6P1C-0388', withdrawal: 'WDR-9C1M-0877', path: '/app/activity' }
	],
	[
		'M16',
		'money.conversion_posted',
		{
			amount: '180000.00',
			reference: 'CNV-5H2R-0716',
			destinationAmount: '120.00',
			destinationCurrency: 'USD',
			actor: 'Ifeoma O.',
			path: '/app/activity'
		}
	],
	['M17', 'money.payout_receipt_rejected', { path: '/app/queue' }],
	[
		'M18',
		'money.entry_not_posted',
		{ amount: '12500.00', reference: 'ADJ-2M6T-0412', subject: 'adjustment', path: '/app/adjust' }
	],
	[
		'T01',
		'team.invitation_accepted',
		{
			member: 'Ada Nwosu',
			firstName: 'Ada',
			office: 'Lagos office',
			role: 'member',
			path: '/app/members'
		}
	],
	['A10', 'account.status_changed', { status: 'restricted', path: '/app' }],
	[
		'A11',
		'account.role_changed',
		{ role: 'team_leader', office: 'Lagos office', actor: 'Ifeoma O.', path: '/app' }
	],
	['A12', 'account.membership_ended', { office: 'Abuja office', path: '/app/activity' }],
	// Blueprint 16: B01–B05 (Paper "Emails — Transactional v2").
	[
		'B01',
		'billing.payment_received',
		{
			amount: '700000.00',
			reference: 'PAY-5R2N-0042',
			path: '/app/billing/payments/0b0e7b5c-6d3a-4f4e-9a52-6c2f1f7e8a10'
		}
	],
	[
		'B02',
		'billing.renewal_reminder',
		{ amount: '700000.00', due: '12 Jan 2027', chip: 'Renews soon', path: '/app/billing' }
	],
	['B03', 'billing.owner_assigned', { path: '/app/billing' }],
	['B04', 'billing.seats_almost_full', { used: '384', cap: '400', path: '/app/billing' }],
	['B05', 'billing.paused', { path: '/app/billing' }]
];

test('every notification email is delivered and rendered from its Paper artboard', async ({
	page
}) => {
	const to = uniqueEmail('samples');
	const base = {
		network: 'Cedar Network',
		amount: '48000.00',
		currency: 'NGN',
		reference: 'WDR-9C1M-0877'
	};
	for (const [code, template, extra] of SAMPLES) {
		const allowed = localSql(
			`select array_to_string(params, ',') from outbox.templates where key = '${template}'`
		).split(',');
		const params = Object.fromEntries(
			Object.entries({ ...base, ...extra }).filter(([k]) => allowed.includes(k))
		);
		localSql(`select outbox.enqueue_email('${template}', 'e2e-sample:${code}:${to}', 'sample', gen_random_uuid(), null, null,
      '${to}', '${JSON.stringify(params).replaceAll("'", "''")}'::jsonb)`);
	}
	// Other files send email too: run the worker until every sample is out.
	for (let i = 0; i < 20; i++) {
		await runOutboxWorker();
		const sent =
			localSql(`select count(*) from outbox.deliveries d join outbox.events e on e.id = d.event_id
      where e.recipient_email = '${to}' and d.status = 'sent'`);
		if (sent === String(SAMPLES.length)) break;
		await new Promise((r) => setTimeout(r, 500));
	}
	const search = (await (
		await fetch(
			`${process.env.MAILPIT_URL ?? 'http://127.0.0.1:54324'}/api/v1/search?query=${encodeURIComponent(`to:"${to}"`)}&limit=50`
		)
	).json()) as { messages: Array<{ ID: string; Subject: string }> };
	expect(search.messages.length).toBe(SAMPLES.length);
	const sent =
		localSql(`select count(*) from outbox.deliveries d join outbox.events e on e.id = d.event_id
    where e.recipient_email = '${to}' and d.status = 'sent'`);
	expect(sent).toBe(String(SAMPLES.length));

	// Mailpit message → sample code, from the delivery's provider message id.
	const codes = new Map(
		localSql(`select d.provider_message_id || '|' || split_part(e.dedupe_key, ':', 2)
      from outbox.events e join outbox.deliveries d on d.event_id = e.id where e.recipient_email = '${to}'`)
			.split('\n')
			.map((line) => line.split('|') as [string, string])
	);
	for (const message of search.messages) {
		const detail = (await (
			await fetch(
				`${process.env.MAILPIT_URL ?? 'http://127.0.0.1:54324'}/api/v1/message/${message.ID}`
			)
		).json()) as { HTML: string; Subject: string };
		expect(detail.HTML).toContain('support@elivatewallet.com');
		expect(detail.HTML).not.toMatch(/0123456789/);
		const code = codes.get(`<${message.ID}@e2e>`);
		expect(code).toBeTruthy();
		for (const [label, size] of [
			['light', { width: 600, height: 700 }],
			['mobile-320', { width: 320, height: 700 }]
		] as const) {
			await page.setViewportSize(size);
			await page.setContent(detail.HTML, { waitUntil: 'load' });
			await shot(page, `email-${code}-${label}`);
		}
		await page.emulateMedia({ colorScheme: 'dark' });
		await page.setViewportSize({ width: 600, height: 700 });
		await page.setContent(detail.HTML, { waitUntil: 'load' });
		await shot(page, `email-${code}-dark`);
		await page.emulateMedia({ colorScheme: 'light' });
	}
});
