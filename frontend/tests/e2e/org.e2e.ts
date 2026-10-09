// Org management (Blueprint 07; Paper O01/O04/O07/O10, R01, F05): the
// President creates, renames, re-places and closes an office, changes a role
// permission with a reason and PIN, and reads the audit log. Local stack
// only, synthetic data.

import { expect, test, type Page } from '@playwright/test';
import {
	completeIdentityAndProfile,
	createConfirmedAccount,
	expectAccessible,
	expectNoHorizontalScroll,
	humanReady,
	inviteMember,
	uidOf,
	uniqueEmail
} from './helpers';

const PASSWORD = 'correct-horse-battery';
const PIN = '1357';

test.describe.configure({ mode: 'serial' });

async function signInAsPresident(page: Page, email: string, network: string) {
	await page.context().clearCookies();
	await page.goto('/sign-in');
	await page.getByLabel('Email address').fill(email);
	await page.getByLabel('Password', { exact: true }).fill(PASSWORD);
	await humanReady(page);
	await page.getByRole('button', { name: 'Sign in' }).click();
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByRole('button', { name: 'Verify' }).click();
	await expect(page).not.toHaveURL(/\/pin(\?.*)?$/);
	if (page.url().includes('/onboarding')) {
		await page.getByRole('link', { name: 'Let’s begin' }).click();
		await completeIdentityAndProfile(page);
		await page.getByRole('link', { name: 'Go to my wallet' }).click();
	}
	await page.goto('/workspaces?switch');
	await page.getByRole('button', { name: new RegExp(`${network}.*President Team`) }).click();
}

test('President manages offices, a role permission and reads the audit log', async ({ page }) => {
	const founder = { email: uniqueEmail('org-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await inviteMember(founder, 'Org Test Network', uniqueEmail('org-m'));
	const uid = uidOf(founder.email);
	await signInAsPresident(page, founder.email, 'Org Test Network');

	// O01: the World Team office from setup, as a tree.
	await page.getByRole('link', { name: 'Offices' }).first().click();
	await expect(page).toHaveURL(/\/app\/offices$/);
	await expect(page.getByRole('heading', { name: '1 office' })).toBeVisible();
	await expect(page.getByRole('link', { name: /Org World Team/ })).toBeVisible();
	await expectAccessible(page);

	// O04: a new team office under it, led by the founder (reason-free, PIN).
	await page.getByRole('button', { name: 'New office' }).click();
	const create = page.getByRole('dialog', { name: 'New office' });
	await create.getByLabel('Office name').fill('Lagos office');
	await create.getByText('Team office', { exact: true }).click();
	await create.getByLabel('Parent office').selectOption({ label: 'Org World Team' });
	await create.getByLabel('Team Leader UID').fill(uid);
	await create.getByLabel('Your PIN').fill(PIN);
	await create.getByRole('button', { name: 'Create office' }).click();
	await expect(page.getByText('Lagos office created.')).toBeVisible();
	await expect(page.getByRole('heading', { name: '2 offices' })).toBeVisible();

	// O07/O10: detail and rename.
	await page.getByRole('link', { name: /Lagos office/ }).click();
	await expect(page.getByRole('heading', { name: 'Lagos office' })).toBeVisible();
	await expect(page.getByText('Held for members · NGN')).toBeVisible();
	await expectAccessible(page);
	await page.getByRole('button', { name: 'Rename' }).click();
	const rename = page.getByRole('dialog', { name: 'Rename office' });
	await rename.getByLabel('Office name').fill('Lagos central office');
	await rename.getByRole('button', { name: 'Save name' }).click();
	await expect(page.getByText('Office renamed.')).toBeVisible();
	await expect(page.getByRole('heading', { name: 'Lagos central office' })).toBeVisible();

	// N04: place it at the top of the network (reason + PIN).
	await page.getByRole('button', { name: 'Move office' }).click();
	const placeDialog = page.getByRole('dialog', { name: 'Place under another office' });
	await placeDialog.getByText('Top of the network', { exact: true }).click();
	await placeDialog.getByLabel('Reason').fill('Reports straight to the President Team');
	await placeDialog.getByLabel('Your PIN').fill(PIN);
	await placeDialog.getByRole('button', { name: 'Move office' }).click();
	await expect(page.getByText('Office moved.')).toBeVisible();

	// N01/N02: close it (no active members or money; its leader is archived).
	await page.getByRole('button', { name: 'Close office' }).click();
	const closeDialog = page.getByRole('dialog', { name: 'Close Lagos central office' });
	await closeDialog.getByLabel('Reason').fill('Merged into the World Team office');
	await closeDialog.getByLabel('Your PIN').fill(PIN);
	await closeDialog.getByRole('button', { name: 'Close office' }).click();
	await expect(page.getByText('Office closed.')).toBeVisible();
	await expect(page.getByText(/^Closed · /)).toBeVisible();
	await expect(page.getByText('Merged into the World Team office')).toBeVisible();
	await expectAccessible(page);

	// Members (C11): the founder is listed.
	await page.goto('/app/members');
	await expect(page.getByText(uid).first()).toBeVisible();
	await expectNoHorizontalScroll(page);

	// R01: switch a configurable permission, save with a reason and the PIN.
	await page.goto('/app/access');
	await expect(page.getByRole('heading', { name: 'Who can do what' })).toBeVisible();
	await page.getByRole('switch', { name: 'Withdraw on behalf for Team Leader' }).click();
	await expect(page.getByText('1 unsaved change')).toBeVisible();
	await page.getByRole('button', { name: 'Save changes' }).click();
	const save = page.getByRole('dialog', { name: 'Save role permissions?' });
	await save.getByLabel('Reason').fill('Team Leaders cover withdrawals on behalf');
	await save.getByLabel('Your PIN').fill(PIN);
	await save.getByRole('button', { name: 'Save changes' }).click();
	await expect(page.getByText('Role permissions saved.')).toBeVisible();
	await expect(
		page.getByRole('switch', { name: 'Withdraw on behalf for Team Leader' })
	).toHaveAttribute('aria-checked', 'true');
	await expectAccessible(page);

	// F05: the audit log shows what happened.
	await page.goto('/app/audit');
	await expect(page.getByRole('button', { name: /Closed an office/ })).toBeVisible();
	await expect(page.getByRole('button', { name: /Created an office/ }).first()).toBeVisible();
	await expect(page.getByRole('button', { name: /Allowed a role permission/ })).toBeVisible();
	await expectAccessible(page);
});

test('signed-out visitors are sent to sign in', async ({ page }) => {
	await page.context().clearCookies();
	const response = await page.request.get('/api/org/offices');
	expect(response.status()).toBe(401);
});
