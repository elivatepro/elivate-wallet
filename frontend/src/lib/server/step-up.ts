// Step-up for protected commands (A-05): when the person typed their PIN in
// the confirm dialog, verify it first (this opens a fresh 5-minute proof),
// then run the command. Without a PIN the backend decides; an expired proof
// comes back as step_up_required and the dialog asks for the PIN.

import { Effect } from 'effect';
import { SecurityApi } from './apis';
import type { EdgeFailure } from './edge';
import type { ApiServices } from './request';

export const withPin = <A>(
	pin: string | undefined,
	program: Effect.Effect<A, EdgeFailure, ApiServices>
): Effect.Effect<A, EdgeFailure, ApiServices> =>
	Effect.gen(function* () {
		if (pin) yield* (yield* SecurityApi).verifyPin({ pin });
		return yield* program;
	});
