// Slice 28 (Paper "PIN unlock v7" PU01–PU03): a PIN owed inside the app locks
// in place instead of saying "no access". Nothing readable stays behind (the
// page is unmounted and every saved copy is deleted), removing the sheet in the
// browser shows nothing, a wrong PIN says how many tries are left, and the
// right one opens the page again. Local stack only, synthetic data.

import { type Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	createConfirmedAccount,
	expectAccessible,
	localSql,
	recordIncome,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, memberWithAccount, signInAs } = walletPeople;
const NETWORK = 'Unlock Test Network';

test.describe.configure({ mode: 'serial' });

const founder = { email: uniqueEmail('unlock-f'), password: PASSWORD, pin: PIN };
const member = uniqueEmail('unlock-m');

/** The session goes past the 15-minute PIN idle limit (B3). */
function goIdle(email: string) {
	localSql(`update identity.session_pin_proofs p
    set last_activity_at = now() - interval '16 minutes'
    from auth.users u where u.id = p.user_id and u.email = '${email}'`);
}

const savedCopies = (page: Page) =>
	page.evaluate(() => Object.keys(localStorage).filter((k) => k.startsWith('ew:cache:')));

for (const viewport of [
	{ name: 'mobile', width: 390, height: 844 },
	{ name: 'desktop', width: 1440, height: 960 }
]) {
	test(`${viewport.name}: a PIN owed locks in place, hides everything, and unlocks on the 4th digit`, async ({
		page
	}) => {
		if (viewport.name === 'mobile') {
			await createConfirmedAccount(founder.email, PASSWORD, PIN);
			await memberWithAccount(founder, NETWORK, member);
			await recordIncome(founder, member, '1000.00');
		}
		await page.setViewportSize(viewport);
		await signInAs(page, member);
		await expect(
			page
				.getByText(/₦1,000\.00/)
				.filter({ visible: true })
				.first()
		).toBeVisible();
		expect((await savedCopies(page)).length).toBeGreaterThan(0);

		goIdle(member);
		// Opening Activity reads from the server. A background read (the bell)
		// may get there first and lock the app before the click: same result.
		await page
			.getByRole('link', { name: 'Activity' })
			.first()
			.click({ timeout: 5000 })
			.catch(() => {});
		const sheet = page.getByRole('dialog', { name: 'Enter your PIN' });
		await expect(sheet).toBeVisible();
		await expect(page.getByText(/don’t have access/)).toHaveCount(0);
		await expect(page.getByText(/₦1,000\.00/)).toHaveCount(0);
		expect(await savedCopies(page)).toEqual([]);
		await expectAccessible(page);

		// Deleting the sheet in the browser reveals nothing: the page isn't there.
		await page.evaluate(() => document.querySelector('[role="dialog"]')?.remove());
		await expect(page.getByText(/₦1,000\.00/)).toHaveCount(0);

		// A fresh load asks again, in place.
		await page.reload();
		await expect(sheet).toBeVisible();
		await sheet.getByLabel('PIN').pressSequentially(PIN === '0000' ? '1111' : '0000');
		await expect(sheet.getByText('Wrong PIN. 4 tries left.')).toBeVisible();

		// Typed key by key, as a person would: the retry must not be blocked.
		await sheet.getByLabel('PIN').pressSequentially(PIN);
		await expect(sheet).toHaveCount(0);
		await expect(page).toHaveURL(/\/app(\/activity)?$/);
		await expect(
			page
				.getByText(/₦1,000\.00/)
				.filter({ visible: true })
				.first()
		).toBeVisible();
	});
}
