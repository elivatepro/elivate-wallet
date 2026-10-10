// Blueprint 20 B8: the member service worker precaches only what the signed-in
// shell needs to open offline: Kit's client entry, the root and /app layouts,
// Home, the error pages, and everything those import (chunks, CSS, fonts).
// Other route chunks (every Admin page included) are fetched when first used
// and kept by the worker's runtime cache, never precached.
//
// The service worker imports `virtual:ew-precache`; this plugin answers it from
// the client build's Vite manifest and Kit's generated route nodes, which both
// exist by the time Kit builds the service worker. In dev the list is empty.

import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Plugin } from 'vite';

const VIRTUAL = 'virtual:ew-precache';
const RESOLVED = `\0${VIRTUAL}`;

/** Route files whose nodes the offline shell needs. */
const SHELL_SOURCES = [
	'src/routes/+layout.svelte',
	'src/routes/+error.svelte',
	'src/routes/app/+layout.svelte',
	'src/routes/app/+layout.ts',
	'src/routes/app/+page.svelte',
	'src/routes/app/+error.svelte'
];

interface Chunk {
	readonly file: string;
	readonly src?: string;
	readonly isEntry?: boolean;
	readonly imports?: readonly string[];
	readonly css?: readonly string[];
	readonly assets?: readonly string[];
}

/** The `_app/immutable/...` files the shell needs, from the client manifest. */
export function shellFiles(root: string): string[] | null {
	const manifestPath = join(root, '.svelte-kit/output/client/.vite/manifest.json');
	if (!existsSync(manifestPath)) return null;
	const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as Record<string, Chunk>;

	const isShellNode = (chunk: Chunk) => {
		if (!chunk.src) return false;
		const generated = join(root, chunk.src);
		if (!existsSync(generated)) return false;
		const text = readFileSync(generated, 'utf8');
		// Kit's built-in error page (when a route has no +error) counts too.
		return (
			SHELL_SOURCES.some((source) => text.includes(`/${source}"`)) ||
			text.includes('@sveltejs/kit/src/runtime/components/')
		);
	};
	const starts = Object.entries(manifest).filter(([, chunk]) => {
		if (!chunk.isEntry) return false;
		// Route nodes are entries too: keep only the shell's.
		return /\/nodes\/\d+\.js$/.test(chunk.src ?? '') ? isShellNode(chunk) : true;
	});

	const files = new Set<string>();
	const seen = new Set<string>();
	const visit = (key: string) => {
		if (seen.has(key)) return;
		seen.add(key);
		const chunk = manifest[key];
		if (!chunk) return;
		files.add(chunk.file);
		for (const file of [...(chunk.css ?? []), ...(chunk.assets ?? [])]) files.add(file);
		for (const next of chunk.imports ?? []) visit(next);
	};
	for (const [key] of starts) visit(key);
	return [...files].sort();
}

export function precachePlugin(): Plugin {
	let root = process.cwd();
	return {
		name: 'ew-precache',
		configResolved(config) {
			root = config.root;
		},
		resolveId(id) {
			return id === VIRTUAL ? RESOLVED : null;
		},
		load(id) {
			if (id !== RESOLVED) return null;
			const files = shellFiles(root);
			return `export const shellFiles = ${JSON.stringify(files)};`;
		}
	};
}
