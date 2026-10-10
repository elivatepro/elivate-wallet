// Unknown /app/* paths (Paper X01/X02). SvelteKit sends a client navigation
// with no matching route to the server, which would render the root error page
// without the shell; this catch-all keeps them in the client shell so
// app/+error.svelte shows "This page isn’t on the map" in the main area. It is
// not prerendered: the Worker serves the empty client shell for any such path.
import { error } from '@sveltejs/kit';
import type { PageLoad } from './$types';

export const prerender = false;

export const load: PageLoad = ({ url }) => {
	error(404, `Not found: ${url.pathname}`);
};
