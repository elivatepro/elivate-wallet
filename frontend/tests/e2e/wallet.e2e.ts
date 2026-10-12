// Ledger-backed Home (W-07), the President's split editor (L01/L02) and the
// NIN leader review loop (Blueprint 06). Local stack only, synthetic data.

import { type Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	completeIdentityAndProfile,
	confirmLinkFor,
	createConfirmedAccount,
	expectAccessible,
	humanReady,
	inviteMember,
	pick,
	recordIncome,
	setJoinPassword,
	uniqueEmail,
	skipInstall
} from './helpers';

const PASSWORD = 'correct-horse-battery';
const PIN = '1357';

test.describe.configure({ mode: 'serial' });

async function joinAsNewMember(page: Page, joinPath: string, email: string) {
	await page.goto(joinPath);
	await page.getByRole('button', { name: 'Verify email' }).click();
	await page.goto(await confirmLinkFor(email, /Confirm your Elivate Wallet email/));
	await page.getByRole('button', { name: 'Continue' }).click();
	await setJoinPassword(page, PASSWORD);
	await page.getByRole('button', { name: 'Accept invitation' }).click();
	await page.getByRole('link', { name: 'Let’s begin' }).click();
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByLabel('Repeat PIN').fill(PIN);
	await page.getByRole('button', { name: 'Save PIN' }).click();
}

async function signInAs(page: Page, email: string) {
	await page.context().clearCookies();
	await page.goto('/sign-in');
	await page.getByLabel('Email address').fill(email);
	await page.getByLabel('Password', { exact: true }).fill(PASSWORD);
	await humanReady(page);
	await page.getByRole('button', { name: 'Sign in' }).click();
	await page.getByLabel('PIN', { exact: true }).fill(PIN);
	await page.getByRole('button', { name: 'Verify' }).click();
	await expect(page).not.toHaveURL(/\/pin(\?.*)?$/);
}

test('member Home shows the posted income split across pockets', async ({ page }) => {
	const founder = { email: uniqueEmail('wallet-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('wallet-m');
	const { joinPath } = await inviteMember(founder, 'Ledger Test Network', member);
	await joinAsNewMember(page, joinPath, member);
	await completeIdentityAndProfile(page);
	await pick(page.getByLabel('Bank', { exact: true }), 'Test Bank');
	await page.getByLabel('Account number').fill('0123456789');
	await page.getByRole('button', { name: 'Check account' }).click();
	await page.getByRole('button', { name: 'Save account' }).click();
	await skipInstall(page);
	await page.getByRole('link', { name: 'Go to my wallet' }).click();
	await expect(page).toHaveURL(/\/app$/);
	await expect(page.getByRole('heading', { name: 'No money in yet' })).toBeVisible();

	await recordIncome(founder, member, '1000.00');
	await page.reload();
	await expect(
		page.getByRole('region', { name: 'Balance' }).getByText('₦1,000.00', { exact: true })
	).toBeVisible();
	await expect(page.getByText('Posted ₦1,000.00')).toBeVisible();
	await expect(page.getByText('Reserved ₦0.00')).toBeVisible();
	// Default split 40 / 10 / 15 / 25 / 10 (U-01).
	await expect(page.getByText('₦400.00', { exact: true })).toBeVisible();
	await expect(page.getByText('40% of income')).toBeVisible();
	await expect(page.getByText('+₦1,000.00')).toBeVisible();
	await expectAccessible(page);

	// Hide amounts masks every figure.
	await page.getByRole('button', { name: 'Hide amounts' }).click();
	await expect(page.getByText('₦1,000.00', { exact: true })).toHaveCount(0);
	await expect(page.getByText('₦••••••', { exact: true }).first()).toBeVisible();
	await page.getByRole('button', { name: 'Show amounts' }).click();
});

test('President edits the split with reason and PIN (L01/L02)', async ({ page }) => {
	const founder = { email: uniqueEmail('split-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await inviteMember(founder, 'Split Test Network', uniqueEmail('split-m'));
	await signInAs(page, founder.email);
	if (page.url().includes('/onboarding')) {
		await page.getByRole('link', { name: 'Let’s begin' }).click();
		await completeIdentityAndProfile(page);
		await skipInstall(page);
		await page.getByRole('link', { name: 'Go to my wallet' }).click();
	}
	await page.goto('/workspaces?switch');
	await page.getByRole('button', { name: /Split Test Network.*President Team/ }).click();
	await page.goto('/app/split');
	await expect(page.getByLabel('Upkeep share of income, percent')).toHaveValue('25.00');
	await page.getByLabel('Upkeep share of income, percent').fill('20.00');
	await expect(page.getByRole('button', { name: 'Save split' })).toBeDisabled();
	await page.getByLabel('Savings share of income, percent').fill('15.00');
	await page.getByRole('button', { name: 'Save split' }).click();
	const dialog = page.getByRole('dialog', { name: 'Save the new split?' });
	await expect(dialog.getByText('Upkeep 25 → 20% · Savings 10 → 15%')).toBeVisible();
	await dialog.getByLabel('Reason').fill('More set aside for savings.');
	await dialog.getByLabel('Your PIN').fill(PIN);
	await dialog.getByRole('button', { name: 'Save split' }).click();
	await expect(page.getByText('Saved. New income uses version 2.')).toBeVisible();
	await expect(page.getByText('More set aside for savings. · version 2')).toBeVisible();
	await expectAccessible(page);
});

test('a failed NIN goes to leader review; the President approves it', async ({ page }) => {
	const founder = { email: uniqueEmail('review-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('review-m');
	const { joinPath } = await inviteMember(founder, 'Review Test Network', member);
	await joinAsNewMember(page, joinPath, member);

	// Two misses, then only a review is possible.
	for (const nin of ['91111111111', '92222222222']) {
		await page.getByLabel('National Identification Number').fill(nin);
		await page.getByRole('button', { name: /^(Verify NIN|Try again)$/ }).click();
	}
	await expect(page.getByRole('heading', { name: 'Ask a leader to review' })).toBeVisible();
	await page.getByLabel('National Identification Number').fill('93333333333');
	await page.getByLabel('First name').fill('Bola');
	await page.getByLabel('Surname').fill('Ade');
	await page.getByRole('button', { name: 'Ask for a review' }).click();
	await expect(page.getByRole('heading', { name: 'Your leader is reviewing it' })).toBeVisible();

	await signInAs(page, founder.email);
	if (page.url().includes('/onboarding')) {
		await page.getByRole('link', { name: 'Let’s begin' }).click();
		await completeIdentityAndProfile(page);
		await skipInstall(page);
		await page.getByRole('link', { name: 'Go to my wallet' }).click();
	}
	await page.goto('/workspaces?switch');
	await page.getByRole('button', { name: /Review Test Network.*President Team/ }).click();
	await page.goto('/app/reviews');
	await expect(page.getByText('Bola Ade')).toBeVisible();
	await page.getByRole('button', { name: 'Approve' }).click();
	const dialog = page.getByRole('dialog', { name: 'Approve this name?' });
	await dialog.getByLabel('Reason').fill('Checked the ID card in person.');
	await dialog.getByLabel('Your PIN').fill(PIN);
	await dialog.getByRole('button', { name: 'Approve' }).click();
	await expect(page.getByText('Approved: Bola Ade.')).toBeVisible();

	// The member continues past identity, confirmed by a leader.
	await signInAs(page, member);
	await page.goto('/onboarding/details');
	await expect(page.getByText('Confirmed by a leader')).toBeVisible();
});
