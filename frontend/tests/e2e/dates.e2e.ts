// Slice 32 (owner 2026-10-11, Paper "Date picker v8" DP01/DP02): every date
// field reads "2 Oct 2026" and opens the app's calendar (anchored on desktop,
// a sheet on phones) with the WAI-ARIA keys; days after today can't be chosen
// where the field has a max. And the member picker's rows line up with its
// search box, with Close inside the dialog. Local stack only, synthetic data.

import { expect, test } from './fixtures';
import { createConfirmedAccount, expectAccessible, uniqueEmail, walletPeople } from './helpers';

const { PASSWORD, PIN, memberWithAccount, asPresident } = walletPeople;
const NETWORK = 'Dates Test Network';

test.describe.configure({ mode: 'serial' });

const founder = { email: uniqueEmail('dates-f'), password: PASSWORD, pin: PIN };

const label = (d: Date) =>
	`${d.getDate()} ${d.toLocaleString('en-GB', { month: 'short' })} ${d.getFullYear()}`;

test('desktop: the calendar under the field, keys, Today, no future days', async ({ page }) => {
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await memberWithAccount(founder, NETWORK, uniqueEmail('dates-m'));
	await asPresident(page, founder.email, NETWORK);
	await page.setViewportSize({ width: 1440, height: 960 });
	await page.goto('/app/income');

	const field = page.locator('#income-date');
	const today = new Date();
	await expect(field).toHaveText(label(today));
	await field.click();
	const cal = page.getByRole('dialog', { name: 'Date received' });
	await expect(cal).toBeVisible();
	const f = (await field.boundingBox())!;
	const c = (await cal.boundingBox())!;
	expect(Math.abs(c.x - f.x)).toBeLessThan(2);
	expect(c.y).toBeGreaterThan(f.y + f.height - 1);

	// Focus starts on the chosen day; Left then Enter picks yesterday.
	await expect(
		cal.getByRole('button', { name: new RegExp(`^\\w+ ${today.getDate()} `) })
	).toBeFocused();
	await page.keyboard.press('ArrowLeft');
	await page.keyboard.press('Enter');
	await expect(cal).toHaveCount(0);
	const yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1);
	await expect(field).toHaveText(label(yesterday));
	await expect(field).toBeFocused();

	// Tomorrow can't be chosen (Date received is up to today); Today chip works.
	await field.click();
	await page.keyboard.press('ArrowRight');
	await page.keyboard.press('ArrowRight');
	await page.keyboard.press('Enter');
	await expect(cal).toHaveCount(0);
	await expect(field).toHaveText(label(today));
	await field.click();
	await expectAccessible(page);
	await cal.getByRole('button', { name: 'Yesterday' }).click();
	await expect(field).toHaveText(label(yesterday));

	// The month title opens months; Escape goes back, then closes.
	await field.click();
	await cal.getByRole('button', { name: /choose month and year/ }).click();
	await expect(cal.getByRole('group', { name: /Months of/ })).toBeVisible();
	await page.keyboard.press('Escape');
	await expect(cal.getByRole('grid')).toBeVisible();
	await page.keyboard.press('Escape');
	await expect(cal).toHaveCount(0);
});

test('the member picker: rows under the search box, Close inside the dialog', async ({ page }) => {
	await asPresident(page, founder.email, NETWORK);
	await page.setViewportSize({ width: 1440, height: 960 });
	await page.goto('/app/income');
	await page.getByRole('button', { name: /Member/ }).click();
	const picker = page.getByRole('dialog', { name: 'Choose the member' });
	await expect(picker.getByRole('button', { name: /Ada Obi/ })).toBeVisible();
	const search = (await picker.getByLabel('Search members').boundingBox())!;
	const row = (await picker.getByRole('button', { name: /Ada Obi/ }).boundingBox())!;
	expect(Math.abs(row.x - search.x)).toBeLessThan(12);
	const box = (await picker.boundingBox())!;
	const close = (await picker.getByRole('button', { name: 'Close' }).boundingBox())!;
	expect(close.x).toBeGreaterThan(box.x + 8);
	expect(close.y + close.height).toBeLessThan(box.y + box.height - 8);
});

test('phone: the calendar is a sheet; a tap chooses', async ({ page }) => {
	await asPresident(page, founder.email, NETWORK);
	await page.setViewportSize({ width: 390, height: 844 });
	await page.goto('/app/income');
	await page.locator('#income-date').click();
	const sheet = page.getByRole('dialog', { name: 'Date received' });
	await expect(sheet).toBeVisible();
	const today = new Date();
	const first = new Date(today.getFullYear(), today.getMonth(), 1);
	await sheet.getByRole('button', { name: new RegExp(`^\\w+ 1 `) }).click();
	await expect(sheet).toHaveCount(0);
	await expect(page.locator('#income-date')).toHaveText(label(first));
});
