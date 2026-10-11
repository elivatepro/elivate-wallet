// Slice 29 (owner 2026-10-11): forms never submit before the person is done.
// Opening a picker inside a form doesn't submit it, and Enter (a phone
// keyboard's Go / Done) moves to the next field instead of validating the
// whole form. Mobile size, as reported. Local stack only, synthetic data.

import { expect, test } from './fixtures';
import { createConfirmedAccount, recordIncome, uniqueEmail, walletPeople } from './helpers';

const { PASSWORD, PIN, memberWithAccount, signInAs, asPresident } = walletPeople;
const NETWORK = 'Forms Test Network';

test.describe.configure({ mode: 'serial' });
test.use({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });

const founder = { email: uniqueEmail('forms-f'), password: PASSWORD, pin: PIN };
const member = uniqueEmail('forms-m');

test('Record income: choosing a member and pressing Enter show no errors', async ({ page }) => {
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await memberWithAccount(founder, NETWORK, member);
	await asPresident(page, founder.email, NETWORK);
	await page.goto('/app/income');

	// Opening the member picker used to submit the form behind it.
	await page.getByRole('button', { name: /Member/ }).click();
	const picker = page.getByRole('dialog', { name: 'Choose the member' });
	await expect(picker).toBeVisible();
	await picker.getByLabel('Search members').fill('obi');
	await picker.getByLabel('Search members').press('Enter');
	await picker.getByRole('button', { name: /Ada Obi/ }).click();
	for (const message of ['Choose the member.', 'Enter the amount received.', 'Add the receipt.']) {
		await expect(page.getByText(message)).toHaveCount(0);
	}

	// Enter (Go / Done) in the amount moves to Source; nothing is validated.
	const amount = page.getByLabel('Amount received');
	await amount.fill('1000');
	await expect(amount).toHaveAttribute('enterkeyhint', 'next');
	await amount.press('Enter');
	await expect(page.getByLabel('Source')).toBeFocused();
	await page.getByLabel('Source').fill('Fiverr order');
	await page.getByLabel('Source').press('Enter');
	await expect(page.getByText('Add the receipt.')).toHaveCount(0);
	await expect(page.getByRole('dialog')).toHaveCount(0);

	// The button still checks everything.
	await page.getByRole('button', { name: 'Review and post' }).first().click();
	await expect(page.getByText('Add the receipt.')).toBeVisible();
});

test('Invite a member: Enter in the email doesn’t send or complain', async ({ page }) => {
	await asPresident(page, founder.email, NETWORK);
	await page.goto('/app/invitations?invite');
	const form = page.getByRole('dialog', { name: 'Invite a member' });
	await expect(form).toBeVisible();
	await form.getByLabel('Email address').fill('new.person@example');
	await form.getByLabel('Email address').press('Enter');
	await expect(form).toBeVisible();
	await expect(form.getByText('Enter a valid email address.')).toHaveCount(0);
	// Sending is still the button's job, and it still checks.
	await form.getByRole('button', { name: 'Send invitation' }).click();
	await expect(form.getByText('Enter a valid email address.')).toBeVisible();
});

test('Withdraw on a phone (Paper M09/M10): the keypad, then review, then the PIN', async ({
	page
}) => {
	await recordIncome(founder, member, '10000.00');
	await signInAs(page, member);
	await page.goto('/app/withdrawals/new');
	await expect(page.getByRole('heading', { name: 'Withdraw' })).toBeVisible();
	await expect(page.getByText('1 / 3')).toBeVisible();
	// The tab bar is gone: the flow has its own close bar.
	await expect(page.locator('.tabbar')).toHaveCount(0);

	const keypad = page.getByRole('group', { name: 'Amount keypad' });
	for (const key of ['1', '5', '0', '0']) await keypad.getByRole('button', { name: key }).click();
	await keypad.getByRole('button', { name: 'Delete' }).click();
	await keypad.getByRole('button', { name: '0' }).click();
	await expect(page.locator('.big-amount')).toHaveText(/₦1,500$/);
	await expect(page.getByText('Choose a pocket to withdraw from.')).toHaveCount(0);

	await page.getByRole('button', { name: 'Continue' }).click();
	await expect(page.getByText('2 / 3')).toBeVisible();
	const review = page.getByRole('region', { name: 'Review your withdrawal' });
	await expect(review.getByText('₦1,500.00')).toBeVisible();
	await review.getByRole('button', { name: 'Submit request' }).click();
	await expect(page.getByRole('dialog', { name: 'Enter your transaction PIN' })).toBeVisible();
	await page.keyboard.press('Escape');

	// Back to the amount keeps it.
	await page.getByRole('button', { name: 'Back to amount' }).click();
	await expect(page.locator('.big-amount')).toHaveText(/₦1,500$/);
});

test('Withdraw on desktop: Enter after the amount closes the keyboard, no errors', async ({
	page
}) => {
	await page.setViewportSize({ width: 1440, height: 960 });
	await signInAs(page, member);
	await page.goto('/app/withdrawals/new');
	await expect(page.getByRole('heading', { name: 'Withdraw to your bank' })).toBeVisible();
	const amount = page.getByLabel('Amount');
	await amount.fill('1500');
	await expect(amount).toHaveAttribute('enterkeyhint', 'done');
	await amount.press('Enter');
	await expect(amount).not.toBeFocused();
	await expect(page.getByRole('heading', { name: 'Review your withdrawal' })).toHaveCount(0);
});
