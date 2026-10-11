// Slice 29: a <button> with no type inside a form submits it. Bits UI's
// Trigger/Close/Cancel/Action render <button> without one, which made "Choose a
// member" on Record income submit the whole form and show every error at once.
// Every such component in the app says type="button"; this keeps it that way.

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const ROOT = join(import.meta.dirname, '..', '..');

function svelteFiles(dir: string): string[] {
	return readdirSync(dir).flatMap((name) => {
		const path = join(dir, name);
		if (statSync(path).isDirectory()) return svelteFiles(path);
		return name.endsWith('.svelte') ? [path] : [];
	});
}

const BITS_BUTTON =
	/<((?:Dialog|AlertDialog|Popover|DropdownMenu)\.(?:Trigger|Close|Cancel|Action))\b((?:[^>{]|\{[^}]*\})*)>/g;

describe('buttons inside forms (Slice 29)', () => {
	it('every Bits UI trigger, close, cancel and action button has a type', () => {
		const missing: string[] = [];
		for (const file of [...svelteFiles(join(ROOT, 'lib')), ...svelteFiles(join(ROOT, 'routes'))]) {
			const source = readFileSync(file, 'utf8');
			for (const match of source.matchAll(BITS_BUTTON)) {
				const attrs = match[2] ?? '';
				if (!/\btype=/.test(attrs) && !/\bchild\b/.test(attrs)) {
					missing.push(`${file.slice(ROOT.length + 1)}: <${match[1]}>`);
				}
			}
		}
		expect(missing).toEqual([]);
	});
});
