// Platform Admin app (Blueprint 18), against the local stack with synthetic
// people only (APP_SURFACE=both serves /admin/* beside the Wallet app). An
// admin signs in with password + PIN, searches, suspends and reactivates an
// account (reason + PIN), stops withdrawals so a member sees the paused banner,
// starts them again, and validates a restore request end to end (archive
// re-read, differences, restoring, completed). Sessions stay separate per
// site, and a non-admin only sees "not an admin".
// E2E_SHOTS=<dir> keeps screenshots for review.

import type { Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	apiSession,
	createConfirmedAccount,
	expectAccessible,
	expectNoHorizontalScroll,
	localSql,
	shot,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, memberWithAccount, signInAs } = walletPeople;
const DESKTOP = { width: 1440, height: 900 };
const NARROW = { width: 320, height: 720 };
const SECRET = process.env.EXPORTS_WORKER_SECRET ?? '';

test.describe.configure({ mode: 'serial' });
test.setTimeout(240_000);

const key = () => crypto.randomUUID();
const uidFor = (email: string) =>
	localSql(
		`select a.uid from identity.accounts a join auth.users u on u.id = a.user_id where u.email = '${email}'`
	).trim();

async function makeAdmin(): Promise<string> {
	const email = uniqueEmail('adm');
	await createConfirmedAccount(email, PASSWORD, PIN);
	localSql(
		`insert into identity.platform_admins (user_id, grant_reason)
		 select id, 'e2e local admin' from auth.users where email = '${email}'`
	);
	return email;
}

async function adminSignIn(page: Page, email: string) {
	await page.goto('/admin/sign-in');
	await page.getByLabel('Email address').fill(email);
	await page.getByLabel('Password', { exact: true }).fill(PASSWORD);
	await page.getByRole('button', { name: 'Continue' }).click();
	await expect(page.getByRole('heading', { name: 'Enter your PIN' })).toBeVisible();
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByRole('button', { name: 'Verify' }).click();
	await expect(page).toHaveURL(/\/admin$/);
}

/** Fills the open admin dialog (reason + PIN) and submits it. */
async function confirm(page: Page, reason: string, submit: string) {
	await page.waitForLoadState('networkidle');
	const dialog = page.getByRole('dialog');
	await dialog.getByRole('textbox', { name: /Reason|Notes/ }).fill(reason);
	await dialog.getByLabel(/4-digit PIN/).fill(PIN);
	await dialog.getByRole('button', { name: submit }).click();
	await expect(page.getByRole('dialog')).toBeHidden();
}

