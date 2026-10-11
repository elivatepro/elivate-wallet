// Blueprint 24: the wheel picker on the public application form (/apply), which
// needs no account: the native <select> without JS, and the sheet's keyboard
// and accessibility with JS, on a phone and on a desktop. The bank search and
// the in-app pickers run inside the member flows (invitations, money, org…).
import { expect, test } from './fixtures';
import { expectAccessible, shot } from './helpers';

test.describe.configure({ mode: 'serial' });

test.describe('without JavaScript', () => {
	test.use({ javaScriptEnabled: false });

	test('the rank is a native select that the form posts', async ({ page }) => {
		await page.goto('/apply');
		const rank = page.getByLabel('Your rank');
		await expect(rank).toHaveJSProperty('tagName', 'SELECT');
		await expect(rank).toHaveAttribute('name', 'rank');
		await expect(rank.locator('option:not([disabled])')).toHaveText([
			'4 Ruby Director',
			'5 Ruby Director',
			'Diamond Director'
		]);
		await rank.selectOption({ label: '5 Ruby Director' });
		await expect(rank).toHaveValue('ruby_director_5');
	});
});

for (const [size, viewport] of [
	['phone', { width: 390, height: 844 }],
	['desktop', { width: 1440, height: 900 }]
] as const) {
	test.describe(size, () => {
		test.use({ viewport });

		test(`keyboard, Escape and the posted value (${size})`, async ({ page, context }) => {
			await context.addCookies([{ name: 'ew_theme', value: 'dark', url: 'http://127.0.0.1:3000' }]);
			await page.goto('/apply');
			const field = page.getByRole('combobox', { name: 'Your rank', exact: true });
			const posted = page.locator('input[type="hidden"][name="rank"]');
			await expect(field).toHaveText('Choose one');
			await expect(field).toHaveAttribute('aria-expanded', 'false');

			// Three options: no search field; the wheel takes focus.
			await field.click();
			const sheet = page.getByRole('dialog', { name: 'Your rank' });
			await expect(sheet).toBeVisible();
			await expect(field).toHaveAttribute('aria-expanded', 'true');
			await expect(sheet.getByRole('combobox')).toHaveCount(0);
			const wheel = sheet.getByRole('listbox', { name: 'Rank' });
			await expect(wheel).toBeFocused();
			await expectAccessible(page);
			await shot(page, `P24-rank-sheet-${size}`);

			// Escape closes without choosing, and focus returns to the field.
			await wheel.press('ArrowDown');
			await page.keyboard.press('Escape');
			await expect(sheet).toHaveCount(0);
			await expect(field).toBeFocused();
			await expect(field).toHaveText('Choose one');
			await expect(posted).toHaveValue('');

			// End, then Enter chooses the last row.
			await field.press('Enter');
			await expect(wheel).toBeFocused();
			await wheel.press('End');
			await expect(sheet.getByRole('option', { name: 'Diamond Director' })).toHaveAttribute(
				'aria-selected',
				'true'
			);
			await wheel.press('Enter');
			await expect(sheet).toHaveCount(0);
			await expect(field).toHaveText('Diamond Director');
			await expect(posted).toHaveValue('diamond_director');

			// Tab stays inside the sheet; tapping a row turns the wheel to it.
			await field.click();
			await expect(wheel).toBeFocused();
			await page.keyboard.press('Tab');
			await expect(sheet.getByRole('button', { name: 'Set rank' })).toBeFocused();
			await page.keyboard.press('Tab');
			await expect(wheel).toBeFocused();
			const first = sheet.getByRole('option', { name: '4 Ruby Director' });
			await first.click();
			await expect(first).toHaveAttribute('aria-selected', 'true');
			await sheet.getByRole('button', { name: 'Set rank' }).click();
			await expect(posted).toHaveValue('ruby_director_4');
			await expect(field).toHaveText('4 Ruby Director');
		});
	});
}

test.describe('a phone on its side', () => {
	test.use({ viewport: { width: 844, height: 390 } });

	test('the sheet fits the screen and scrolls to its button', async ({ page }) => {
		await page.goto('/apply');
		await page.getByRole('combobox', { name: 'Your rank', exact: true }).click();
		const sheet = page.getByRole('dialog', { name: 'Your rank' });
		// After the 200 ms rise, the sheet sits inside the 390 px screen.
		await expect
			.poll(async () => {
				const box = await sheet.boundingBox();
				return !!box && box.y >= 0 && box.y + box.height <= 390;
			})
			.toBe(true);
		await sheet.getByRole('option', { name: '5 Ruby Director' }).click();
		await sheet.getByRole('button', { name: 'Set rank' }).click();
		await expect(page.getByRole('combobox', { name: 'Your rank', exact: true })).toHaveText(
			'5 Ruby Director'
		);
	});
});
