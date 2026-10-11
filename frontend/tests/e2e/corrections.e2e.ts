// Conversions, adjustments, returned funds and reversals (W-12, W-14–W-16;
// Blueprint 12). The President records a conversion and an adjustment from a
// member's wallet; a second President, assigned as Financial Evidence
// Reviewer, clears them. A completed payout gets money back (returned funds),
// and an income is reversed. Local stack only, synthetic data. Set E2E_SHOTS
// to a folder to keep screenshots for the Paper comparison.

import { type Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	addReviewer,
	createConfirmedAccount,
	expectAccessible,
	expectNoHorizontalScroll,
	finishCheck,
	localSql,
	pick,
	recordIncome,
	shot,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, memberWithAccount, signInAs, asPresident } = walletPeople;
const PROOF = {
	name: 'grey-conversion.pdf',
	mimeType: 'application/pdf',
	buffer: Buffer.from('%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << >>\n%%EOF\n')
};

test.describe.configure({ mode: 'serial' });

const walletOf = (email: string) =>
	localSql(
		`select w.id from ledger.wallets w join auth.users u on u.id = w.owner_user_id where u.email = '${email}'`
	);

/** The same screen at 390 px (Paper mobile): no sideways scroll, captured for the comparison. */
async function onMobile(page: Page, name: string) {
	const size = page.viewportSize();
	await page.setViewportSize({ width: 390, height: 844 });
	await expectNoHorizontalScroll(page);
	await shot(page, name);
	if (size) await page.setViewportSize(size);
}

/** Fills the PIN when the 5-minute window has lapsed (the sign-in PIN usually covers it). */
async function pinIfAsked(page: Page, dialog: string, confirm: string, done: RegExp) {
	const pin = page.getByRole('dialog', { name: dialog });
	await expect(page.getByRole('heading', { name: done }).or(pin)).toBeVisible();
	if (await pin.isVisible()) {
		await pin.getByLabel('Your PIN').fill(PIN);
		await pin.getByRole('button', { name: confirm }).click();
	}
	await expect(page.getByRole('heading', { name: done })).toBeVisible();
}

async function clearCase(page: Page, row: RegExp, notice: RegExp) {
	await page.getByRole('button', { name: row }).first().click();
	await page.getByLabel('Reason').fill('Statement matches the record');
	await page.getByRole('button', { name: 'Clear' }).click();
	await expect(page.getByText(notice)).toBeVisible();
}

