// Billing (Blueprint 16, W-19) against the local stack with synthetic people
// and a fake Paystack (fake-providers.mjs: a local "hosted checkout" that
// signs its webhook with the run's throwaway test key). Covers founder setup
// with the trial (PL01, PL02, PL04), an upgrade through Paystack (PL05 → v2
// B05), renewal (PL08d, PL09d), the owner dialog (v2 B01), a pay-first
// network with a cancelled then a paid checkout (PL11, PL03, PL10d), the seat
// cap (E03) and a paused network (PL06, PL07d, B05 email).
// E2E_SHOTS=<dir> keeps screenshots for the Paper comparison.

import type { Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	apiSession,
	createConfirmedAccount,
	expectAccessible,
	expectNoHorizontalScroll,
	localSql,
	mailFor,
	shot,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, memberWithAccount, signInAs, asPresident } = walletPeople;
const MOBILE = { width: 390, height: 844 };
const DESKTOP = { width: 1440, height: 900 };
const SUPABASE_URL = process.env.SUPABASE_URL ?? '';
const BILLING_WORKER_SECRET = process.env.BILLING_WORKER_SECRET ?? '';

test.describe.configure({ mode: 'serial' });
test.setTimeout(180_000);

const tag = () => Math.random().toString(36).slice(2, 7);

/** Runs the Paystack subscription sync once, as pg_cron would. */
async function runBillingSync() {
	const response = await fetch(`${SUPABASE_URL}/functions/v1/billing/worker/sync`, {
		method: 'POST',
		headers: {
			authorization: `Bearer ${BILLING_WORKER_SECRET}`,
			'content-type': 'application/json'
		},
		body: '{}'
	});
	expect(response.status).toBe(200);
}

/** Pays (or cancels) on the fake Paystack page and lands back on the payment screen. */
async function onPaystack(page: Page, action: 'Pay' | 'Cancel payment') {
	await expect(page.getByRole('heading', { name: 'Paystack test checkout' })).toBeVisible();
	await page.getByRole('button', { name: action, exact: true }).click();
	await expect(page).toHaveURL(/\/app\/billing\/payments\/[0-9a-f-]{36}\?trxref=/);
}

const tenantOf = (email: string, role = 'president_team_member') =>
	`(select m.tenant_id from org.memberships m join auth.users u on u.id = m.user_id
	  where u.email = '${email}' and m.role = '${role}' order by m.started_at desc limit 1)`;

