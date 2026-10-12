// Slice 08 (Blueprint 08): activity with search/filters and the transaction
// detail (M03/M04/M05), the team overview (T01/T04), member wallets and the
// shared unknown-outcome recovery (F-03, B16). Local stack only, synthetic data.

import { expect, test, type Page } from '@playwright/test';
import {
	completeIdentityAndProfile,
	confirmLinkFor,
	createConfirmedAccount,
	expectAccessible,
	expectNoHorizontalScroll,
	fillSettled,
	humanReady,
	inviteMember,
	pick,
	recordIncome,
	uniqueEmail,
	skipInstall
} from './helpers';

const PASSWORD = 'correct-horse-battery';
const PIN = '1357';

test.describe.configure({ mode: 'serial', timeout: 90_000 });

const founder = { email: uniqueEmail('money-f'), password: PASSWORD, pin: PIN };
const member = uniqueEmail('money-m');
const NETWORK = 'Money Test Network';

async function signInAs(page: Page, email: string) {
	await page.context().clearCookies();
	await page.goto('/sign-in');
	await page.getByLabel('Email address').fill(email);
	await page.getByLabel('Password', { exact: true }).fill(PASSWORD);
	await humanReady(page);
	await page.getByRole('button', { name: 'Sign in' }).click();
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByRole('button', { name: 'Verify' }).click();
	await expect(page).not.toHaveURL(/\/pin(\?.*)?$/);
}

async function openPresidentWorkspace(page: Page) {
	await signInAs(page, founder.email);
	if (page.url().includes('/onboarding')) {
		await page.getByRole('link', { name: 'Let’s begin' }).click();
		await completeIdentityAndProfile(page);
		await skipInstall(page);
		await page.getByRole('link', { name: 'Go to my wallet' }).click();
	}
	await page.goto('/workspaces?switch');
	await page.getByRole('button', { name: new RegExp(`${NETWORK}.*President Team`) }).click();
}

test('a member searches and filters activity and opens a transaction', async ({ page }) => {
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const { joinPath } = await inviteMember(founder, NETWORK, member);
	await page.goto(joinPath);
	await page.getByRole('button', { name: 'Verify email' }).click();
	await page.goto(await confirmLinkFor(member, /Confirm your Elivate Wallet email/));
	await page.getByRole('button', { name: 'Continue' }).click();
	await fillSettled(page, 'New password', PASSWORD);
	await page.getByRole('button', { name: 'Set password' }).click();
	await page.getByRole('button', { name: 'Accept invitation' }).click();
	await page.getByRole('link', { name: 'Let’s begin' }).click();
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByLabel('Repeat PIN').fill(PIN);
	await page.getByRole('button', { name: 'Save PIN' }).click();
	await completeIdentityAndProfile(page);
	await pick(page.getByLabel('Bank', { exact: true }), 'Test Bank');
	await page.getByLabel('Account number').fill('0123456789');
	await page.getByRole('button', { name: 'Check account' }).click();
	await page.getByRole('button', { name: 'Save account' }).click();
	await skipInstall(page);
	await page.getByRole('link', { name: 'Go to my wallet' }).click();

	await recordIncome(founder, member, '1000.00');
	await recordIncome(founder, member, '2500.00');
	await page.reload();

	await page.getByRole('link', { name: 'See all' }).click();
	await expect(page).toHaveURL(/\/app\/activity$/);
	const list = page.locator('.list');
	await expect(list.getByRole('button', { name: /Fiverr/ })).toHaveCount(2);
	// Month totals come from the backend, per currency.
	await expect(page.getByText('In +₦3,500.00')).toBeVisible();

	await page.getByLabel('Search activity').fill('2,500');
	await expect(list.getByRole('button', { name: /Fiverr/ })).toHaveCount(1);
	await list.getByRole('button', { name: /Fiverr/ }).click();
	await expect(page).toHaveURL(/tx=/);
	const panel = page.getByRole('complementary', { name: /Transaction INC-/ });
	await expect(panel.getByText('+₦2,500.00')).toBeVisible();
	await expect(panel.getByText('Split into pockets')).toBeVisible();
	await expect(panel.getByText('₦1,000.00')).toBeVisible(); // 40% Point Value
	await expectAccessible(page);
	await panel.getByRole('button', { name: 'Close details' }).click();
	await expect(panel).toHaveCount(0);

	await page.getByLabel('Search activity').fill('');
	await page.getByRole('button', { name: 'Money out' }).click();
	await expect(page.getByRole('heading', { name: 'Nothing matches' })).toBeVisible();
	await expectAccessible(page);
	await page.getByRole('button', { name: 'Clear filters' }).click();
	await expect(list.getByRole('button', { name: /Fiverr/ })).toHaveCount(2);

	// Mobile: the full-page detail (M05).
	await page.setViewportSize({ width: 320, height: 720 });
	await expect(list.getByRole('button', { name: /Fiverr/ })).toHaveCount(2);
	await expectNoHorizontalScroll(page);
	await list
		.getByRole('button', { name: /Fiverr/ })
		.first()
		.click();
	await expect(page.getByRole('heading', { name: '+₦2,500.00' })).toBeVisible();
	await expectNoHorizontalScroll(page);
	await page.getByRole('button', { name: 'Back to activity' }).click();
	await expect(page).toHaveURL(/\/app\/activity$/);
});