test('a conversion and an adjustment are checked by an evidence reviewer', async ({ page }) => {
	const network = 'Convert Test Network';
	const founder = { email: uniqueEmail('cv-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('cv-m');
	await memberWithAccount(founder, network, member);
	await recordIncome(founder, member, '1000.00', 'USD');
	await recordIncome(founder, member, '10000.00');
	const reviewer = uniqueEmail('cv-r');
	await createConfirmedAccount(reviewer, PASSWORD, PIN);
	await addReviewer(founder, reviewer);
	const wallet = walletOf(member);

	// B07 → MV04: from the member's wallet ("Convert" next to Move).
	await asPresident(page, founder.email, network);
	await page.goto(`/app/wallets?wallet=${wallet}`);
	await page.getByRole('link', { name: 'Convert' }).click();
	await expect(page).toHaveURL(/\/app\/convert\?member=/);
	await pick(page.getByLabel('Pocket', { exact: true }), /^Point Value \$400\.00 available in USD/);
	await page.getByLabel('Converted from').fill('100');
	await page.getByLabel('Actually received').fill('152000');
	await page.getByLabel('Provider').fill('Grey');
	await page.getByLabel('Quoted rate').fill('1525');
	await page.locator('input[type=file]').setInputFiles(PROOF);
	await expect(page.getByText('₦1,520.00 per $1').filter({ visible: true }).first()).toBeVisible();
	await expect(page.getByText('₦500.00')).toBeVisible();
	await expectAccessible(page);
	await shot(page, 'B07-record-conversion');
	await onMobile(page, 'B08-record-conversion-mobile');
	await page.getByRole('button', { name: 'Submit for review' }).click();
	await pinIfAsked(
		page,
		'Confirm with your PIN',
		'Submit for review',
		/Conversion sent for checking/
	);
	await expect(page.getByText('$100.00 → ₦152,000.00')).toBeVisible();
	await shot(page, 'MV04-conversion-sent');

	// E05 → MV02 (PIN always) → MV03.
	await page.goto(`/app/wallets?wallet=${wallet}`);
	await page.getByRole('link', { name: 'Adjust' }).click();
	await expect(page).toHaveURL(/\/app\/adjust\?member=/);
	await page.getByLabel('Amount', { exact: true }).fill('1000');
	await page.locator('input[type=file]').setInputFiles({ ...PROOF, name: 'approval-letter.pdf' });
	await expect(page.getByText('₦400.00').filter({ visible: true }).first()).toBeVisible();
	await shot(page, 'E05-adjustment');
	await onMobile(page, 'E06-adjustment-mobile');
	await page.getByRole('button', { name: 'Submit adjustment' }).click();
	const confirm = page.getByRole('dialog', { name: 'Submit +₦1,000.00?' });
	await expect(confirm.getByText('Goodwill credit from the network')).toBeVisible();
	await shot(page, 'MV02-adjustment-confirm');
	await confirm.getByLabel('Your PIN').fill(PIN);
	await confirm.getByRole('button', { name: 'Submit adjustment' }).click();
	await expect(page.getByRole('heading', { name: 'Adjustment sent for checking' })).toBeVisible();
	await expect(page.getByText(/^ADJ-/).filter({ visible: true })).toBeVisible();
	await shot(page, 'MV03-adjustment-sent');

	// The reviewer clears both; nothing posted before.
	expect(
		localSql(
			`select count(*) from finance.entries where status = 'posted' and id in (select e.id from finance.entries e join auth.users u on u.id = e.owner_user_id where u.email = '${member}')`
		)
	).toBe('0');
	await asPresident(page, reviewer, network);
	await page.goto('/app/evidence');
	await expect(page.getByRole('button', { name: /Conversion · USD → NGN/ })).toBeVisible();
	await page.getByRole('button', { name: /Conversion · USD → NGN/ }).click();
	await expect(page.getByText('grey-conversion.pdf')).toBeVisible();
	await expectAccessible(page);
	await shot(page, 'C09-evidence-conversion');
	await clearCase(page, /Conversion · USD → NGN/, /^Cleared\. CNV-/);
	await clearCase(page, /Adjustment · credit/, /^Cleared\. ADJ-/);
	expect(
		localSql(
			`select count(*) from finance.entries where status = 'posted' and id in (select e.id from finance.entries e join auth.users u on u.id = e.owner_user_id where u.email = '${member}')`
		)
	).toBe('2');
});

test('money comes back from a payout, and an income is reversed', async ({ page }) => {
	const network = 'Return Test Network';
	const founder = { email: uniqueEmail('rt-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('rt-m');
	await memberWithAccount(founder, network, member);
	await recordIncome(founder, member, '10000.00');
	await recordIncome(founder, member, '100.00');
	const reviewer = uniqueEmail('rt-r');
	await createConfirmedAccount(reviewer, PASSWORD, PIN);
	await addReviewer(founder, reviewer);

	// The member withdraws ₦1,500 (M06/M07).
	await signInAs(page, member);
	await page.goto('/app/withdrawals/new');
	await page.getByRole('radio', { name: /Point Value/ }).click();
	await page.getByLabel('Amount').fill('1500');
	await page.getByRole('button', { name: 'Continue to review' }).click();
	await page.getByRole('button', { name: 'Submit request' }).click();
	const wdPin = page.getByRole('dialog', { name: 'Enter your transaction PIN' });
	await wdPin.getByLabel('Your PIN').fill(PIN);
	await wdPin.getByRole('button', { name: 'Submit request' }).click();
	await expect(page.getByRole('heading', { name: 'Request sent' })).toBeVisible();

	// The President approves, pays and records; the check matches.
	await asPresident(page, founder.email, network);
	await page.goto('/app/queue');
	const panel = page.getByRole('region', { name: /Withdrawal WDR-/ });
	await panel.getByRole('button', { name: 'Approve' }).click();
	await expect(page.getByText(/^Approved\./)).toBeVisible();
	await panel.getByLabel('Amount sent').fill('1500');
	await panel.locator('input[type=file]').setInputFiles({ ...PROOF, name: 'transfer.pdf' });
	await panel.getByRole('button', { name: 'Submit for verification' }).click();
	const recPin = page.getByRole('dialog', { name: 'Confirm with your PIN' });
	await expect(page.getByText(/^Sent for verification/).or(recPin)).toBeVisible();
	if (await recPin.isVisible()) {
		await recPin.getByLabel('Your PIN').fill(PIN);
		await recPin.getByRole('button', { name: 'Submit for verification' }).click();
	}
	await expect(page.getByText(/^Sent for verification/)).toBeVisible();
	finishCheck(member);

	// W07 → W09: from the completed withdrawal.
	await page.goto('/app/queue?tab=completed');
	await panel.getByRole('link', { name: /Record returned funds/ }).click();
	await expect(page.getByText('Up to ₦1,500.00')).toBeVisible();
	await page.getByLabel('Amount returned').fill('500');
	await page.getByLabel('Returned by').fill('Guaranty Trust Bank');
	await page.getByLabel('Bank reference').fill('RV-26P8-XQ19');
	await page.locator('input[type=file]').setInputFiles({ ...PROOF, name: 'bank-alert.pdf' });
	await expectAccessible(page);
	await shot(page, 'W07-returned-funds');
	await onMobile(page, 'W08-returned-funds-mobile');
	await page.getByRole('button', { name: 'Send for checking' }).click();
	await pinIfAsked(page, 'Confirm with your PIN', 'Send for checking', /Sent for checking/);
	await expect(page.getByText('Checking proof · no balance change yet')).toBeVisible();
	await shot(page, 'W09-returned-sent');

	await asPresident(page, reviewer, network);
	await page.goto('/app/evidence');
	await clearCase(page, /Returned funds/, /^Cleared\. RTN-/);

	// E07 → MV05: the ₦100 income is reversed.
	const reference = localSql(
		`select t.reference from ledger.transactions t join finance.income_records i on i.transaction_id = t.id
		 where i.amount = 100 and i.owner_user_id = (select id from auth.users where email = '${member}')`
	);
	await asPresident(page, founder.email, network);
	await page.goto(`/app/reversals?reference=${reference}`);
	await expect(page.getByText(reference).first()).toBeVisible();
	await page.getByLabel('Note').fill('Same order was recorded twice.');
	await page.getByLabel(`Type ${reference} to confirm`).fill(reference.toLowerCase());
	await expectAccessible(page);
	await shot(page, 'E07-reverse');
	await onMobile(page, 'E08-reverse-mobile');
	await page.getByRole('button', { name: 'Reverse transaction' }).click();
	await pinIfAsked(page, 'Confirm with your PIN', 'Reverse transaction', /Reversal posted/);
	await expect(page.getByText(`reverses ${reference}`).filter({ visible: true })).toBeVisible();
	await shot(page, 'MV05-reversal-posted');

	await signInAs(page, member);
	await page.goto('/app/activity');
	await expect(page.getByText('Reversed').first()).toBeVisible();
});
