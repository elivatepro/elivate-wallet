// Blueprint 20 B6: signed-in pages open from cached data, then refresh. A
// second Home visit renders before /api/home answers; another person signing
// in on the same browser never sees the first person's data (the ew_who
// guard); and recording income clears the cached wallets so the new balance
// shows. Local stack only, synthetic data.

import { type Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	completeIdentityAndProfile,
	createConfirmedAccount,
	humanReady,
	recordIncome,
	uniqueEmail,
	walletPeople,
	skipInstall
} from './helpers';

const { PASSWORD, PIN, memberWithAccount, signInAs, asPresident } = walletPeople;
const NETWORK = 'Cache Test Network';
const RECEIPT = {
	name: 'fiverr-order-receipt.pdf',
	mimeType: 'application/pdf',
	buffer: Buffer.from('%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << >>\n%%EOF\n')
};

test.describe.configure({ mode: 'serial' });

const founder = { email: uniqueEmail('cache-f'), password: PASSWORD, pin: PIN };
const member = uniqueEmail('cache-m');

/** Holds every response of `path` back by `ms` (the read itself still runs). */
async function delay(page: Page, path: string, ms: number) {
	await page.route(
		(url) => url.pathname === path,
		async (route) => {
			await new Promise((resolve) => setTimeout(resolve, ms));
			await route.continue();
		}
	);
}

const balance = (page: Page, amount: string) =>
	page.getByRole('region', { name: 'Balance' }).getByText(amount, { exact: true });

test('a second Home visit renders from the cache before /api/home answers', async ({ page }) => {
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await memberWithAccount(founder, NETWORK, member);
	await recordIncome(founder, member, '1000.00');

	await signInAs(page, member);
	await expect(page).toHaveURL(/\/app$/);
	await expect(balance(page, '₦1,000.00')).toBeVisible();
	const who = (await page.context().cookies()).find((c) => c.name === 'ew_who');
	expect(who?.httpOnly).toBe(false);

	// Reload: the device cache (guarded by ew_who) shows the balance at once.
	await delay(page, '/api/home', 4000);
	const started = Date.now();
	await page.reload();
	await expect(balance(page, '₦1,000.00')).toBeVisible({ timeout: 2500 });
	expect(Date.now() - started).toBeLessThan(4000);
	await expect(page.getByTestId('cache-note')).toHaveText('Updating…');
	// The fresh reply replaces it.
	await expect(page.getByTestId('cache-note')).toHaveCount(0, { timeout: 10_000 });

	// Back to Home in the app: memory, no wait.
	await page.getByRole('link', { name: 'Activity' }).first().click();
	await expect(page).toHaveURL(/\/app\/activity$/);
	await page.getByRole('link', { name: 'Home' }).first().click();
	await expect(balance(page, '₦1,000.00')).toBeVisible({ timeout: 1500 });
});

test('sign out, then another person signs in: no flash of the first person’s data', async ({
	page
}) => {
	await signInAs(page, member);
	await expect(balance(page, '₦1,000.00')).toBeVisible();
	const saved = await page.evaluate(() =>
		Object.fromEntries(
			Object.keys(localStorage)
				.filter((k) => k.startsWith('ew:cache') || k.startsWith('ew:scope'))
				.map((k) => [k, localStorage.getItem(k) ?? ''])
		)
	);
	expect(Object.keys(saved).some((k) => k.endsWith(':balances'))).toBe(true);

	await page.getByRole('button', { name: 'Account' }).click();
	await page.getByRole('menuitem', { name: 'Sign out' }).click();
	await expect(page).toHaveURL(/\/sign-in$/);
	expect((await page.context().cookies()).some((c) => c.name === 'ew_who')).toBe(false);

	// Worst case: the purge missed (another tab, a crash). Put the first
	// person's entries back; only the ew_who guard stands in the way.
	await page.evaluate((entries) => {
		for (const [k, v] of Object.entries(entries)) localStorage.setItem(k, v);
	}, saved);
	await delay(page, '/api/home', 3000);
	await page.getByLabel('Email address').fill(founder.email);
	await page.getByLabel('Password', { exact: true }).fill(PASSWORD);
	await humanReady(page);
	await page.getByRole('button', { name: 'Sign in' }).click();
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByRole('button', { name: 'Verify' }).click();
	// The founder (set up already, Blueprint 22) holds two workspaces: pick theirs.
	if (
		await page.waitForURL(/\/workspaces/, { timeout: 3000 }).then(
			() => true,
			() => false
		)
	) {
		await page.getByRole('button', { name: new RegExp(`${NETWORK}.*President Team`) }).click();
	}
	if (
		await page.waitForURL(/\/onboarding/, { timeout: 3000 }).then(
			() => true,
			() => false
		)
	) {
		await page.getByRole('link', { name: 'Let’s begin' }).click();
		await completeIdentityAndProfile(page);
		await skipInstall(page);
		await page.getByRole('link', { name: 'Go to my wallet' }).click();
	}
	await expect(page).toHaveURL(/\/app$/);
	// While /api/home is held back, the first person's money never shows (the
	// founder's own network home shows the network's income, Blueprint 25).
	for (let i = 0; i < 10; i += 1) {
		await expect(page.getByRole('region', { name: 'Balance' })).toHaveCount(0);
		await expect(page.getByTestId('cache-note')).toHaveCount(0);
		await page.waitForTimeout(200);
	}
	// The founder's President Team workspace holds no wallet: Home is the
	// network overview (Blueprint 25).
	await expect(page.getByRole('region', { name: 'Income recorded this month' })).toBeVisible({
		timeout: 10_000
	});
});

