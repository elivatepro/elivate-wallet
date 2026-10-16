// Slice 30 (owner 2026-10-11): desktop dropdowns are a list anchored under the
// field, the header shows only the network's name with a quiet tile, the
// Activity chips have no extra rail, and the Profile banner keeps the photo
// and name on one left edge. Local stack only, synthetic data.

import { expect, test } from './fixtures';
import { createConfirmedAccount, recordIncome, shot, uniqueEmail, walletPeople } from './helpers';

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

// Blueprint 41 (owner 2026-10-15): mobile polish on a 390 px phone.
test('phone: the current tab stays, Home rows open, Dark mode switch, short banner', async ({
	page
}) => {
	await signInAs(page, member);
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto('/app');
	const row = page.locator('a.tx').first();
	await expect(row).toBeVisible();
	await shot(page, '41-home');

	// Tapping the current tab keeps the page (no reload) and scrolls it to the top.
	await page.evaluate(() => {
		(window as Window & { kept?: boolean }).kept = true;
		window.scrollTo(0, 200);
	});
	await page.locator('.tabbar a[aria-current="page"]').click();
	await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(0);
	expect(await page.evaluate(() => (window as Window & { kept?: boolean }).kept)).toBe(true);
	await expect(page).toHaveURL(/\/app$/);

	// A Recent activity row opens its transaction; Back returns Home.
	await row.click();
	await expect(page).toHaveURL(/\/app\/activity\?tx=/);
	await expect(page.getByText('25.00').first()).toBeVisible();
	await shot(page, '41-detail');
	await page.goBack();
	await expect(page).toHaveURL(/\/app$/);

	// More: one Dark mode switch, on for the dark theme; off chooses Light.
	await page.goto('/app/more');
	const dark = page.getByRole('switch', { name: 'Dark mode' });
	await expect(dark).toBeChecked();
	await dark.click();
	await expect(dark).not.toBeChecked();
	await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
	await shot(page, '41-more-light');
	await dark.click();
	await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
	await shot(page, '41-more');

	// Quick search opens as a sheet with its field focused.
	await page.getByRole('button', { name: 'Quick search…' }).click();
	await expect(page.getByRole('combobox')).toBeFocused();
	await page.getByRole('combobox').fill('wi');
	await expect(page.getByRole('option', { name: /Withdrawals/ })).toBeVisible();
	await shot(page, '41-search');
	await page.getByRole('button', { name: 'Cancel' }).click();

	// Withdrawals: the banner is about 200 px on phones.
	await page.goto('/app/withdrawals');
	const banner = (await page.locator('section.hero').boundingBox())!;
	expect(Math.round(banner.height)).toBeLessThanOrEqual(202);
	await shot(page, '41-withdrawals');
});

// Blueprint 43 (owner 2026-10-16): a bottom sheet closes with a drag down.
test('phone: a sheet follows a drag, springs back from a short one, closes past a third or on a flick', async ({
	page
}) => {
	await signInAs(page, member);
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto('/app/account');
	const editButton = page.getByRole('button', { name: 'Edit' });
	const edit = page.getByRole('dialog', { name: 'Edit profile' });
	const open = async () => {
		await editButton.click();
		await expect(edit).toBeVisible();
		await expect.poll(async () => (await edit.boundingBox())?.y).toBeGreaterThan(100);
		const box = (await edit.boundingBox())!;
		const title = (await edit.locator('.rd-title').boundingBox())!;
		return { box, x: title.x + 20, y: title.y + title.height / 2 };
	};
	const slowly = async (x: number, from: number, to: number) => {
		for (let i = 1; i <= 8; i++) {
			await page.mouse.move(x, from + ((to - from) * i) / 8);
			await page.waitForTimeout(16);
		}
		await page.waitForTimeout(200);
	};

	// A short drag: the sheet follows the finger, then springs back.
	const first = await open();
	await page.mouse.move(first.x, first.y);
	await page.mouse.down();
	await slowly(first.x, first.y, first.y + 60);
	expect((await edit.boundingBox())!.y).toBeGreaterThan(first.box.y + 40);
	await page.mouse.up();
	await expect
		.poll(async () => Math.abs((await edit.boundingBox())!.y - first.box.y))
		.toBeLessThan(2);
	await expect(edit).toBeVisible();

	// Past a third of its height: it closes like Cancel (focus back on Edit).
	await page.mouse.move(first.x, first.y);
	await page.mouse.down();
	await slowly(first.x, first.y, first.y + first.box.height * 0.5);
	await page.mouse.up();
	await expect(edit).toHaveCount(0);
	await expect(editButton).toBeFocused();

	// A quick flick down closes it too.
	const again = await open();
	await page.mouse.move(again.x, again.y);
	await page.mouse.down();
	await page.mouse.move(again.x, again.y + 50, { steps: 3 });
	await page.mouse.up();
	await expect(edit).toHaveCount(0);

	// Fields don't start a drag: a drag from the Display name field leaves it open.
	await open();
	const field = (await edit.getByLabel('Display name').boundingBox())!;
	await page.mouse.move(field.x + 20, field.y + field.height / 2);
	await page.mouse.down();
	await page.mouse.move(field.x + 20, field.y + 300, { steps: 3 });
	await page.mouse.up();
	await expect(edit).toBeVisible();
	await page.keyboard.press('Escape');
	await expect(edit).toHaveCount(0);
});
