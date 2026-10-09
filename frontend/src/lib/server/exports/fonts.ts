// Lexend and IBM Plex Mono for generated PDFs, inlined as data URLs so the
// headless browser never fetches anything (latin + latin-ext: ₦ is U+20A6).
import lexendLatin from '@fontsource-variable/lexend/files/lexend-latin-wght-normal.woff2?inline';
import lexendLatinExt from '@fontsource-variable/lexend/files/lexend-latin-ext-wght-normal.woff2?inline';
import monoLatin from '@fontsource/ibm-plex-mono/files/ibm-plex-mono-latin-400-normal.woff2?inline';
import monoLatinExt from '@fontsource/ibm-plex-mono/files/ibm-plex-mono-latin-ext-400-normal.woff2?inline';

const LATIN =
	'U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD';
const LATIN_EXT =
	'U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF';

export const FONT_FACES = `
@font-face{font-family:Lexend;font-style:normal;font-weight:100 900;src:url(${lexendLatin}) format('woff2');unicode-range:${LATIN}}
@font-face{font-family:Lexend;font-style:normal;font-weight:100 900;src:url(${lexendLatinExt}) format('woff2');unicode-range:${LATIN_EXT}}
@font-face{font-family:'IBM Plex Mono';font-style:normal;font-weight:400;src:url(${monoLatin}) format('woff2');unicode-range:${LATIN}}
@font-face{font-family:'IBM Plex Mono';font-style:normal;font-weight:400;src:url(${monoLatinExt}) format('woff2');unicode-range:${LATIN_EXT}}`;