test('recording income clears the cached wallets and shows the new balance', async ({ page }) => {
	await asPresident(page, founder.email, NETWORK);
	await page.goto('/app/wallets');
	await expect(page.getByRole('link', { name: /₦1,000\.00/ })).toBeVisible();
	const cachedKinds = () =>
		page.evaluate(() =>
			Object.keys(localStorage)
				.filter((k) => k.startsWith('ew:cache'))
				.map((k) => k.split(':').slice(5).join(':'))
		);
	expect(await cachedKinds()).toContain('wallets');

	await page.goto('/app/income');
	await page.getByRole('button', { name: /Member/ }).click();
	const picker = page.getByRole('dialog', { name: 'Choose the member' });
	await picker.getByLabel('Search members').fill('obi');
	await picker.getByRole('button', { name: /Ada Obi/ }).click();
	await page.getByLabel('Amount received').fill('500');
	await page.getByLabel('Source').fill('Fiverr order');
	await page.locator('input[type=file]').setInputFiles(RECEIPT);
	await expect(page.getByText('fiverr-order-receipt.pdf')).toBeVisible();
	await page.getByRole('button', { name: 'Review and post' }).last().click();
	const dialog = page.getByRole('dialog', { name: 'Post ₦500.00?' });
	await dialog.getByLabel('Your PIN').fill(PIN);
	await dialog.getByRole('button', { name: 'Post income' }).click();
	await expect(page.getByRole('heading', { name: 'Income posted' })).toBeVisible();
	// The command cleared the money kinds on this device.
	const after = await cachedKinds();
	expect(after).not.toContain('wallets');
	expect(after).not.toContain('balances');

	// Nothing stale to show: the list waits for the server, then has the new total.
	await delay(page, '/api/wallets', 2000);
	const listed = Date.now();
	await page.goto('/app/wallets');
	await expect(page.getByRole('link', { name: /₦1,000\.00/ })).toHaveCount(0);
	await expect(page.getByTestId('cache-note')).toHaveCount(0);
	await expect(page.getByRole('link', { name: /₦1,500\.00/ })).toBeVisible({ timeout: 10_000 });
	expect(Date.now() - listed).toBeGreaterThanOrEqual(2000);

	// Next visit opens from the cache with the new balance, then refreshes.
	await page.reload();
	await expect(page.getByRole('link', { name: /₦1,500\.00/ })).toBeVisible({ timeout: 1500 });
	await expect(page.getByTestId('cache-note')).toHaveText('Updating…');
});

// ── Blueprint 23: every page, instant taps, idle code preload ─────────────

test('every page opens from its saved copy before its read answers', async ({ page }) => {
	await asPresident(page, founder.email, NETWORK);
	await expect(page).toHaveURL(/\/app$/);
	const events = page.getByRole('heading', { name: /^\d+\+? events?$/ });
	const invited = page.getByText(member, { exact: true }).first();
	await page.goto('/app/audit');
	await expect(events).toBeVisible();
	await page.goto('/app/invitations');
	await expect(invited).toBeVisible();

	// Reload (device cache): the audit log shows before /api/org/audit answers.
	await delay(page, '/api/org/audit', 4000);
	await delay(page, '/api/invitations', 4000);
	await page.goto('/app/audit');
	await expect(events).toBeVisible({ timeout: 2500 });
	await expect(page.getByTestId('cache-note')).toHaveText('Updating…');
	await expect(page.getByTestId('cache-note')).toHaveCount(0, { timeout: 10_000 });

	// In the app (memory): Invitations shows at once, then refreshes.
	await page.getByRole('link', { name: 'Invitations' }).first().click();
	await expect(page).toHaveURL(/\/app\/invitations$/);
	await expect(invited).toBeVisible({ timeout: 1500 });
	await expect(page.getByTestId('cache-note')).toHaveText('Updating…');
	await expect(page.getByTestId('cache-note')).toHaveCount(0, { timeout: 10_000 });
});

test('the shell fetches every screen’s code once it is idle', async ({ page }) => {
	const nodes = new Set<string>();
	page.on('request', (request) => {
		const path = new URL(request.url()).pathname;
		if (path.startsWith('/_app/immutable/nodes/')) nodes.add(path);
	});
	await asPresident(page, founder.email, NETWORK);
	await expect(page).toHaveURL(/\/app$/);
	// About 45 route nodes; the shell itself needs only a few.
	await expect.poll(() => nodes.size, { timeout: 20_000 }).toBeGreaterThan(40);
});

test.describe('a tap answers at once (mobile)', () => {
	// No service worker: page.route never sees requests it answers.
	test.use({
		viewport: { width: 390, height: 844 },
		isMobile: true,
		hasTouch: true,
		serviceWorkers: 'block'
	});

	test('the tab and a page frame show before the page’s code arrives', async ({ page }) => {
		// Save-Data: no idle preload, so the tapped page's code is still to come.
		await page.addInitScript(() =>
			Object.defineProperty(navigator, 'connection', { value: { saveData: true } })
		);
		await asPresident(page, founder.email, NETWORK);
		await expect(page).toHaveURL(/\/app$/);
		await page.route('**/_app/immutable/nodes/**', async (route) => {
			await new Promise((resolve) => setTimeout(resolve, 2500));
			await route.continue();
		});
		const people = page.locator('.tabbar [data-tab="people"]');
		await people.click();
		await expect(people).toHaveAttribute('aria-current', 'page', { timeout: 500 });
		await expect(page.locator('.tabbar [data-tab="home"]')).not.toHaveAttribute(
			'aria-current',
			'page'
		);
		await expect(page.getByTestId('page-frame')).toBeVisible({ timeout: 1000 });
		await expect(page).toHaveURL(/\/app\/members$/, { timeout: 10_000 });
		await expect(page.getByTestId('page-frame')).toHaveCount(0);
	});
});
