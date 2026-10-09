// Withdrawals and pocket moves (W-09–W-11, W-13; Blueprint 11): a member
// requests a withdrawal with their PIN, the President approves it, reveals
// the destination, records the payout with a receipt, and the receipt check
// (stubbed in the local database: no OpenAI call) matches, completing it. A
// pocket move is requested and approved. Local stack only, synthetic data.

import { expect, test } from './fixtures';
import {
	createConfirmedAccount,
	expectAccessible,
	inviteMember,
	localSql,
	recordIncome,
	shot,
	finishCheckAsMatch,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, joinAsNewMember, signInAs, asPresident } = walletPeople;
const RECEIPT = {
	name: 'access-transfer.pdf',
	mimeType: 'application/pdf',
	buffer: Buffer.from('%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << >>\n%%EOF\n')
};

test.describe.configure({ mode: 'serial' });

/** Stands in for the payout-checker worker: the receipt shows another payment date. */
function finishCheckAsDateMismatch() {
	localSql(`do $$
declare
  job jsonb := api.claim_payout_checks('e2e', 1)->0;
  paid date := (select r.paid_on from finance.payout_checks c
                join finance.payout_revisions r on r.id = c.revision_id
                where c.id = (job->>'checkId')::uuid);
begin
  perform api.finish_payout_check((job->>'checkId')::uuid, (job->>'leaseToken')::uuid, 'mismatch',
    jsonb_build_object('paymentDate', (paid - 1)::text, 'receipt', jsonb_build_object(
      'amount', job->'expected'->>'amount', 'currency', 'NGN', 'recipientAccount', '0123456789',
      'recipientName', job->'expected'->>'recipientName', 'transactionDate', (paid - 1)::text,
      'paymentStatus', 'successful', 'confidence', 'high')),
    array['paymentDate_mismatch'], 'e2e-stub', 'strict-single-receipt-v1');
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

	// President: C01 approve → U01 reveal (PIN) → U02 record → C05 checking.
	await asPresident(page, founder.email, 'Withdraw Test Network');
	await page.getByRole('link', { name: 'Withdrawal queue' }).first().click();
	const panel = page.getByRole('region', { name: /Withdrawal WDR-/ });
	await expect(panel.getByText('₦1,500.00').first()).toBeVisible();
	await expectAccessible(page);
	await panel.getByRole('button', { name: 'Approve' }).click();
	await expect(page.getByText(/^Approved\./)).toBeVisible();
	// The sign-in PIN opened a fresh 5-minute proof, so the PIN is asked only if it lapsed.
	await panel.getByRole('button', { name: 'Reveal' }).click();
	const revealPin = page.getByRole('dialog', { name: 'Show account number' });
	await expect(panel.getByText('0123456789').or(revealPin)).toBeVisible();
	if (await revealPin.isVisible()) {
		await shot(page, 'U01-reveal-pin');
		await revealPin.getByLabel('Your PIN').fill(PIN);
		await revealPin.getByRole('button', { name: 'Show number' }).click();
	}
	await expect(panel.getByText('0123456789')).toBeVisible();
	await expect(panel.getByRole('button', { name: 'Hide' })).toBeVisible();

	await panel.getByLabel('Amount sent').fill('1450');
	await panel.getByLabel('Bank reference').fill('000014261005173300');
	await panel.getByLabel('Bank fee (optional)').fill('50');
	await panel.locator('input[type=file]').setInputFiles(RECEIPT);
	await expect(panel.getByText('access-transfer.pdf')).toBeVisible();
	await shot(page, 'U02-revealed-record');
	await panel.getByRole('button', { name: 'Submit for verification' }).click();
	await expect(page.getByText(/^Sent for verification/)).toBeVisible();
	await page.getByRole('tab', { name: /Verifying/ }).click();
	await expect(panel.getByText('Checking receipt')).toBeVisible();

	// The receipt shows another date (stubbed worker): U03, the one fix keeps the receipt.
	finishCheckAsDateMismatch();
	await page.getByRole('tab', { name: /Needs action/ }).click();
	await expect(panel.getByText('Correction needed · 1 left')).toBeVisible();
	await panel.getByRole('button', { name: 'Fix the date' }).click();
	const fix = page.getByRole('dialog', { name: 'Fix the date' });
	await expect(fix.getByLabel('Date paid')).toBeVisible();
	await shot(page, 'U03-fix-date');
	await fix.getByLabel('Your PIN').fill(PIN);
	await fix.getByRole('button', { name: 'Send again' }).click();
	await expect(page.getByText(/^Sent again\./)).toBeVisible();

	// The second check matches, completing the withdrawal (U04).
	finishCheckAsMatch();
	await page.getByRole('tab', { name: 'Completed' }).click();
	await expect(panel.getByText('Completed', { exact: true })).toBeVisible();
	await expect(page.getByRole('heading', { name: '₦1,500.00 paid out' })).toBeVisible();
	await shot(page, 'U04-completed');

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
	await expect(page.getByRole('heading', { name: 'Move requested' })).toBeVisible();
	await expect(
		page.getByText(/from Point Value to Savings is held until your leader approves/)
	).toBeVisible();
	await expectAccessible(page);
	await shot(page, 'MV01-move-requested');

	await asPresident(page, founder.email, 'Move Test Network');
	await page.getByRole('link', { name: 'Transfers' }).first().click();
	const panel = page.getByRole('region', { name: /Pocket move PTR-/ });
	await expect(panel.getByText('Point Value', { exact: true })).toBeVisible();
	await panel.getByRole('button', { name: 'Approve & move' }).click();
	await expect(page.getByText(/^Moved ₦100\.00 from Point Value to Savings\./)).toBeVisible();
});
