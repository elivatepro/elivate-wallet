// Wizard step 4, NGN payout account (W-02 step 6, W-17; Paper 11 matched,
// 12 name mismatch, App v3 Y01 identity check pending). Lookup needs a fresh
// PIN (step-up); right after the PIN step it usually still holds, otherwise
// the form asks for the PIN once. Lookup is not confirmation: the person
// saves it explicitly.

import { fail, redirect } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { PIN_PATTERN } from '#lib/contract/common.js';
import { ACCOUNT_NUMBER_PATTERN } from '#lib/contract/payout.js';
import { PayoutApi } from '#lib/server/apis-identity.js';
import { SecurityApi } from '#lib/server/apis.js';
import { failureOf, isBackendError, redirectForFailure } from '#lib/server/flow.js';
import { expectStep } from '#lib/server/onboarding.js';
import { runApi } from '#lib/server/request.js';
import { newIdempotencyKey } from '#lib/server/workspace.js';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async (event) => {
	const { wizard } = await expectStep(event, 'bank');
	const exit = await runApi(
		event,
		wizard.session,
		Effect.gen(function* () {
			return yield* (yield* PayoutApi).banks;
		})
	);
	const legal = wizard.profile!.identity.legalName;
	return {
		banks: Exit.isSuccess(exit) ? exit.value : [],
		banksUnavailable: Exit.isFailure(exit),
		legalName: legal ? [legal.given, ...legal.middle, legal.surname].join(' ') : null,
		stepUpUntil: wizard.state.stepUpExpiresAt,
		idempotencyKey: newIdempotencyKey()
	};
};

export const actions: Actions = {
	lookup: async (event) => {
		const { wizard } = await expectStep(event, 'bank');
		const form = await event.request.formData();
		const bankCode = String(form.get('bankCode') ?? '');
		const accountNumber = String(form.get('accountNumber') ?? '').replace(/\s/g, '');
		const pin = String(form.get('pin') ?? '');
		const idempotencyKey = String(form.get('idempotencyKey') ?? '');
		const echo = { bankCode, accountNumber };
		const errors: Record<string, string> = {};
		if (!bankCode) errors.bankCode = 'Choose your bank.';
		if (!ACCOUNT_NUMBER_PATTERN.test(accountNumber))
			errors.accountNumber = 'Enter the 10-digit account number.';
		if (Object.keys(errors).length) return fail(400, { ...echo, errors });
		const membershipId = wizard.membershipId;
		if (!membershipId) redirect(303, '/onboarding/continue');

		if (pin) {
			if (!PIN_PATTERN.test(pin))
				return fail(400, { ...echo, needPin: true, errors: { pin: 'Enter your 4-digit PIN.' } });
			const verified = await runApi(
				event,
				wizard.session,
				Effect.gen(function* () {
					return yield* (yield* SecurityApi).verifyPin({ pin });
				})
			);
			if (Exit.isFailure(verified)) {
				const failure = failureOf(verified);
				if (isBackendError(failure, 'pin_incorrect')) {
					return fail(403, { ...echo, needPin: true, errors: { pin: 'That PIN is incorrect.' } });
				}
				redirectForFailure(failure);
			}
		}

		const exit = await runApi(
			event,
			wizard.session,
			Effect.gen(function* () {
				return yield* (yield* PayoutApi).lookup(membershipId, {
					bankCode,
					accountNumber,
					idempotencyKey
				});
			})
		);
		if (Exit.isSuccess(exit)) {
			return { ...echo, lookup: exit.value, confirmKey: newIdempotencyKey() };
		}
		const failure = failureOf(exit);
		if (isBackendError(failure, 'step_up_required')) return fail(403, { ...echo, needPin: true });
		if (isBackendError(failure, 'account_not_found')) {
			return fail(422, {
				...echo,
				errors: { accountNumber: 'No account with that number at this bank.' }
			});
		}
		if (isBackendError(failure, 'bank_unknown') || isBackendError(failure, 'validation_error')) {
			return fail(422, { ...echo, errors: { bankCode: 'Choose your bank from the list.' } });
		}
		if (isBackendError(failure, 'rate_limited')) {
			return fail(429, { ...echo, message: 'Too many account checks. Try again later.' });
		}
		if (isBackendError(failure, 'provider_unavailable') || failure._tag === 'TransportError') {
			return fail(503, {
				...echo,
				message: 'We couldn’t check the account right now. Try again shortly.'
			});
		}
		if (isBackendError(failure, 'no_wallet') || isBackendError(failure, 'payout_account_exists')) {
			redirect(303, '/onboarding/continue');
		}
		redirectForFailure(failure);
	},

	confirm: async (event) => {
		const { wizard } = await expectStep(event, 'bank');
		const form = await event.request.formData();
		const lookupId = String(form.get('lookupId') ?? '');
		const idempotencyKey = String(form.get('idempotencyKey') ?? '');
		const membershipId = wizard.membershipId;
		if (!membershipId) redirect(303, '/onboarding/continue');
		const exit = await runApi(
			event,
			wizard.session,
			Effect.gen(function* () {
				return yield* (yield* PayoutApi).confirm(membershipId, { lookupId, idempotencyKey });
			})
		);
		if (Exit.isSuccess(exit)) redirect(303, '/onboarding/done');
		const failure = failureOf(exit);
		if (isBackendError(failure, 'payout_lookup_expired')) {
			return fail(409, { message: 'That check expired. Look the account up again.' });
		}
		if (isBackendError(failure, 'payout_name_mismatch')) {
			return fail(422, { message: 'This account’s name doesn’t match your verified name.' });
		}
		if (isBackendError(failure, 'payout_account_exists')) redirect(303, '/onboarding/continue');
		if (failure._tag === 'TransportError' && failure.status !== 401) {
			return fail(503, {
				message: 'We couldn’t confirm that. Try again.',
				lookupId,
				confirmKey: idempotencyKey
			});
		}
		redirectForFailure(failure);
	}
};
