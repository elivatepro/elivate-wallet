// Withdrawals and pocket moves (W-09–W-11, W-13; Blueprint 11): a member
// requests a withdrawal with their PIN, the President approves it, reveals
// the destination, records the payout with a receipt, and the receipt check
// (stubbed in the local database: no OpenAI call) matches, completing it. A
// pocket move is requested and approved. Local stack only, synthetic data.

import { type Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	completeIdentityAndProfile,
	confirmLinkFor,
	createConfirmedAccount,
	expectAccessible,
	humanReady,
	inviteMember,
	localSql,
	recordIncome,
	setJoinPassword,
	uniqueEmail
} from './helpers';

const PASSWORD = 'correct-horse-battery';
const PIN = '1357';
const RECEIPT = {
	name: 'access-transfer.pdf',
	mimeType: 'application/pdf',
	buffer: Buffer.from('%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << >>\n%%EOF\n')
};

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
	await completeIdentityAndProfile(page);
	await page.getByLabel('Bank').selectOption('058');
	await page.getByLabel('Account number').fill('0123456789');
	await page.getByRole('button', { name: 'Check account' }).click();
	await page.getByRole('button', { name: 'Save account' }).click();
	await page.getByRole('link', { name: 'Go to my wallet' }).click();
	await expect(page).toHaveURL(/\/app$/);
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

async function asPresident(page: Page, email: string, network: string) {
	await signInAs(page, email);
	if (page.url().includes('/onboarding')) {
		await page.getByRole('link', { name: 'Let’s begin' }).click();
		await completeIdentityAndProfile(page);
		await page.getByRole('link', { name: 'Go to my wallet' }).click();
	}
	await page.goto('/workspaces?switch');
	await page.getByRole('button', { name: new RegExp(`${network}.*President Team`) }).click();
}

/** Stands in for the payout-checker worker: lease the queued check and report a match. */
function finishCheckAsMatch() {
	localSql(`do $$
declare
  job jsonb := api.claim_payout_checks('e2e', 1)->0;
  paid text := (select r.paid_on::text from finance.payout_checks c
                join finance.payout_revisions r on r.id = c.revision_id
                where c.id = (job->>'checkId')::uuid);
begin
  perform api.finish_payout_check((job->>'checkId')::uuid, (job->>'leaseToken')::uuid, 'match',
    jsonb_build_object('paymentDate', paid, 'receipt', jsonb_build_object(
      'amount', job->'expected'->>'amount', 'currency', 'NGN', 'recipientAccount', '0123456789',
      'recipientName', job->'expected'->>'recipientName', 'transactionDate', paid,
      'paymentStatus', 'successful', 'confidence', 'high')),
    '{}'::text[], 'e2e-stub', 'strict-single-receipt-v1');
end $$`);
}

