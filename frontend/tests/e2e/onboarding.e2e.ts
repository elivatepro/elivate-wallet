import { expect, test } from '@playwright/test';
import {
	completeIdentityAndProfile,
	confirmLinkFor,
	createNetworkFor,
	expectAccessible,
	expectNoHorizontalScroll,
	humanReady,
	uniqueEmail
} from './helpers';

const PASSWORD = 'correct-horse-battery';
const PIN = '1357';

test.describe.configure({ mode: 'serial' });

test('sign-up → email confirm → PIN setup → workspace picker → shell, then PIN sign-in', async ({
	page
}) => {
	const email = uniqueEmail('founder');

	// 1. Start your network (founder entry, W-01).
	await page.goto('/sign-up');
	await page.getByLabel('Email address').fill(email);
	await page.getByLabel('Password', { exact: true }).fill(PASSWORD);
	await humanReady(page);
	await page.getByRole('button', { name: 'Create account' }).click();
	await expect(page.getByRole('heading', { name: 'Check your inbox' })).toBeVisible();

	// 2. The emailed link lands on a Continue page; GET alone does not verify.
	const link = await confirmLinkFor(email, /Confirm your Elivate Wallet email/);
	expect(new URL(link).pathname).toBe('/auth/confirm');
	await page.goto(link);
	await expect(page.getByRole('heading', { name: 'Confirm your email' })).toBeVisible();
	await page.getByRole('button', { name: 'Continue' }).click();

	// 3. First PIN; the URL is clean (no token) after the POST redirect.
	await expect(page).toHaveURL(/\/pin\/setup$/);
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByLabel('Repeat PIN').fill('2468');
	await page.getByRole('button', { name: 'Save PIN' }).click();
	await expect(page.getByText('The PINs don’t match.')).toBeVisible();
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByLabel('Repeat PIN').fill(PIN);
	await page.getByRole('button', { name: 'Save PIN' }).click();

	// 4. A brand-new founder has no workspace yet.
	await expect(page).toHaveURL(/\/workspaces$/);
	await expect(page.getByRole('heading', { name: 'No workspace yet' })).toBeVisible();
	await expect(page.getByText(/EW-\d{5,}/)).toBeVisible();

	// 5. Once a workspace exists, first-use setup runs (W-01 step 6): NIN and
	// profile; a President Team member has no wallet, so no bank step.
	await createNetworkFor(email, PASSWORD, PIN, 'Sunrise Test Network');
	await page.goto('/workspaces');
	await expect(page).toHaveURL(/\/onboarding$/);
	await expect(
		page.getByRole('heading', { name: 'Welcome to Sunrise Test Network' })
	).toBeVisible();
	await page.getByRole('link', { name: 'Let’s begin' }).click();
	await completeIdentityAndProfile(page);
	await expect(page.getByRole('heading', { name: 'You’re all set, Ada' })).toBeVisible();

	// 6. With exactly one workspace it is opened automatically (decision 48).
	await page.goto('/workspaces');
	await expect(page).toHaveURL(/\/app$/);
	await expect(page.getByText('Sunrise Test Network').filter({ visible: true })).toBeVisible();
	await expect(page.getByRole('heading', { name: 'No money in yet' })).toBeVisible();
	// No token or membership id in any URL.
	expect(page.url()).not.toMatch(/token|membership|[0-9a-f]{8}-[0-9a-f]{4}/i);

	// 7. Sign out, sign back in: password, then PIN (one wrong try first).
	await page.getByRole('button', { name: 'Account' }).click();
	await page.getByRole('menuitem', { name: 'Sign out' }).click();
	await expect(page).toHaveURL(/\/sign-in$/);
	const cached = await page.evaluate(() =>
		Object.keys(localStorage).filter((k) => k.startsWith('ew:cache') || k.startsWith('ew:scope'))
	);
	expect(cached).toEqual([]);

	await page.getByLabel('Email address').fill(email);
	await page.getByLabel('Password', { exact: true }).fill(PASSWORD);
	await humanReady(page);
	await page.getByRole('button', { name: 'Sign in' }).click();
	await expect(page).toHaveURL(/\/pin$/);
	await page.getByLabel('PIN', { exact: true }).fill('0000');
	await page.getByRole('button', { name: 'Verify' }).click();
	await expect(page.getByText('That PIN is incorrect. 4 tries left.')).toBeVisible();
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByRole('button', { name: 'Verify' }).click();
	await expect(page).toHaveURL(/\/app$/);
	await expect(page.getByText('Sunrise Test Network').filter({ visible: true })).toBeVisible();
});

test('sign-in keeps one generic message for wrong credentials (W-01)', async ({ page }) => {
	await page.goto('/sign-in');
	await page.getByLabel('Email address').fill(uniqueEmail('nobody'));
	await page.getByLabel('Password', { exact: true }).fill('not-the-password');
	await humanReady(page);
	await page.getByRole('button', { name: 'Sign in' }).click();
	await expect(page.getByRole('alert')).toHaveText(
		'We couldn’t sign you in. Check your details and try again.'
	);
});

test('signed-out visitors are sent to sign-in', async ({ page }) => {
	await page.goto('/workspaces');
	await expect(page).toHaveURL(/\/sign-in$/);
	await page.goto('/pin');
	await expect(page).toHaveURL(/\/sign-in$/);
});

test.describe('320 px, both themes: accessible and no horizontal scroll', () => {
	test.use({ viewport: { width: 320, height: 720 } });

	for (const theme of ['dark', 'light'] as const) {
		test(`auth pages in ${theme}`, async ({ page, context }) => {
			await context.addCookies([{ name: 'ew_theme', value: theme, url: 'http://127.0.0.1:3000' }]);
			for (const path of ['/sign-in', '/sign-up', '/sign-up/check-email', '/auth/link-expired']) {
				await page.goto(path);
				await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
				await expectNoHorizontalScroll(page);
				await expectAccessible(page);
			}
		});
	}

	test('PIN setup and the empty workspace picker', async ({ page }) => {
		const email = uniqueEmail('a11y');
		await page.goto('/sign-up');
		await page.getByLabel('Email address').fill(email);
		await page.getByLabel('Password', { exact: true }).fill(PASSWORD);
		await humanReady(page);
		await page.getByRole('button', { name: 'Create account' }).click();
		await page.goto(await confirmLinkFor(email, /Confirm your Elivate Wallet email/));
		await expectAccessible(page);
		await page.getByRole('button', { name: 'Continue' }).click();
		await expect(page).toHaveURL(/\/pin\/setup$/);
		await expectNoHorizontalScroll(page);
		await expectAccessible(page);
		await page.getByLabel('PIN', { exact: true }).fill(PIN);
		await page.getByLabel('Repeat PIN').fill(PIN);
		await page.getByRole('button', { name: 'Save PIN' }).click();
		await expect(page.getByRole('heading', { name: 'No workspace yet' })).toBeVisible();
		await expectNoHorizontalScroll(page);
		await expectAccessible(page);
	});
});
