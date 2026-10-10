-- Blueprint 05 — B6 test 1: the bank-name vs NIN-name rule (Q1-C, nm-1).
begin;
-- Slice 22: these fixtures predate setup by role (pgTAP 220 tests the gate).
set local identity.setup_gate = off;
create extension if not exists pgtap with schema extensions;
select plan(52);

create function pg_temp.legal(p_given text, p_middle text[], p_surname text) returns jsonb
language sql immutable as $$
  select jsonb_build_object('given', p_given, 'middle', to_jsonb(coalesce(p_middle, '{}'::text[])), 'surname', p_surname)
$$;
create function pg_temp.nm(p_given text, p_middle text[], p_surname text, p_bank text) returns text
language sql immutable as $$
  select payout.name_match(pg_temp.legal(p_given, p_middle, p_surname), p_bank)::text
$$;

-- ── Normalisation ──
select is(payout.name_words('  Ọlá  Adé-Bọ̀wálé '), array['OLA', 'ADE', 'BOWALE'], 'NFKD, marks dropped, hyphen splits');
select is(payout.name_words('O''Brien, J. P.'), array['OBRIEN', 'J', 'P'], 'apostrophes and dots deleted, commas split');
select is(payout.name_words('D’Souza/Okeke'), array['DSOUZA', 'OKEKE'], 'typographic apostrophe deleted, slash splits');
select is(payout.name_words('ADEBAYO 2 OKAFOR'), array['ADEBAYO', 'OKAFOR'], 'digits split and vanish');
select is(payout.name_words(''), '{}'::text[], 'empty name has no words');
select is(payout.name_words(null), '{}'::text[], 'null name has no words');
select is(payout.name_words('ﬁfi'), array['FIFI'], 'compatibility ligatures decompose');
select is(payout.strip_titles(array['MR', 'DR', 'NGOZI', 'EZE']), array['NGOZI', 'EZE'], 'several leading titles are dropped');
select is(payout.strip_titles(array['NGOZI', 'EZE', 'MRS']), array['NGOZI', 'EZE', 'MRS'], 'trailing titles stay');

-- ── Blueprint B2 table ──
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'OKAFOR ADEBAYO OLUWASEUN'), 'matched', 'different order');
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'Okafor, Adebayo'), 'matched', 'middle name missing');
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'OKAFOR ADEBAYO O.'), 'matched', 'middle initial');
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'OKAFOR A. OLUWASEUN'), 'mismatched', 'first name as an initial');
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'ADEBAYO OLUWASEUN'), 'mismatched', 'surname missing');
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'ADEBAYO OKAFFOR'), 'mismatched', 'no spelling tolerance');
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'ADEBAYO OKAFOR CHUKWU'), 'mismatched', 'extra word');
select is(pg_temp.nm('Ngozi', null, 'Eze', 'MRS NGOZI EZE'), 'matched', 'leading title dropped');
select is(pg_temp.nm('Ifeoma', null, 'Nwachukwu-Okeke', 'NWACHUKWU OKEKE IFEOMA'), 'matched', 'hyphen equals space');
select is(pg_temp.nm('Ngozi', array['Adaeze'], 'Okeke', 'NGOZI EZE'), 'mismatched', 'married name blocked');
select is(pg_temp.nm('Chidi', null, 'Obi', 'OBI CHIDI ENTERPRISES'), 'mismatched', 'business name blocked');