test('a founder starts the trial, upgrades through Paystack and manages renewal', async ({
	page
}) => {
	const email = uniqueEmail('founder');
	const network = `Cedar ${tag()}`;
	await createConfirmedAccount(email, PASSWORD, PIN);
	await signInAs(page, email);
	await page.setViewportSize(DESKTOP);
	await expect(page).toHaveURL(/\/workspaces/);
	await page.getByRole('link', { name: 'Start a network' }).click();

	// PL01 → PL02 (trial available).
	await expect(page.getByRole('heading', { name: 'Name your network' })).toBeVisible();
	await shot(page, 'PL01-name-desktop');
	await page.getByLabel('Network name').fill(network);
	await page.getByRole('button', { name: 'Continue' }).click();
	await expect(page.getByRole('heading', { name: 'Choose a plan' })).toBeVisible();
	await expect(page.getByText('Start free for 7 days, then pay yearly.')).toBeVisible();
	await shot(page, 'PL02-plan-desktop');
	await page.setViewportSize(MOBILE);
	await shot(page, 'PL02-plan-mobile');
	await expectNoHorizontalScroll(page);
	await page.setViewportSize(DESKTOP);
	await page.getByRole('button', { name: 'Start 7-day free trial' }).click();

	// PL04: the trial is running.
	await expect(page).toHaveURL(/\/app\/billing$/);
	await expect(page.getByText('Free trial')).toBeVisible();
	await expect(page.getByRole('heading', { name: /7 days left|6 days left/ })).toBeVisible();
	await expect(page.getByText('of 400 people')).toBeVisible();
	await expectAccessible(page);
	await shot(page, 'PL04-trial-desktop');
	await page.setViewportSize(MOBILE);
	await expectNoHorizontalScroll(page);
	await shot(page, 'PL04-trial-mobile');
	await page.setViewportSize(DESKTOP);

	// Owner dialog (v2 B01): nobody else to choose yet.
	await page.getByRole('button', { name: 'Change' }).click();
	await expect(page.getByRole('dialog', { name: 'Change Billing Owner' })).toBeVisible();
	await shot(page, 'B01v2-owner-desktop');
	await page.getByRole('button', { name: 'Cancel' }).click();

	// PL05 from the plan list: a bigger band during the trial is a full year.
	await page
		.getByRole('listitem')
		.filter({ hasText: 'Up to 1,000 users' })
		.getByRole('button', { name: 'Upgrade' })
		.click();
	const dialog = page.getByRole('dialog', { name: 'Move up a plan' });
	await expect(dialog).toBeVisible();
	await expect(dialog.getByText('₦1,000,000.00').first()).toBeVisible();
	await shot(page, 'PL05-upgrade-desktop');
	await dialog.getByRole('button', { name: 'Pay ₦1,000,000.00' }).click();
	await onPaystack(page, 'Pay');

	// v2 B05: confirmed server-side (webhook + verification), never by the redirect.
	await expect(page.getByRole('heading', { name: 'Payment confirmed' })).toBeVisible();
	await expect(page.getByText(/^PAY-[0-9A-Z]{4}-[0-9A-Z]{4}$/)).toBeVisible();
	await shot(page, 'B05v2-confirmed-desktop');
	await page.setViewportSize(MOBILE);
	await expectNoHorizontalScroll(page);
	await shot(page, 'B06v2-confirmed-mobile');
	await page.setViewportSize(DESKTOP);

	// B01 to the Billing Owner, with the exact amount and the PAY reference.
	const receipt = await mailFor(email, /^Payment received$/);
	expect(receipt.HTML).toContain('₦1,000,000.00');
	expect(receipt.HTML).toMatch(/PAY-[0-9A-Z]{4}-[0-9A-Z]{4} · Paystack/);
	expect(receipt.HTML).not.toContain('ewp_');

	// PL08d: active; the card renews it once Paystack's subscription is set up.
	await runBillingSync();
	await page.getByRole('link', { name: 'Back to Billing' }).click();
	await expect(page.getByText('Active', { exact: true })).toBeVisible();
	await expect(page.getByText(/^Auto-renews /)).toBeVisible();
	await shot(page, 'PL08d-active-desktop');
	await page.setViewportSize(MOBILE);
	await expectNoHorizontalScroll(page);
	await shot(page, 'PL08d-active-mobile');
	await page.setViewportSize(DESKTOP);

	// PL09d: manage renewal, turn it off.
	await page.getByRole('button', { name: 'Manage renewal' }).click();
	await expect(page.getByRole('dialog', { name: 'Renewal' })).toBeVisible();
	await shot(page, 'PL09d-renewal-desktop');
	await page.getByRole('button', { name: 'Turn off auto-renew' }).click();
	await expect(page.getByText('Renews by payment')).toBeVisible();
	expect(
		localSql(`select auto_renew from billing.subscriptions where tenant_id = ${tenantOf(email)}`)
	).toBe('f');
});

test('a second network pays first; a cancelled checkout charges nothing', async ({ page }) => {
	const email = uniqueEmail('founder2');
	await createConfirmedAccount(email, PASSWORD, PIN);
	// The founder's one trial is already used on their first network.
	const api = await apiSession(email, PASSWORD, PIN);
	await api.call('org', '/networks', {
		name: `Birch ${tag()}`,
		shortName: 'Birch',
		planKey: 'band_400',
		trial: true,
		idempotencyKey: crypto.randomUUID()
	});
	await api.close();

	await signInAs(page, email);
	await page.setViewportSize(DESKTOP);
	await page.goto('/setup');
	await page.getByLabel('Network name').fill(`Oak ${tag()}`);
	await page.getByRole('button', { name: 'Continue' }).click();
	// PL11: the trial is used; every band pays first.
	await expect(
		page.getByText('You’ve used your free trial. Pay yearly to open this network.')
	).toBeVisible();
	await page.getByText('1,001+ people').click();
	await shot(page, 'PL11-trial-used-desktop');
	await page.setViewportSize(MOBILE);
	await shot(page, 'PL11-trial-used-mobile');
	await page.setViewportSize(DESKTOP);
	await page.getByRole('button', { name: 'Continue to payment' }).click();

	// PL03: Paystack hand-off with the PAY reference.
	await expect(page).toHaveURL(/\/setup\/pay$/);
	await expect(page.getByRole('heading', { name: 'Pay on Paystack' })).toBeVisible();
	await expect(page.getByText(/^PAY-[0-9A-Z]{4}-[0-9A-Z]{4}$/)).toBeVisible();
	await shot(page, 'PL03-handoff-desktop');
	await page.setViewportSize(MOBILE);
	await expectNoHorizontalScroll(page);
	await shot(page, 'PL03-handoff-mobile');
	await page.setViewportSize(DESKTOP);
	await page.getByRole('link', { name: 'Pay ₦1,500,000.00' }).click();
	await onPaystack(page, 'Cancel payment');

	// PL10d: not completed; the network is still waiting.
	await expect(page.getByRole('heading', { name: 'Payment not completed' })).toBeVisible();
	await shot(page, 'PL10d-not-completed-desktop');
	await page.setViewportSize(MOBILE);
	await shot(page, 'PL10d-not-completed-mobile');
	await page.setViewportSize(DESKTOP);
	await page.getByRole('link', { name: 'Try again' }).click();
	await expect(page.getByText('Awaiting payment')).toBeVisible();
	await shot(page, 'PL-pending-billing-desktop');
	await page.getByRole('button', { name: 'Pay ₦1,500,000.00' }).click();
	await onPaystack(page, 'Pay');
	await expect(page.getByRole('heading', { name: 'Payment confirmed' })).toBeVisible();
	expect(localSql(`select t.status from org.tenants t where t.id = ${tenantOf(email)}`)).toBe(
		'active'
	);
});

