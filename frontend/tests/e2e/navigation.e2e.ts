// Blueprint 25 (Paper "Navigation v5" NV01–NV03): the President Team's network
// home with the leader tab set and the sectioned sidebar (no wallet items), a
// member's wallet tabs and My wallet section, the 64 px header line, and the
// pill growing on navigation. With E2E_SHOTS set, screenshots at 390 and
// 1440 px, dark and light, for the Paper comparison. Local stack only,
// synthetic data.

import { type Locator, type Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	createConfirmedAccount,
	expectAccessible,
	expectNoHorizontalScroll,
	recordIncome,
	shot,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, memberWithAccount, signInAs, asPresident } = walletPeople;
const NETWORK = 'Navigation Test Network';
const DESKTOP = { width: 1440, height: 960 };
const MOBILE = { width: 390, height: 844 };

test.describe.configure({ mode: 'serial' });

const founder = { email: uniqueEmail('nav-f'), password: PASSWORD, pin: PIN };
const member = uniqueEmail('nav-m');

const tabIds = (tabbar: Locator) =>
	tabbar.getByRole('link').evaluateAll((links) => links.map((l) => (l as HTMLElement).dataset.tab));
const width = async (locator: Locator) => (await locator.boundingBox())?.width ?? 0;

/** At 320, 360 and 390 px, every tab sits inside the bar and the bar on screen. */
async function expectTabsFit(page: Page, pages: Record<string, string>) {
	for (const w of [320, 360, 390]) {
		await page.setViewportSize({ width: w, height: 760 });
		for (const [id, path] of Object.entries(pages)) {
			await page.goto(path);
			const tab = page.locator(`.tabbar [data-tab="${id}"]`);
			await expect(tab).toHaveAttribute('aria-current', 'page');
			await page.waitForTimeout(320); // the pill's 260 ms width animation
			const boxes = await page.evaluate(() => {
				const bar = document.querySelector('.tabbar')!.getBoundingClientRect();
				const tabs = [...document.querySelectorAll('.tabbar .tab')].map((t) =>
					t.getBoundingClientRect()
				);
				return {
					bar: { left: bar.left, right: bar.right },
					tabs: tabs.map((t) => [t.left, t.right, t.width])
				};
			});
			expect(boxes.bar.left, `${w}px ${id}`).toBeGreaterThanOrEqual(0);
			expect(boxes.bar.right, `${w}px ${id}`).toBeLessThanOrEqual(w);
			for (const [left, right, size] of boxes.tabs) {
				expect(left, `${w}px ${id}`).toBeGreaterThanOrEqual(boxes.bar.left);
				expect(right, `${w}px ${id}`).toBeLessThanOrEqual(boxes.bar.right);
				expect(size, `${w}px ${id}: 44 px targets`).toBeGreaterThanOrEqual(44);
			}
		}
	}
}

async function theme(page: Page, value: 'light' | 'dark') {
	await page.context().addCookies([{ name: 'ew_theme', value, url: page.url() }]);
	await page.reload();
}

/** The switcher block's and the top bar's bottom borders share one pixel row. */
async function expectHeaderLine(page: Page) {
	for (const w of [1024, 1280, 1440, 1920]) {
		await page.setViewportSize({ width: w, height: 900 });
		const lines = await page.evaluate(() =>
			['.switcher-block', '.topbar'].map(
				(s) => document.querySelector(s)!.getBoundingClientRect().bottom
			)
		);
		expect(lines[0], `width ${w}`).toBe(lines[1]);
		expect(lines[0], `width ${w}`).toBe(64);
	}
}

