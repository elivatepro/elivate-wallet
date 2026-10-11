// Founder applications (Blueprint 19), against the local stack with synthetic
// people only (APP_SURFACE=both serves the Admin app beside the Wallet app).
// An applicant applies (A19), a platform admin approves with a reason and the
// PIN (A17), the founder invitation creates the account, the PIN comes next
// and the 7-day trial opens. A second applicant is not approved (A18) and the
// same email gets the same reply without a new application.
// E2E_SHOTS=<dir> keeps screenshots for review.

import type { Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	confirmLinkFor,
	createConfirmedAccount,
	expectAccessible,
	expectNoHorizontalScroll,
	humanReady,
	lightSetupWizard,
	localSql,
	mailFor,
	pick,
	setJoinPassword,
	shot,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN } = walletPeople;
const DESKTOP = { width: 1440, height: 900 };
const NARROW = { width: 320, height: 720 };

test.describe.configure({ mode: 'serial' });
test.setTimeout(240_000);

const tag = () => Math.random().toString(36).slice(2, 7);

async function makeAdmin(): Promise<string> {
	const email = uniqueEmail('fadm');
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

async function apply(page: Page, person: { name: string; email: string; team: string }) {
	await page.goto('/sign-in');
	await page.getByRole('link', { name: 'Start your network' }).click();
	await expect(page).toHaveURL(/\/apply$/);
	await expect(page.getByRole('heading', { name: 'Start your network' })).toBeVisible();
	await page.getByLabel('Full name').fill(person.name);
	await page.getByLabel('Phone number').fill('0803 555 0142');
	await page.getByLabel('Email address').fill(person.email);
	await page.getByLabel('Team name').fill(person.team);
	await pick(page.getByLabel('Your rank'), '4 Ruby Director');
	await humanReady(page);
	await page.getByRole('button', { name: 'Send application' }).click();
	// The first call may wake a cold Edge Function.
	await expect(page).toHaveURL(/\/apply\/sent$/, { timeout: 20_000 });
	await expect(page.getByRole('heading', { name: 'We have your application' })).toBeVisible();
}

/** Opens the A22b dialog for one applicant and records the decision. */
async function decide(page: Page, email: string, choice: 'approve' | 'reject', reason: string) {
	await page.goto('/admin/applications');
	const row = page.getByRole('row').filter({ hasText: email });
	await row.getByRole('link', { name: 'Review' }).click();
	const dialog = page.getByRole('dialog', { name: 'Review application' });
	await expect(dialog).toBeVisible();
	await page.waitForLoadState('networkidle');
	await dialog.getByLabel(choice === 'approve' ? /Approve · email/ : /Not approved · they/).check();
	await dialog.getByRole('textbox', { name: 'Reason' }).fill(reason);
	await dialog.getByLabel(/4-digit PIN/).fill(PIN);
	return dialog;
}

test('apply → admin approves → founder invitation → account → PIN → trial', async ({
	page,
	browser
}) => {
	const founder = { name: 'Adaeze Okafor', email: uniqueEmail('apply'), team: `Harmony ${tag()}` };

	// 13 → 14 (desktop), A19.
	await page.setViewportSize(DESKTOP);
	await page.goto('/apply');
	await expectAccessible(page);
	await shot(page, '13d-apply-desktop');
	await apply(page, founder);
	await expectAccessible(page);
	await shot(page, '14d-sent-desktop');
	const received = await mailFor(founder.email, /^We have your Elivate Wallet application$/);
	expect(received.HTML).toContain(founder.team);
	expect(received.HTML).toContain('root-founder-received.png');

	// The same email again: the same page, nothing new stored.
	await apply(page, { ...founder, team: 'Another Team' });
	expect(
		localSql(`select count(*) from founders.applications where email = '${founder.email}'`)
	).toBe('1');

	// A22 / A22b: an admin approves with a reason and the PIN.
	const admin = await browser.newContext({ viewport: DESKTOP });
	const adminPage = await admin.newPage();
	await adminSignIn(adminPage, await makeAdmin());
	await adminPage.getByRole('link', { name: 'Founder applications' }).first().click();
	await expect(adminPage).toHaveURL(/\/admin\/applications$/);
	await expect(adminPage.getByRole('row').filter({ hasText: founder.email })).toContainText(
		'4 Ruby Director'
	);
	await expectAccessible(adminPage);
	await shot(adminPage, 'A22d-applications-desktop');
	const dialog = await decide(adminPage, founder.email, 'approve', 'Rank confirmed by phone');
	await shot(adminPage, 'A22bd-review-desktop');
	await dialog.getByRole('button', { name: 'Approve' }).click();
	await expect(adminPage.getByRole('dialog')).toBeHidden();
	expect(
		localSql(`select status from founders.applications where email = '${founder.email}'`)
	).toBe('approved');
	await adminPage.getByRole('link', { name: 'Approved', exact: true }).click();
	await expect(adminPage.getByRole('row').filter({ hasText: founder.email })).toContainText(
		'Sent · until'
	);
	await adminPage.setViewportSize(NARROW);
	await expectNoHorizontalScroll(adminPage);
	await shot(adminPage, 'A22m-applications-mobile');
	await adminPage.setViewportSize(DESKTOP);

	// A17 carries the founder link; the reason never does.
	const approved = await mailFor(
		founder.email,
		/^You’re approved to start your network on Elivate Wallet$/
	);
	expect(approved.HTML).not.toContain('Rank confirmed');
	const link = approved.HTML.match(/href="(https?:\/\/[^"]*\/founder#t=[A-Za-z0-9_-]{43})"/)?.[1];
	expect(link).toBeTruthy();
	const path = new URL(link!).pathname + new URL(link!).hash;

	// The founder invitation (08 → 09) creates the account.
	await page.context().clearCookies();
	await page.goto(path);
	await expect(page.getByRole('heading', { name: 'Confirm your email' })).toBeVisible();
	await expect(
		page.getByText(`You’re approved to start ${founder.team}.`, { exact: false })
	).toBeVisible();
	expect(page.url()).not.toContain('#t=');
	await expectAccessible(page);
	await page.getByRole('button', { name: 'Verify email' }).click();
	await expect(page.getByRole('heading', { name: 'Check your inbox' })).toBeVisible();
	await page.goto(await confirmLinkFor(founder.email, /Confirm your Elivate Wallet email/));
	await page.getByRole('button', { name: 'Continue' }).click();
	await expect(page).toHaveURL(/\/founder$/);
	await setJoinPassword(page, PASSWORD);
	await page.getByRole('button', { name: 'Accept invitation' }).click();

	// PIN first, then network setup and the trial.
	await expect(page).toHaveURL(/\/pin\/setup\?next=\/setup$/);
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByLabel('Repeat PIN').fill(PIN);
	await page.getByRole('button', { name: 'Save PIN' }).click();
	// Blueprint 22: the light setup (name, photo, rank) before naming the network.
	await lightSetupWizard(page);
	await page.getByRole('link', { name: 'Set up your network' }).click();
	await expect(page).toHaveURL(/\/setup$/);
	await page.getByLabel('Network name').fill(founder.team);
	await page.getByRole('button', { name: 'Continue' }).click();
	await page.getByRole('button', { name: 'Start 7-day free trial' }).click();
	await expect(page).toHaveURL(/\/app\/billing$/);
	await expect(page.getByText('Free trial')).toBeVisible();
	expect(
		localSql(`select f.source from founders.approved f join auth.users u on u.id = f.user_id
		  where u.email = '${founder.email}'`)
	).toBe('application');

	// The link is spent.
	await page.context().clearCookies();
	await page.goto(path);
	await expect(page.getByRole('heading', { name: 'Invitation unavailable' })).toBeVisible();
	await admin.close();
});

test('not approved → A18; the same email is told the same thing', async ({ page, browser }) => {
	const applicant = { name: 'Ngozi Umeh', email: uniqueEmail('reject'), team: `Golden ${tag()}` };
	await apply(page, applicant);

	const admin = await browser.newContext({ viewport: DESKTOP });
	const adminPage = await admin.newPage();
	await adminSignIn(adminPage, await makeAdmin());
	const dialog = await decide(adminPage, applicant.email, 'reject', 'Rank not confirmed yet');
	await dialog.getByRole('button', { name: 'Save decision' }).click();
	await expect(adminPage.getByRole('dialog')).toBeHidden();
	await adminPage.getByRole('link', { name: 'Not approved' }).click();
	await expect(adminPage.getByRole('row').filter({ hasText: applicant.email })).toBeVisible();

	const rejected = await mailFor(applicant.email, /^Your Elivate Wallet application$/);
	expect(rejected.HTML).toContain('You can apply again after 30 days.');
	expect(rejected.HTML).not.toContain('Rank not confirmed');

	await apply(page, applicant);
	expect(
		localSql(`select count(*) from founders.applications where email = '${applicant.email}'`)
	).toBe('1');
	await admin.close();
});

test('a signed-in person without approval is sent to the application', async ({ page }) => {
	const email = uniqueEmail('noapp');
	await createConfirmedAccount(email, PASSWORD, PIN);
	await walletPeople.signInAs(page, email);
	await page.goto('/setup');
	await expect(page).toHaveURL(/\/apply$/);
	await expect(page.getByLabel('Email address')).toHaveValue(email);
	await expect(page.getByRole('link', { name: 'Back to workspaces' })).toBeVisible();
});

test.describe('320 px, both themes', () => {
	test.use({ viewport: NARROW });
	for (const theme of ['dark', 'light'] as const) {
		test(`apply pages in ${theme}`, async ({ page, context }) => {
			await context.addCookies([{ name: 'ew_theme', value: theme, url: 'http://127.0.0.1:3000' }]);
			for (const path of ['/apply', '/apply/sent', '/founder']) {
				await page.goto(path);
				await expectNoHorizontalScroll(page);
				await expectAccessible(page);
			}
			await page.goto('/apply');
			await shot(page, `13m-apply-${theme}`);
		});
	}
});