test('at the seat cap invitations stop; a paused network keeps money visible', async ({ page }) => {
	const founder = { email: uniqueEmail('pres'), password: PASSWORD, pin: PIN };
	const member = uniqueEmail('member');
	const network = `Pine ${tag()}`;
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await memberWithAccount(founder, network, member);
	const tenant = tenantOf(founder.email);

	// A trial on the smallest band, filled to its 400 seats with synthetic people.
	localSql(`update billing.subscriptions set status = 'trial', kind = 'trial',
	  plan_id = (select id from billing.plans where key = 'band_400'),
	  period_start = now(), period_end = now() + interval '5 days' where tenant_id = ${tenant}`);
	localSql(`with people as (
	    insert into auth.users (id, email, aud, role)
	    select gen_random_uuid(), 'seat-' || gen_random_uuid() || '@fill.test', 'authenticated', 'authenticated'
	    from generate_series(1, 400 - billing.seats_used(${tenant})) returning id)
	  insert into org.memberships (tenant_id, office_id, user_id, role, is_primary, created_by)
	  select ${tenant}, (select id from org.offices where tenant_id = ${tenant} limit 1), id, 'member', true,
	    (select created_by from org.tenants where id = ${tenant}) from people`);
	expect(localSql(`select billing.seats_used(${tenant})`)).toBe('400');

	// E03: the President is told the network is full and offered the upgrade.
	await asPresident(page, founder.email, network);
	await page.setViewportSize(DESKTOP);
	await page.goto('/app/invitations');
	await page
		.getByRole('button', { name: /Invite/ })
		.first()
		.click();
	await page.getByLabel('Email address').fill(uniqueEmail('late'));
	await page
		.getByRole('button', { name: /Send invitation|Invite/ })
		.last()
		.click();
	await expect(page.getByRole('dialog', { name: 'Can’t add members right now' })).toBeVisible();
	await shot(page, 'E03-seat-limit-desktop');
	await page.getByRole('button', { name: 'Not now' }).click();

	// The trial ends unpaid: paused at once, no grace.
	localSql(`update billing.subscriptions set period_start = now() - interval '7 days',
	  period_end = now() - interval '1 minute' where tenant_id = ${tenant}`);
	localSql(`select billing.run_lifecycle()`);
	expect(localSql(`select status from org.tenants where id = ${tenant}`)).toBe('suspended');

	// PL07d: leaders see the pay-to-resume view.
	await page.goto('/app/billing');
	await expect(page.getByRole('heading', { name: 'Paused' })).toBeVisible();
	await expect(page.getByText('Pay to resume')).toBeVisible();
	await shot(page, 'PL07d-paused-billing-desktop');
	await page.setViewportSize(MOBILE);
	await expectNoHorizontalScroll(page);
	await shot(page, 'PL07d-paused-billing-mobile');

	// B05 says pay to resume.
	const paused = await mailFor(founder.email, /^Your plan is paused$/);
	expect(paused.HTML).toContain('Pay to turn it back on.');

	// PL06: the member still sees their money, with the paused banner.
	await signInAs(page, member);
	await page.setViewportSize(DESKTOP);
	await page.goto('/app');
	await expect(page.getByText(`${network} is paused`)).toBeVisible();
	await shot(page, 'PL06-paused-member-desktop');
	await page.setViewportSize(MOBILE);
	await expectNoHorizontalScroll(page);
	await shot(page, 'PL06-paused-member-mobile');
});