test('a withdrawal is requested, approved, paid out and verified', async ({ page }) => {
	const founder = { email: uniqueEmail('wd-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('wd-m');
	const { joinPath } = await inviteMember(founder, 'Withdraw Test Network', member);
	await joinAsNewMember(page, joinPath, member);
	await recordIncome(founder, member, '10000.00');

	// Member: M06 → M07 (PIN) → M08.
	await page.goto('/app/withdrawals');
	await expect(page.getByRole('heading', { name: '₦0.00' })).toBeVisible();
	await page.getByRole('link', { name: 'New withdrawal' }).click();
	await expect(page.getByRole('heading', { name: 'Withdraw to your bank' })).toBeVisible();
	await page.getByRole('radio', { name: /Point Value/ }).click();
	await page.getByLabel('Amount').fill('999999');
	await page.getByRole('button', { name: 'Continue to review' }).click();
	await expect(page.getByText(/You can withdraw up to/).first()).toBeVisible();
	await page.getByLabel('Amount').fill('1500');
	await page.getByRole('button', { name: 'Continue to review' }).click();
	await expect(page.getByRole('heading', { name: 'Review your withdrawal' })).toBeVisible();
	await expectAccessible(page);
	await page.getByRole('button', { name: 'Submit request' }).click();
	const pin = page.getByRole('dialog', { name: 'Enter your transaction PIN' });
	await pin.getByLabel('Your PIN').fill(PIN);
	await pin.getByRole('button', { name: 'Submit request' }).click();
	await expect(page.getByRole('heading', { name: 'Request sent' })).toBeVisible();
	await expect(page.getByText(/^Reference WDR-/)).toBeVisible();
	await page.getByRole('link', { name: 'Track this withdrawal' }).click();
	await expect(page.getByRole('heading', { name: '₦1,500.00' })).toBeVisible();
	await expect(page.getByText('Requested').first()).toBeVisible();

	// President: C01 approve → T03 reveal + record → C05 checking.
	await asPresident(page, founder.email, 'Withdraw Test Network');
	await page.getByRole('link', { name: 'Withdrawal queue' }).first().click();
	const panel = page.getByRole('region', { name: /Withdrawal WDR-/ });
	await expect(panel.getByText('₦1,500.00').first()).toBeVisible();
	await expectAccessible(page);
	await panel.getByRole('button', { name: 'Approve' }).click();
	await expect(page.getByText(/^Approved\./)).toBeVisible();
	// The sign-in PIN opened a fresh 5-minute proof, so the PIN is asked only if it lapsed.
	await panel.getByRole('button', { name: 'Reveal' }).click();
	const revealPin = page.getByRole('dialog', { name: 'Enter your transaction PIN' });
	await expect(panel.getByText('0123456789').or(revealPin)).toBeVisible();
	if (await revealPin.isVisible()) {
		await revealPin.getByLabel('Your PIN').fill(PIN);
		await revealPin.getByRole('button', { name: 'Reveal' }).click();
	}
	await expect(panel.getByText('0123456789')).toBeVisible();

	await panel.getByLabel('Amount sent').fill('1450');
	await panel.getByLabel(/Transfer fee/).fill('50');
	await panel.getByLabel(/Bank reference/).fill('000014261005173300');
	await panel.locator('input[type=file]').setInputFiles(RECEIPT);
	await expect(panel.getByText('access-transfer.pdf')).toBeVisible();
	await panel.getByRole('button', { name: 'Submit for verification' }).click();
	await expect(page.getByText(/^Sent for verification/)).toBeVisible();
	await page.getByRole('tab', { name: /Verifying/ }).click();
	await expect(panel.getByText('Checking receipt')).toBeVisible();

	// The receipt check matches (stubbed worker), completing the withdrawal.
	finishCheckAsMatch();
	await page.getByRole('tab', { name: 'Completed' }).click();
	await expect(panel.getByText('Completed', { exact: true })).toBeVisible();

	await signInAs(page, member);
	await page.goto('/app/withdrawals');
	await expect(page.getByText('−₦1,500.00')).toBeVisible();
});

test('a pocket move is requested and approved', async ({ page }) => {
	const founder = { email: uniqueEmail('mv-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('mv-m');
	const { joinPath } = await inviteMember(founder, 'Move Test Network', member);
	await joinAsNewMember(page, joinPath, member);
	await recordIncome(founder, member, '1000.00');

	await page.goto('/app');
	await page.getByRole('link', { name: 'Move money' }).first().click();
	await expect(page.getByRole('heading', { name: 'Move between pockets' })).toBeVisible();
	const from = page.getByRole('radiogroup', { name: 'From pocket' });
	const to = page.getByRole('radiogroup', { name: 'To pocket' });
	await from.getByRole('radio', { name: /Point Value/ }).click();
	await to.getByRole('radio', { name: /Savings/ }).click();
	await page.getByLabel('Amount').fill('100');
	await page.getByRole('button', { name: 'Continue to review' }).click();
	await page.getByRole('button', { name: 'Send request' }).click();
	await expect(page.getByText('Requested · waiting for approval')).toBeVisible();
	await expectAccessible(page);

	await asPresident(page, founder.email, 'Move Test Network');
	await page.getByRole('link', { name: 'Transfers' }).first().click();
	const panel = page.getByRole('region', { name: /Pocket move PTR-/ });
	await expect(panel.getByText('Point Value', { exact: true })).toBeVisible();
	await panel.getByRole('button', { name: 'Approve & move' }).click();
	await expect(page.getByText(/^Moved ₦100\.00 from Point Value to Savings\./)).toBeVisible();
});