-- ── More cases ──
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'ADEBAYO OLUWASEUN OKAFOR'), 'matched', 'NIN order');
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'adebayo okafor'), 'matched', 'case ignored');
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', '  ADEBAYO    OKAFOR  '), 'matched', 'spacing ignored');
select is(pg_temp.nm('Ọlá', null, 'Adébáyọ̀', 'OLA ADEBAYO'), 'matched', 'Yoruba marks on the NIN side');
select is(pg_temp.nm('Ola', null, 'Adebayo', 'ỌLÁ ADÉBÁYỌ̀'), 'matched', 'Yoruba marks on the bank side');
select is(pg_temp.nm('Adebayo', array['Oluwaseun', 'Tunde'], 'Okafor', 'OKAFOR ADEBAYO O T'), 'matched', 'two middle initials');
select is(pg_temp.nm('Adebayo', array['Oluwaseun', 'Tunde'], 'Okafor', 'OKAFOR ADEBAYO TUNDE'), 'matched', 'one of two middle names');
select is(pg_temp.nm('Adebayo', array['Oluwaseun', 'Tunde'], 'Okafor', 'OKAFOR ADEBAYO T OLUWASEUN'), 'matched', 'initial plus full middle name');
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'OKAFOR ADEBAYO O OLUWASEUN'), 'mismatched', 'a middle name used twice');
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'OKAFOR ADEBAYO X'), 'mismatched', 'initial of no middle name');
select is(pg_temp.nm('Adebayo', null, 'Okafor', 'OKAFOR ADEBAYO A'), 'mismatched', 'initial without a middle name');
select is(pg_temp.nm('Adebayo', null, 'Okafor', 'OKAFOR'), 'mismatched', 'one bank word');
select is(pg_temp.nm('Adebayo', null, 'Okafor', ''), 'mismatched', 'empty bank name');
select is(pg_temp.nm('Adebayo', null, 'Okafor', 'MR OKAFOR'), 'mismatched', 'title plus one word');
select is(pg_temp.nm('Adebayo', null, 'Okafor', 'CHIEF DR ADEBAYO OKAFOR'), 'matched', 'two leading titles');
select is(pg_temp.nm('Adebayo', null, 'Okafor', 'ADEBAYO OKAFOR MR'), 'mismatched', 'trailing title is an extra word');
select is(pg_temp.nm('Mary Jane', null, 'Okafor', 'OKAFOR MARY'), 'matched', 'second given name is optional');
select is(pg_temp.nm('Mary Jane', null, 'Okafor', 'OKAFOR MARY J'), 'matched', 'second given name as an initial');
select is(pg_temp.nm('Mary Jane', null, 'Okafor', 'OKAFOR JANE'), 'mismatched', 'first given name is required');
select is(pg_temp.nm('Adebayo', null, 'Okafor Eze', 'ADEBAYO OKAFOR'), 'mismatched', 'every surname word is required');
select is(pg_temp.nm('Emeka', null, 'Emeka', 'EMEKA EMEKA'), 'matched', 'repeated word counted twice');
select is(pg_temp.nm('Emeka', null, 'Emeka', 'EMEKA OBI'), 'mismatched', 'repeated word must appear twice');
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'ADEBAYO ADEBAYO OKAFOR'), 'mismatched', 'duplicate bank word');
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'O''Neil', 'ADEBAYO ONEIL'), 'matched', 'apostrophe in surname');
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'ADEBAYO OKAFOR OLUWASEUN.'), 'matched', 'trailing dot');
select is(pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'ADEBAYO OKAFOR OLUWASEUN 123'), 'matched', 'digits ignored');

-- ── Identity pending and robustness ──
select is(payout.name_match(null, 'ADEBAYO OKAFOR')::text, 'identity_pending', 'no verified identity yet');
select is(payout.name_match('null'::jsonb, 'ADEBAYO OKAFOR')::text, 'identity_pending', 'JSON null is no identity');
select throws_ok(
  $$ select payout.name_match('{"given": "Ade"}'::jsonb, 'ADE OKAFOR') $$,
  'P0001', 'invariant_violation', 'a malformed legal name is a bug, not a mismatch'
);
select throws_ok(
  $$ select payout.name_match('{"given": "", "surname": "Okafor"}'::jsonb, 'ADE OKAFOR') $$,
  'P0001', 'invariant_violation', 'an empty given name is a bug'
);
select is(
  (select count(distinct pg_temp.nm('Adebayo', array['Oluwaseun'], 'Okafor', 'OKAFOR ADEBAYO O.')) from generate_series(1, 20))::int,
  1, 'deterministic across calls'
);
select is(payout.name_rule_version(), 'nm-1', 'rule version');

select * from finish();
rollback;
