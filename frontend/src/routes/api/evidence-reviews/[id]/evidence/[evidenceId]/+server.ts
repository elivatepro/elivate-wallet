// View one evidence file of a conversion, adjustment or returned funds
// (reviewers and the leaders who may record that kind for the member).
import { EntryRoutes } from '#lib/contract/entries.js';
import { streamEvidence, validId } from '#lib/server/money-endpoints.js';
import { invalidRequest, respondError } from '#lib/server/relay.js';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = (event) => {
	const { id, evidenceId } = event.params;
	if (!validId(id) || !validId(evidenceId) || [...event.url.searchParams.keys()].length) {
		return Promise.resolve(respondError(invalidRequest('id')));
	}
	return streamEvidence(event, EntryRoutes.evidence(id, evidenceId), {});
};