test('President Team: network home, leader tabs, sections, no wallet items', async ({ page }) => {
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await memberWithAccount(founder, NETWORK, member);
	await recordIncome(founder, member, '1000.00');
	await recordIncome(founder, member, '25.00', 'USD');

	await page.setViewportSize(DESKTOP);
	await asPresident(page, founder.email, NETWORK);
	await expect(page).toHaveURL(/\/app$/);

	// The network home: this month's income, one currency at a time.
	const hero = page.getByRole('region', { name: 'Income recorded this month' });
	await expect(hero.getByTestId('network-income')).toHaveText('₦1,000.00');
	const offices = page.getByRole('table', { name: /per office/ });
	await expect(offices.getByRole('row', { name: /Navigation World Team/ })).toContainText(
		'₦1,000.00'
	);
	await hero.getByRole('button', { name: 'USD' }).click();
	await expect(hero.getByTestId('network-income')).toHaveText('$25.00');
	await expect(offices.getByRole('row', { name: /Navigation World Team/ })).toContainText('$25.00');
	await hero.getByRole('button', { name: 'NGN' }).click();
	await expect(page.getByRole('heading', { name: 'No wallet in this workspace' })).toHaveCount(0);
	await expect(page.locator('.topbar .breadcrumb')).toHaveText('Network overview');

	// The sectioned sidebar (owner decision 2): no My wallet for the President Team.
	const sidebar = page.getByRole('complementary', { name: 'Main' });
	for (const label of ['Approvals', 'Money', 'People', 'Workspace']) {
		await expect(sidebar.getByRole('group', { name: label })).toBeVisible();
	}
	await expect(sidebar.getByRole('group', { name: 'My wallet' })).toHaveCount(0);
	await expect(sidebar.getByRole('link', { name: 'Network overview' })).toHaveAttribute(
		'aria-current',
		'page'
	);
	await expect(
		sidebar
			.getByRole('group', { name: 'Approvals' })
			.getByRole('link', { name: 'Withdrawal queue' })
	).toBeVisible();
	await expect(
		sidebar.getByRole('group', { name: 'People' }).getByRole('link', { name: 'Invitations' })
	).toBeVisible();
	for (const name of ['Withdrawals', 'Payout accounts', 'Statements']) {
		await expect(sidebar.getByRole('link', { name, exact: true })).toHaveCount(0);
	}
	await expectAccessible(page);
	await shot(page, 'NV03-president-desktop-dark');

	await expectHeaderLine(page);
	await page.setViewportSize(DESKTOP);
	await theme(page, 'light');
	await expect(hero.getByTestId('network-income')).toHaveText('₦1,000.00');
	await shot(page, 'NV03-president-desktop-light');
	await theme(page, 'dark');

	// Mobile: the pill bar's leader set.
	await page.setViewportSize(MOBILE);
	await expect(hero.getByTestId('network-income')).toHaveText('₦1,000.00');
	const tabbar = page.getByRole('navigation', { name: 'Main' });
	expect(await tabIds(tabbar)).toEqual(['home', 'approvals', 'people', 'activity', 'more']);
	await expect(tabbar.locator('[data-tab="home"]')).toHaveAttribute('aria-current', 'page');
	await expectNoHorizontalScroll(page);
	await expectAccessible(page);
	await shot(page, 'NV01-president-mobile-dark');
	await theme(page, 'light');
	await shot(page, 'NV01-president-mobile-light');
	await theme(page, 'dark');

	// The pill grows on the tapped tab and Home folds back to its icon.
	const people = tabbar.locator('[data-tab="people"]');
	const home = tabbar.locator('[data-tab="home"]');
	const folded = await width(people);
	expect(folded).toBeLessThanOrEqual(56);
	await people.click();
	await expect(people).toHaveAttribute('aria-current', 'page');
	await expect(page).toHaveURL(/\/app\/members$/);
	await expect.poll(() => width(people)).toBeGreaterThan(folded + 30);
	await expect.poll(() => width(home)).toBeLessThanOrEqual(56);
	// Offices belongs to People too.
	await page.goto('/app/offices');
	await expect(people).toHaveAttribute('aria-current', 'page');
	// Activity is the network's audit log (the President Team holds no wallet).
	await tabbar.locator('[data-tab="activity"]').click();
	await expect(page).toHaveURL(/\/app\/audit$/);

	// Every selected tab fits the bar on narrow phones (P-06: 320 px).
	await expectTabsFit(page, {
		home: '/app',
		approvals: '/app/queue',
		people: '/app/members',
		activity: '/app/audit',
		more: '/app/more'
	});
});

test('member: wallet tabs and My wallet; no leadership sections', async ({ page }) => {
	await page.setViewportSize(DESKTOP);
	await signInAs(page, member);
	await expect(page).toHaveURL(/\/app$/);
	await expect(page.getByRole('region', { name: 'Balance' })).toBeVisible();

	const sidebar = page.getByRole('complementary', { name: 'Main' });
	const mine = sidebar.getByRole('group', { name: 'My wallet' });
	for (const name of ['Withdrawals', 'Payout accounts', 'Statements', 'Pockets & split']) {
		await expect(mine.getByRole('link', { name })).toBeVisible();
	}
	for (const label of ['Approvals', 'Money', 'People']) {
		await expect(sidebar.getByRole('group', { name: label })).toHaveCount(0);
	}
	await expect(sidebar.getByRole('link', { name: 'Activity' })).toBeVisible();
	await shot(page, 'NV-member-desktop-dark');

	await page.setViewportSize(MOBILE);
	const tabbar = page.getByRole('navigation', { name: 'Main' });
	expect(await tabIds(tabbar)).toEqual(['home', 'activity', 'withdraw', 'more']);
	await shot(page, 'NV-member-home-mobile-dark');

	const activity = tabbar.locator('[data-tab="activity"]');
	const folded = await width(activity);
	await activity.click();
	await expect(page).toHaveURL(/\/app\/activity$/);
	await expect(activity).toHaveAttribute('aria-current', 'page');
	await expect.poll(() => width(activity)).toBeGreaterThan(folded + 30);
	await expectNoHorizontalScroll(page);
	await shot(page, 'NV02-member-activity-mobile-dark');
	await theme(page, 'light');
	await shot(page, 'NV02-member-activity-mobile-light');

	await expectTabsFit(page, {
		home: '/app',
		activity: '/app/activity',
		withdraw: '/app/withdrawals',
		more: '/app/more'
	});
	await page.setViewportSize(MOBILE);

	// More lists My wallet too.
	await page.goto('/app/more');
	await expect(page.getByRole('region', { name: 'My wallet' })).toBeVisible();
	await expect(page.getByRole('region', { name: 'Approvals' })).toHaveCount(0);
	await shot(page, 'NV-member-more-mobile-light');
});