test('a non-admin sees "not an admin"; each site keeps its own session', async ({ page }) => {
	const founder = { email: uniqueEmail('adm-x'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);

	// Signed in to the Wallet app is not signed in to the admin site.
	await signInAs(page, founder.email);
	await page.goto('/admin');
	await expect(page).toHaveURL(/\/admin\/sign-in$/);

	await page.getByLabel('Email address').fill(founder.email);
	await page.getByLabel('Password', { exact: true }).fill(PASSWORD);
	await page.getByRole('button', { name: 'Continue' }).click();
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByRole('button', { name: 'Verify' }).click();
	await expect(page.getByRole('heading', { name: 'This account isn’t an admin' })).toBeVisible();
	// Blueprint 20 B7: pages no longer await parent(); the gate still runs on each one.
	for (const path of [
		'/admin',
		'/admin/networks',
		'/admin/accounts',
		'/admin/search?q=x',
		'/admin/audit',
		'/admin/admins',
		'/admin/switches',
		'/admin/emails',
		'/admin/nin',
		'/admin/applications',
		'/admin/backups',
		'/admin/more'
	]) {
		await page.goto(path);
		await expect(page, path).toHaveURL(/\/admin\/no-access$/);
	}

	const cookies = await page.context().cookies();
	const admin = cookies.filter((c) => c.name.startsWith('ew-admin-auth'));
	expect(admin.length).toBeGreaterThan(0);
	expect(admin.every((c) => c.httpOnly && c.sameSite === 'Strict')).toBe(true);
});

test('an admin searches, suspends and reactivates an account with reason + PIN', async ({
	page
}) => {
	const adminEmail = await makeAdmin();
	const founder = { email: uniqueEmail('adm-f'), password: PASSWORD, pin: PIN };
	const member = uniqueEmail('adm-m');
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await memberWithAccount(founder, 'Cedar Admin', member);
	const memberUid = uidFor(member);

	await page.setViewportSize(DESKTOP);
	await adminSignIn(page, adminEmail);
	await expect(page.getByRole('heading', { name: 'Kill switches' })).toBeVisible();
	await expectAccessible(page);
	await shot(page, 'A03-overview');

	await page.goto(`/admin/search?q=${memberUid}`);
	await page
		.getByRole('link', { name: new RegExp(memberUid) })
		.first()
		.click();
	await expect(page).toHaveURL(new RegExp(`/admin/accounts/${memberUid}$`));
	await expect(page.getByText('Memberships')).toBeVisible();
	await expectAccessible(page);

	await page.getByRole('link', { name: 'Change account status' }).click();
	await page.waitForLoadState('networkidle');
	await page.getByRole('dialog').getByLabel('New status').selectOption('suspended');
	await shot(page, 'A09b-status');
	// A wrong PIN keeps the dialog open with the error and the typed reason.
	const dialog = page.getByRole('dialog');
	await dialog.getByRole('textbox', { name: /Reason/ }).fill('Wrong PIN first.');
	await dialog.getByLabel(/4-digit PIN/).fill(PIN === '0000' ? '1111' : '0000');
	await dialog.getByRole('button', { name: 'Suspend account' }).click();
	await expect(page.getByRole('dialog')).toBeVisible();
	await expect(page).toHaveURL(/dialog=/);
	await expect(page.getByRole('dialog').getByRole('textbox', { name: /Reason/ })).toHaveValue(
		'Wrong PIN first.'
	);
	await confirm(page, 'Suspicious sign-in reported by the office.', 'Suspend account');
	await expect(page.getByText('Suspended').first()).toBeVisible();
	expect(localSql(`select status from identity.accounts where uid = '${memberUid}'`).trim()).toBe(
		'suspended'
	);

	await page.getByRole('link', { name: 'Change account status' }).click();
	await page.waitForLoadState('networkidle');
	await page.getByRole('dialog').getByLabel('New status').selectOption('active');
	await confirm(page, 'Security review finished.', 'Reactivate account');
	expect(localSql(`select status from identity.accounts where uid = '${memberUid}'`).trim()).toBe(
		'active'
	);

	// The networks list finds the network; narrow screens never scroll sideways.
	await page.goto('/admin/networks?q=Cedar%20Admin');
	await expect(page.getByRole('link', { name: /Cedar Admin/ })).toBeVisible();
	await page.setViewportSize(NARROW);
	await expectNoHorizontalScroll(page);
	await expectAccessible(page);
});

test('stopping withdrawals pauses new requests for members; starting them again restores it', async ({
	page,
	browser
}) => {
	const adminEmail = await makeAdmin();
	const founder = { email: uniqueEmail('ks-f'), password: PASSWORD, pin: PIN };
	const member = uniqueEmail('ks-m');
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await memberWithAccount(founder, 'Cedar Switch', member);

	await page.setViewportSize(DESKTOP);
	await adminSignIn(page, adminEmail);
	await page.goto('/admin/switches');
	await page.getByRole('switch', { name: 'Withdrawals: running, stop' }).click();
	await expect(page.getByRole('dialog')).toContainText('every network');
	await shot(page, 'A11b-stop');
	await confirm(page, 'Bank partner outage reported.', 'Stop withdrawals');
	await expect(page.getByText('Stopped').first()).toBeVisible();

	try {
		const memberPage = await (await browser.newContext()).newPage();
		await signInAs(memberPage, member);
		await memberPage.goto('/app/withdrawals/new');
		await expect(
			memberPage.getByRole('heading', { name: 'Withdrawals are paused for now' })
		).toBeVisible();
		// The page stays below the banner, so open attempts can still be recovered.
		await expect(memberPage.getByRole('heading', { name: 'Withdraw to your bank' })).toBeVisible();
		await shot(memberPage, 'X-withdrawals-paused');
		await memberPage.context().close();
	} finally {
		// Always start withdrawals again: other test files share the stack.
		await page.goto('/admin/switches?dialog=start&key=withdrawals');
		await confirm(page, 'Bank partner is back.', 'Start withdrawals');
	}
	expect(
		localSql(
			`select stopped from platform.kill_switches where key = 'withdrawals' and tenant_id is null`
		).trim()
	).toBe('f');
	expect(
		Number(localSql(`select count(*) from audit.security_events where action like 'kill_switch.%'`))
	).toBeGreaterThanOrEqual(2);
});

test('a restore request is validated, reviewed, restored by hand and completed', async ({
	page
}) => {
	const adminEmail = await makeAdmin();
	const founder = { email: uniqueEmail('rs-f'), password: PASSWORD, pin: PIN };
	const member = uniqueEmail('rs-m');
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await memberWithAccount(founder, 'Cedar Restore', member);

	// The President backs up the network (real runner) and asks for a restore.
	const api = await apiSession(founder.email, PASSWORD, PIN);
	const workspaces = await api.call<Array<{ membershipId: string; role: string }>>(
		'org',
		'/workspaces'
	);
	const president = workspaces.find((w) => w.role === 'president_team_member')!.membershipId;
	const started = await api.call<{ backup: { backupId: string } }>(
		'org',
		'/backups',
		{ idempotencyKey: key() },
		president
	);
	const run = await page.request.post('/internal/exports/run', {
		headers: { authorization: `Bearer ${SECRET}` },
		data: {}
	});
	expect(run.status()).toBe(200);
	await expect
		.poll(() =>
			localSql(`select status from backups.archives where id = '${started.backup.backupId}'`)
		)
		.toBe('ready');
	const requested = await api.call<{ restore: { restoreId: string; reference: string } }>(
		'org',
		'/restores',
		{
			backupId: started.backup.backupId,
			reason: 'An office was closed by mistake. Compare with this backup.',
			idempotencyKey: key()
		},
		president
	);
	await api.close();
	const restoreId = requested.restore.restoreId;

	await page.setViewportSize(DESKTOP);
	await adminSignIn(page, adminEmail);
	await page.goto('/admin/backups');
	await expect(page.getByText(requested.restore.reference).first()).toBeVisible();
	await expectAccessible(page);
	await page.goto(`/admin/backups/${restoreId}`);
	await page.getByRole('link', { name: 'Start validating' }).click();
	await confirm(page, 'Checking the archive.', 'Start validating');
	await expect(page.getByText('Passed')).toBeVisible({ timeout: 60_000 });
	await expect(page.getByRole('heading', { name: 'Differences' })).toBeVisible();
	await expect(page.getByText('Kept · never overwritten').first()).toBeVisible();
	await shot(page, 'A15r-review');
	expect(
		localSql(`select status from backups.restore_requests where id = '${restoreId}'`).trim()
	).toBe('in_review');

	await page.getByRole('link', { name: 'Start restoring' }).click();
	await confirm(page, 'Re-opening the office by hand.', 'Start restoring');
	await page.getByRole('link', { name: 'Mark completed' }).click();
	await confirm(page, 'Office re-opened by hand; nothing else changed.', 'Mark completed');
	expect(
		localSql(`select status from backups.restore_requests where id = '${restoreId}'`).trim()
	).toBe('completed');
	await page.setViewportSize(NARROW);
	await expectNoHorizontalScroll(page);
});
