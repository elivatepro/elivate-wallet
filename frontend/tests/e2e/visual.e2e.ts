// Slice 30 (owner 2026-10-11): desktop dropdowns are a list anchored under the
// field, the header shows only the network's name with a quiet tile, the
// Activity chips have no extra rail, and the Profile banner keeps the photo
// and name on one left edge. Local stack only, synthetic data.

import { expect, test } from './fixtures';
import { createConfirmedAccount, recordIncome, uniqueEmail, walletPeople } from './helpers';

const { PASSWORD, PIN, memberWithAccount, signInAs, asPresident } = walletPeople;
const NETWORK = 'Visual Test Network';

test.describe.configure({ mode: 'serial' });

const founder = { email: uniqueEmail('vis-f'), password: PASSWORD, pin: PIN };
const member = uniqueEmail('vis-m');

test('desktop: the dropdown opens anchored under its field, keys and clicks choose', async ({
	page
}) => {
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await memberWithAccount(founder, NETWORK, member);
	await recordIncome(founder, member, '25.00', 'USD');
	await asPresident(page, founder.email, NETWORK);
	await page.setViewportSize({ width: 1440, height: 960 });
	await page.goto('/app/income');
	const field = page.locator('#income-currency');
	await field.click();
	const list = page.getByRole('listbox', { name: 'Currency' });
	await expect(list).toBeVisible();
	await expect(page.locator('dialog[data-wheel-picker][open]')).toHaveCount(0);
	const f = (await field.boundingBox())!;
	const l = (await page.locator('.wp-pop').boundingBox())!;
	expect(Math.abs(l.x - f.x)).toBeLessThan(2);
	expect(l.y).toBeGreaterThan(f.y + f.height - 1);
	expect(l.y).toBeLessThan(f.y + f.height + 12);

	// Keyboard: down, Enter.
	await page.keyboard.press('ArrowDown');
	await page.keyboard.press('Enter');
	await expect(list).toHaveCount(0);
	await expect(field).toHaveText(/USD/);
	await expect(field).toBeFocused();

	// Mouse: a click chooses; Escape and a click outside close without choosing.
	await field.click();
	await page.getByRole('option', { name: 'NGN' }).click();
	await expect(field).toHaveText(/NGN/);
	await field.click();
	await page.keyboard.press('Escape');
	await expect(page.locator('.wp-pop')).toHaveCount(0);
	await field.click();
	await page.mouse.click(1200, 900);
	await expect(page.locator('.wp-pop')).toHaveCount(0);
	await expect(field).toHaveText(/NGN/);

	// Follows the page: scrolling moves the open list with its field.
	await page.setViewportSize({ width: 1440, height: 520 });
	await field.evaluate((el) => el.scrollIntoView({ block: 'start' }));
	await field.click();
	const before = (await page.locator('.wp-pop').boundingBox())!;
	await page.evaluate(() => window.scrollBy(0, 40));
	await expect
		.poll(async () => {
			const now = (await page.locator('.wp-pop').boundingBox())!;
			const at = (await field.boundingBox())!;
			return Math.abs(now.y - (at.y + at.height)) < 12 && now.y !== before.y;
		})
		.toBe(true);
	await page.keyboard.press('Escape');

	// No room below: the list opens above the field.
	await field.evaluate((el) => el.scrollIntoView({ block: 'end' }));
	await field.click();
	const above = (await page.locator('.wp-pop').boundingBox())!;
	const at = (await field.boundingBox())!;
	expect(above.y + above.height).toBeLessThanOrEqual(at.y + 1);
	await page.keyboard.press('Escape');
});

test('phone: the header has the name only, the chips no rail, the banner one edge', async ({
	page
}) => {
	await signInAs(page, member);
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto('/app/activity');
	const header = page.locator('.appbar');
	await expect(header.getByText(NETWORK)).toBeVisible();
	await expect(header.getByText(/Member ·/)).toHaveCount(0);
	const rail = await page
		.getByRole('group', { name: 'Direction' })
		.evaluate((el) => getComputedStyle(el).borderTopWidth);
	expect(rail).toBe('0px');

	await page.goto('/app/account');
	const name = page.getByRole('heading', { level: 1 });
	await expect(name).toBeVisible();
	const avatar = page.locator('section.hero .avatar');
	const a = (await avatar.boundingBox())!;
	const n = (await name.boundingBox())!;
	expect(Math.abs(a.x - n.x)).toBeLessThan(2);
	const hero = (await page.locator('section.hero').boundingBox())!;
	expect(a.y).toBeGreaterThanOrEqual(hero.y);
	await expect(avatar.locator('img')).toHaveCount(0);
});
