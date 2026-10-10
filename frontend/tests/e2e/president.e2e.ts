// Slice 21 (owner feedback): a President Team member reaches Invitations from
// every Invite entry, sees no own-money modules (they hold no wallet), and a
// lapsed PIN brings them back to the page they asked for. Also the password
// field's show/hide toggle. Local stack only, synthetic data.

import { type Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	addPresident,
	completeIdentityAndProfile,
	createConfirmedAccount,
	inviteMember,
	localSql,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, signInAs } = walletPeople;
const DESKTOP = { width: 1440, height: 900 };
const MOBILE = { width: 390, height: 844 };

test.describe.configure({ mode: 'serial' });

/** Signs in a President-only person, finishing first-use setup if asked. */
async function signInPresident(page: Page, email: string) {
	await signInAs(page, email);
	if (page.url().includes('/onboarding')) {
		await page.getByRole('link', { name: 'Let’s begin' }).click();
		await completeIdentityAndProfile(page);
		await expect(page.getByRole('link', { name: 'Go to my wallet' })).toBeVisible();
		await page.getByRole('link', { name: 'Go to my wallet' }).click();
	}
	await expect(page).toHaveURL(/\/app$/);
}

async function expectInvitations(page: Page) {
	await expect(page).toHaveURL(/\/app\/invitations$/);
	await expect(page.getByRole('heading', { name: 'Invitations', level: 1 })).toBeVisible();
	await expect(page.getByRole('button', { name: 'Invite a member' })).toBeVisible();
}

test('password field: showing the password keeps what was typed', async ({ page }) => {
	await page.goto('/sign-in');
	await page.waitForLoadState('networkidle');
	const field = page.getByLabel('Password', { exact: true });
	await field.fill('typed-before-toggle');
	await page.getByRole('button', { name: 'Show password' }).click();
	await expect(field).toHaveAttribute('type', 'text');
	await expect(field).toHaveValue('typed-before-toggle');
	await page.getByRole('button', { name: 'Hide password' }).click();
	await expect(field).toHaveAttribute('type', 'password');
	await expect(field).toHaveValue('typed-before-toggle');
	await field.press('End');
	await field.pressSequentially('!');
	await page.getByRole('button', { name: 'Show password' }).click();
	await expect(field).toHaveValue('typed-before-toggle!');
});

test('President Team: every Invite entry opens Invitations; no wallet modules', async ({
	page
}) => {
	const founder = { email: uniqueEmail('pt-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await inviteMember(founder, 'President Invite Network', uniqueEmail('pt-m'));
	const president = uniqueEmail('pt-p');
	await createConfirmedAccount(president, PASSWORD, PIN);
	await addPresident(founder, president);

	await page.setViewportSize(DESKTOP);
	await signInPresident(page, president);

	// No own wallet: no own-money entries anywhere.
	const sidebar = page.getByRole('complementary', { name: 'Main' });
	await expect(sidebar.getByRole('link', { name: 'Invitations' })).toBeVisible();
	for (const name of ['Payout accounts', 'Statements', 'Activity', 'Withdrawals']) {
		await expect(sidebar.getByRole('link', { name, exact: true })).toHaveCount(0);
	}
	await expect(page.getByRole('heading', { name: 'No wallet in this workspace' })).toBeVisible();

	// The workspace switcher's divider sits on the top bar's bottom border, at every width.
	for (const width of [1024, 1280, 1440, 1920]) {
		await page.setViewportSize({ width, height: 900 });
		const lines = await page.evaluate(() =>
			['.switcher-block', '.topbar'].map(
				(s) => document.querySelector(s)!.getBoundingClientRect().bottom
			)
		);
		expect(lines[0], `width ${width}`).toBe(lines[1]);
	}
	await page.setViewportSize(DESKTOP);

	// Sidebar.
	await sidebar.getByRole('link', { name: 'Invitations' }).click();
	await expectInvitations(page);
	// A full load of the page (e.g. after an update) stays there too.
	await page.reload();
	await expectInvitations(page);

	// Team overview's shortcut.
	await sidebar.getByRole('link', { name: 'Home' }).click();
	await page.goto('/app/team');
	await page.getByRole('link', { name: /Invite a member/ }).click();
	await expectInvitations(page);

	// Members' hero action.
	await page.goto('/app/members');
	await page.getByRole('link', { name: /Invite a member/ }).click();
	await expectInvitations(page);

	// Quick search.
	await page.goto('/app');
	await page.getByRole('button', { name: 'Quick search…' }).click();
	await page.keyboard.type('Invitations');
	await page.keyboard.press('Enter');
	await expectInvitations(page);

	// A direct visit to an own-money page explains instead of failing.
	await page.goto('/app/payout-accounts');
	await expect(page.getByRole('heading', { name: 'Not available for your role' })).toBeVisible();

	// Mobile: More.
	await page.setViewportSize(MOBILE);
	await page.goto('/app/more');
	await expect(page.getByRole('link', { name: 'Payout accounts' })).toHaveCount(0);
	await expect(page.getByRole('link', { name: 'Statements' })).toHaveCount(0);
	await page.getByRole('link', { name: 'Invitations' }).click();
	await expectInvitations(page);

	// A lapsed PIN (idle lock) on a full load returns to the asked-for page.
	const lapse = () =>
		localSql(`update identity.session_pin_proofs p set last_activity_at = now() - interval '1 hour'
		  from auth.users u where u.id = p.user_id and u.email = '${president}'`);
	lapse();
	await page.goto('/app/invitations');
	await expect(page).toHaveURL(/\/pin\?next=%2Fapp%2Finvitations$/);
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByRole('button', { name: 'Verify' }).click();
	await expectInvitations(page);

	// ... and so does one found by the page's own read after an in-app tap.
	await page.setViewportSize(DESKTOP);
	await page.goto('/app');
	await expect(page.getByRole('heading', { name: 'No wallet in this workspace' })).toBeVisible();
	lapse();
	await page
		.getByRole('complementary', { name: 'Main' })
		.getByRole('link', { name: 'Invitations' })
		.click();
	await expect(page).toHaveURL(/\/pin\?next=%2Fapp%2Finvitations$/);
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByRole('button', { name: 'Verify' }).click();
	await expectInvitations(page);

	// ... and through the server gates too (sign-in while signed in → picker → PIN).
	lapse();
	await page.goto('/sign-in?next=%2Fapp%2Finvitations');
	await expect(page).toHaveURL(/\/pin\?next=%2Fapp%2Finvitations$/);
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByRole('button', { name: 'Verify' }).click();
	await expectInvitations(page);
});