test('the President sees the team overview and opens a member wallet', async ({ page }) => {
	await openPresidentWorkspace(page);
	// Slice 28: the team overview is Home (/app/team sends old links there).
	await page.goto('/app/team');
	await expect(page).toHaveURL(/\/app$/);
	await expect(page.getByTestId('network-income')).toHaveText('₦3,500.00');
	await expectAccessible(page);

	await page.goto('/app/wallets');
	await page.getByRole('link', { name: /₦3,500\.00/ }).click();
	await expect(page).toHaveURL(/wallet=/);
	// Q05: per-pocket breakdown (default split of ₦3,500.00: Point Value 40%).
	await expect(
		page.getByRole('region', { name: 'Pockets' }).getByText('₦1,400.00').first()
	).toBeVisible();
	await expectAccessible(page);
	await page.getByRole('link', { name: 'View all' }).click();
	await expect(page.locator('.list').getByRole('button', { name: /Fiverr/ })).toHaveCount(2);
});

test('an unknown outcome is checked, not resent under a new key (F-03)', async ({ page }) => {
	await openPresidentWorkspace(page);
	await page.goto('/app/split');

	// 1. The save reaches the server but the answer is lost: the lookup finds it
	// committed and the same-key replay shows the saved split.
	let dropped = false;
	await page.route('**/api/split', async (route) => {
		if (route.request().method() !== 'PUT' || dropped) return route.continue();
		dropped = true;
		await route.fetch();
		await route.abort('failed');
	});
	await page.getByLabel('Upkeep share of income, percent').fill('20.00');
	await page.getByLabel('Savings share of income, percent').fill('15.00');
	await page.getByRole('button', { name: 'Save split' }).click();
	let dialog = page.getByRole('dialog', { name: 'Save the new split?' });
	await dialog.getByLabel('Reason').fill('More set aside for savings.');
	await dialog.getByLabel('Your PIN').fill(PIN);
	await dialog.getByRole('button', { name: 'Save split' }).click();
	await expect(page.getByText('Saved. New income uses version 2.')).toBeVisible();

	// 2. The request never reaches the server: nothing committed, the same body
	// goes again with the same key on "Send again".
	await page.unroute('**/api/split');
	const keys: string[] = [];
	let blocked = false;
	await page.route('**/api/split', async (route) => {
		if (route.request().method() !== 'PUT') return route.continue();
		keys.push(JSON.parse(route.request().postData() ?? '{}').idempotencyKey);
		if (!blocked) {
			blocked = true;
			return route.abort('failed');
		}
		return route.continue();
	});
	await page.getByLabel('Upkeep share of income, percent').fill('25.00');
	await page.getByLabel('Savings share of income, percent').fill('10.00');
	await page.getByRole('button', { name: 'Save split' }).click();
	dialog = page.getByRole('dialog', { name: 'Save the new split?' });
	await dialog.getByLabel('Reason').fill('Back to the default split.');
	await dialog.getByLabel('Your PIN').fill(PIN);
	await dialog.getByRole('button', { name: 'Save split' }).click();
	await expect(page.getByRole('heading', { name: 'It didn’t go through yet' })).toBeVisible();
	await expect(page.getByText(/Attempt [A-Z0-9]{4}-/)).toBeVisible();
	await expectAccessible(page);
	await page.getByRole('button', { name: 'Send again' }).click();
	await expect(page.getByText('Saved. New income uses version 3.')).toBeVisible();
	expect(keys).toHaveLength(2);
	expect(keys[0]).toBe(keys[1]);
});
